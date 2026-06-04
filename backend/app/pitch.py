"""Stage 5 helper — pitch contour via pYIN (librosa) or CREPE (opt-in).

Two backends share one contract — ``(times, hz, voiced_flag, voiced_prob)``:

* ``extract_pitch_pyin``   — librosa pYIN, the default. No extra deps.
* ``extract_pitch_crepe``  — pretrained CREPE CNN tracker, opt-in. More
  octave-robust on low humming. Heavy deps (torch for dev / onnxruntime for
  prod) are imported *lazily inside the backend* so the pYIN path never pays
  for them. A ``crepe-tiny.onnx`` bundled under ``backend/bin/crepe/`` is
  preferred at runtime; otherwise we fall back to ``torchcrepe`` (dev).
"""
from __future__ import annotations

from pathlib import Path
from typing import Optional, Tuple

import numpy as np
import librosa

# CREPE operates on 16 kHz audio with a native 10 ms hop (160 samples).
CREPE_SR = 16000
CREPE_HOP = 160
CREPE_FRAME = 1024


def extract_pitch_pyin(
    y: np.ndarray,
    sr: int,
    fmin: float,
    fmax: float,
    frame_length: Optional[int] = None,
    hop_length: int = 256,
) -> Tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray]:
    """Return ``(times, hz, voiced_flag, voiced_prob)``.

    If ``frame_length`` is None we pick it from ``fmin`` so 4 periods of the
    fundamental fit inside the analysis window — pYIN degrades badly when the
    window holds fewer than 2-3 periods.
    """
    if frame_length is None:
        periods_needed = 4
        required = int(np.ceil(sr / max(fmin, 30.0) * periods_needed))
        size = 1
        while size < max(2048, required):
            size *= 2
        frame_length = size
    f0, voiced_flag, voiced_prob = librosa.pyin(
        y, fmin=fmin, fmax=fmax, sr=sr,
        frame_length=frame_length, hop_length=hop_length,
        fill_na=np.nan,
    )
    times = librosa.times_like(f0, sr=sr, hop_length=hop_length)
    if voiced_prob is None:
        voiced_prob = np.where(voiced_flag, 1.0, 0.0)
    return times, f0, voiced_flag.astype(bool), voiced_prob


def hz_to_midi_float(hz: np.ndarray) -> np.ndarray:
    out = np.full_like(hz, np.nan, dtype=np.float64)
    mask = np.isfinite(hz) & (hz > 0)
    out[mask] = 69.0 + 12.0 * np.log2(hz[mask] / 440.0)
    return out


# ---------------------------------------------------------------------------
# CREPE backend (opt-in) — same contract as extract_pitch_pyin
# ---------------------------------------------------------------------------

BUNDLED_CREPE_ONNX = (
    Path(__file__).resolve().parent.parent / "bin" / "crepe" / "crepe-tiny.onnx"
)

# Lazy singleton: built once on first CREPE request, then reused. workers=1 in
# prod means one backend per process. Default pYIN users never touch this.
_CREPE_STATE = {"backend": None, "error": None}

# CREPE's 360 pitch bins map to cents (20 cents apart), starting near C1.
_CREPE_CENTS = np.linspace(0.0, 7180.0, 360) + 1997.3794084376191
# CREPE's supported f0 band (bin 0 .. bin 359), used to clamp caller fmin/fmax.
_CREPE_FMIN_HZ = float(10.0 * 2.0 ** (_CREPE_CENTS[0] / 1200.0))    # ~31.7 Hz
_CREPE_FMAX_HZ = float(10.0 * 2.0 ** (_CREPE_CENTS[-1] / 1200.0))   # ~2004 Hz


def _clamp_band(fmin: float, fmax: float) -> Tuple[float, float]:
    """Clamp a caller (fmin, fmax) to CREPE's representable range."""
    lo = max(float(fmin), _CREPE_FMIN_HZ)
    hi = min(float(fmax), _CREPE_FMAX_HZ)
    if hi <= lo:                      # degenerate request — fall back to full band
        lo, hi = _CREPE_FMIN_HZ, _CREPE_FMAX_HZ
    return lo, hi


def _to_local_average_cents(salience: np.ndarray) -> np.ndarray:
    """Decode (N, 360) salience to cents via a ±4-bin weighted average."""
    centers = np.argmax(salience, axis=1)
    out = np.zeros(salience.shape[0], dtype=np.float64)
    for i, c in enumerate(centers):
        start, end = max(0, c - 4), min(360, c + 5)
        s = salience[i, start:end]
        wsum = float(s.sum())
        out[i] = float((s * _CREPE_CENTS[start:end]).sum() / wsum) if wsum > 0 else 0.0
    return out


class _OnnxCrepe:
    """Prod backend: bundled tiny ONNX model + in-house framing/decoder."""

    def __init__(self, onnx_path: Path):
        import onnxruntime as ort  # lazy
        self._sess = ort.InferenceSession(
            str(onnx_path), providers=["CPUExecutionProvider"]
        )
        self._input = self._sess.get_inputs()[0].name

    def predict(
        self, y16: np.ndarray, fmin: float, fmax: float
    ) -> Tuple[np.ndarray, np.ndarray, np.ndarray]:
        audio = np.pad(y16.astype(np.float32), CREPE_FRAME // 2, mode="constant")
        n_frames = 1 + (len(audio) - CREPE_FRAME) // CREPE_HOP
        if n_frames <= 0:
            empty = np.zeros(0)
            return empty, empty, empty
        frames = np.lib.stride_tricks.as_strided(
            audio,
            shape=(n_frames, CREPE_FRAME),
            strides=(audio.strides[0] * CREPE_HOP, audio.strides[0]),
        ).copy()
        frames -= frames.mean(axis=1, keepdims=True)
        frames /= np.clip(frames.std(axis=1, keepdims=True), 1e-8, None)
        salience = self._sess.run(None, {self._input: frames.astype(np.float32)})[0]
        # Restrict the decoder to the requested band so out-of-range bins can't
        # win the argmax (a common octave-error source). Mirrors torchcrepe's
        # fmin/fmax behaviour for the prod path.
        lo, hi = _clamp_band(fmin, fmax)
        band = (_CREPE_CENTS >= 1200.0 * np.log2(lo / 10.0)) & (
            _CREPE_CENTS <= 1200.0 * np.log2(hi / 10.0)
        )
        salience = salience * band[None, :]
        cents = _to_local_average_cents(salience)
        hz = 10.0 * (2.0 ** (cents / 1200.0))
        conf = salience.max(axis=1).astype(np.float64)
        times = np.arange(n_frames, dtype=np.float64) * (CREPE_HOP / CREPE_SR)
        return times, hz, conf


class _TorchCrepe:
    """Dev backend: torchcrepe.predict (PyTorch). Not bundled in prod."""

    def __init__(self):
        import torch  # lazy
        import torchcrepe  # lazy
        self._torch = torch
        self._tc = torchcrepe

    def predict(
        self, y16: np.ndarray, fmin: float, fmax: float
    ) -> Tuple[np.ndarray, np.ndarray, np.ndarray]:
        lo, hi = _clamp_band(fmin, fmax)
        audio = self._torch.from_numpy(y16[None, :].astype(np.float32))
        pitch, periodicity = self._tc.predict(
            audio, CREPE_SR, hop_length=CREPE_HOP,
            fmin=lo, fmax=hi,          # band restriction is essential for stable decoding
            model="tiny", batch_size=512, device="cpu",
            return_periodicity=True,
        )
        hz = pitch.squeeze(0).cpu().numpy().astype(np.float64)
        conf = periodicity.squeeze(0).cpu().numpy().astype(np.float64)
        times = np.arange(hz.shape[0], dtype=np.float64) * (CREPE_HOP / CREPE_SR)
        return times, hz, conf


def _get_crepe_backend():
    """Build (once) and return the CREPE backend, preferring bundled ONNX."""
    if _CREPE_STATE["backend"] is not None:
        return _CREPE_STATE["backend"]
    if _CREPE_STATE["error"] is not None:
        raise RuntimeError(_CREPE_STATE["error"])
    try:
        if BUNDLED_CREPE_ONNX.exists():
            backend = _OnnxCrepe(BUNDLED_CREPE_ONNX)
        else:
            backend = _TorchCrepe()
    except Exception as e:  # noqa: BLE001 — surface a clear, cached error
        _CREPE_STATE["error"] = (
            f"CREPE backend unavailable: {e}. Install torchcrepe (dev) or bundle "
            f"crepe-tiny.onnx at {BUNDLED_CREPE_ONNX}."
        )
        raise RuntimeError(_CREPE_STATE["error"]) from e
    _CREPE_STATE["backend"] = backend
    return backend


def extract_pitch_crepe(
    y: np.ndarray,
    sr: int,
    fmin: float,
    fmax: float,
    frame_length: Optional[int] = None,
    hop_length: int = 256,
    *,
    conf_threshold: float = 0.45,
) -> Tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray]:
    """Return ``(times, hz, voiced_flag, voiced_prob)`` — same contract as pYIN.

    ``frame_length``/``hop_length`` are accepted for signature parity but ignored
    (CREPE uses a fixed native 10 ms hop). Downstream consumers are time-based, so
    the different frame grid is safe. Out-of-range or low-confidence frames get
    ``hz = NaN`` to mirror pYIN's ``fill_na=np.nan``.
    """
    y16 = librosa.resample(y, orig_sr=sr, target_sr=CREPE_SR) if sr != CREPE_SR else y
    backend = _get_crepe_backend()
    times, hz, conf = backend.predict(np.ascontiguousarray(y16), fmin, fmax)

    voiced_prob = conf.astype(np.float64)
    voiced_flag = voiced_prob >= conf_threshold
    hz = hz.astype(np.float64)
    drop = (~np.isfinite(hz)) | (hz < fmin) | (hz > fmax) | (~voiced_flag)
    hz[drop] = np.nan
    return times, hz, voiced_flag, voiced_prob
