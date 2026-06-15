# Vocal sound-processing effects for the on-device editor's "사운드 가공" step.
# Mirrors process_vocal/autotune: bytes in → (WAV bytes, display peaks, duration,
# sr). Light edits (trim/fade/gain) stay on-device; these heavier DSP effects run
# here, reusing the 44.1 kHz decode + WORLD vocoder already used by autotune.
from __future__ import annotations

import io
import math
from typing import List, Tuple

import numpy as np
import soundfile as sf

from .analyze import _downsample_for_display, denoise_vocal_light
from .autotune import AT_SR, FRAME_PERIOD_MS, _decode_44k

# Effects whose params are documented inline in _apply_*; unknown types raise.
FX_TYPES = ("eq", "reverb", "comp", "delay", "stretch", "pitch")


def _f(params: dict, key: str, default: float) -> float:
    """Read a finite float param with a fallback (None/NaN/garbage → default)."""
    v = params.get(key, default)
    try:
        f = float(v)
    except (TypeError, ValueError):
        return default
    return f if math.isfinite(f) else default


def _biquad(y: np.ndarray, b: np.ndarray, a: np.ndarray) -> np.ndarray:
    from scipy.signal import lfilter

    return lfilter(b, a, y).astype(np.float32)


def _shelf_or_peak(sr: int, f0: float, gain_db: float, kind: str, q: float = 0.707) -> Tuple[np.ndarray, np.ndarray]:
    """Audio-EQ-cookbook biquad coefficients (low/high shelf, peaking)."""
    a_ = 10.0 ** (gain_db / 40.0)
    w0 = 2.0 * math.pi * min(max(f0, 10.0), sr * 0.45) / sr
    cw, sw = math.cos(w0), math.sin(w0)
    alpha = sw / (2.0 * q)
    if kind == "peak":
        b0 = 1 + alpha * a_
        b1 = -2 * cw
        b2 = 1 - alpha * a_
        a0 = 1 + alpha / a_
        a1 = -2 * cw
        a2 = 1 - alpha / a_
    else:
        tsa = 2.0 * math.sqrt(a_) * alpha
        if kind == "low":
            b0 = a_ * ((a_ + 1) - (a_ - 1) * cw + tsa)
            b1 = 2 * a_ * ((a_ - 1) - (a_ + 1) * cw)
            b2 = a_ * ((a_ + 1) - (a_ - 1) * cw - tsa)
            a0 = (a_ + 1) + (a_ - 1) * cw + tsa
            a1 = -2 * ((a_ - 1) + (a_ + 1) * cw)
            a2 = (a_ + 1) + (a_ - 1) * cw - tsa
        else:  # high shelf
            b0 = a_ * ((a_ + 1) + (a_ - 1) * cw + tsa)
            b1 = -2 * a_ * ((a_ - 1) + (a_ + 1) * cw)
            b2 = a_ * ((a_ + 1) + (a_ - 1) * cw - tsa)
            a0 = (a_ + 1) - (a_ - 1) * cw + tsa
            a1 = 2 * ((a_ - 1) - (a_ + 1) * cw)
            a2 = (a_ + 1) - (a_ - 1) * cw - tsa
    b = np.array([b0, b1, b2]) / a0
    a = np.array([1.0, a1 / a0, a2 / a0])
    return b, a


def _eq(y: np.ndarray, sr: int, params: dict) -> np.ndarray:
    """3-band tone shaping: low shelf @200Hz, mid peak @1kHz, high shelf @5kHz.
    params: {low, mid, high} in dB (each -18..18), optional {lowFreq,midFreq,
    highFreq,midQ}."""
    low = max(-18.0, min(18.0, _f(params, "low", 0.0)))
    mid = max(-18.0, min(18.0, _f(params, "mid", 0.0)))
    high = max(-18.0, min(18.0, _f(params, "high", 0.0)))
    if low:
        y = _biquad(y, *_shelf_or_peak(sr, _f(params, "lowFreq", 200.0), low, "low"))
    if mid:
        y = _biquad(y, *_shelf_or_peak(sr, _f(params, "midFreq", 1000.0), mid, "peak", _f(params, "midQ", 0.9)))
    if high:
        y = _biquad(y, *_shelf_or_peak(sr, _f(params, "highFreq", 5000.0), high, "high"))
    return y


def _reverb(y: np.ndarray, sr: int, params: dict) -> np.ndarray:
    """Convolution reverb with an exponentially-decaying noise impulse response.
    params: {wet 0..1, decay seconds 0.1..4}. Deterministic IR (fixed seed) so
    re-processing is stable."""
    from scipy.signal import fftconvolve

    wet = max(0.0, min(1.0, _f(params, "wet", 0.25)))
    if wet <= 0:
        return y
    decay = max(0.1, min(4.0, _f(params, "decay", 1.4)))
    n = int(sr * decay)
    rng = np.random.default_rng(1234)  # fixed → reproducible reverb tail
    env = np.exp(-np.linspace(0.0, 6.0, n))  # ~ -52 dB at the tail
    ir = (rng.standard_normal(n) * env).astype(np.float32)
    ir[0] = 1.0  # keep the dry transient inside the IR for a natural onset
    wetsig = fftconvolve(y, ir)[: len(y)].astype(np.float32)
    p = float(np.max(np.abs(wetsig))) or 1.0
    wetsig = wetsig / p * (float(np.max(np.abs(y))) or 1.0)  # match dry level
    return ((1.0 - wet) * y + wet * wetsig).astype(np.float32)


def _compress(y: np.ndarray, sr: int, params: dict) -> np.ndarray:
    """Feed-forward compressor with a peak-tracking envelope.
    params: {threshold dB -60..0, ratio 1..20, attack ms, release ms, makeup dB}."""
    thr = max(-60.0, min(0.0, _f(params, "threshold", -18.0)))
    ratio = max(1.0, min(20.0, _f(params, "ratio", 3.0)))
    atk = max(1.0, _f(params, "attack", 10.0)) / 1000.0
    rel = max(5.0, _f(params, "release", 120.0)) / 1000.0
    makeup = _f(params, "makeup", 0.0)

    aa = math.exp(-1.0 / (atk * sr))
    ar = math.exp(-1.0 / (rel * sr))
    env = 0.0
    gain = np.empty(len(y), dtype=np.float32)
    eps = 1e-9
    for i, s in enumerate(np.abs(y)):
        coef = aa if s > env else ar
        env = coef * env + (1.0 - coef) * float(s)
        env_db = 20.0 * math.log10(env + eps)
        over = env_db - thr
        gr_db = (over - over / ratio) if over > 0 else 0.0  # gain reduction (dB)
        gain[i] = 10.0 ** ((makeup - gr_db) / 20.0)
    return (y * gain).astype(np.float32)


def _delay(y: np.ndarray, sr: int, params: dict) -> np.ndarray:
    """Feedback delay / echo. params: {time ms 1..2000, feedback 0..0.95, wet 0..1}."""
    t = max(1.0, min(2000.0, _f(params, "time", 300.0)))
    fb = max(0.0, min(0.95, _f(params, "feedback", 0.35)))
    wet = max(0.0, min(1.0, _f(params, "wet", 0.3)))
    if wet <= 0:
        return y
    d = int(sr * t / 1000.0)
    out = y.astype(np.float32).copy()
    for i in range(d, len(out)):
        out[i] += fb * out[i - d]  # recursive feedback echo
    return ((1.0 - wet) * y + wet * out).astype(np.float32)


def _stretch(y: np.ndarray, sr: int, params: dict) -> np.ndarray:
    """Time-stretch (length change, pitch preserved). params: {ratio 0.5..2.0}
    where >1 = slower/longer. Phase-vocoder via librosa."""
    import librosa

    ratio = max(0.5, min(2.0, _f(params, "ratio", 1.0)))
    if abs(ratio - 1.0) < 1e-3:
        return y
    # librosa rate = output speed; rate<1 slows down (longer). ratio = length mult.
    return librosa.effects.time_stretch(y.astype(np.float32), rate=1.0 / ratio).astype(np.float32)


def _pitch(y: np.ndarray, sr: int, params: dict) -> np.ndarray:
    """Pitch shift with formant preservation via WORLD. params: {semitones -12..12}."""
    import pyworld as pw

    semis = max(-12.0, min(12.0, _f(params, "semitones", 0.0)))
    if abs(semis) < 1e-3:
        return y
    y64 = y.astype(np.float64)
    f0, t = pw.dio(y64, sr, frame_period=FRAME_PERIOD_MS)
    f0 = pw.stonemask(y64, f0, t, sr)
    sp = pw.cheaptrick(y64, f0, t, sr)  # spectral envelope kept → formants preserved
    ap = pw.d4c(y64, f0, t, sr)
    f0_out = f0 * (2.0 ** (semis / 12.0))
    out = pw.synthesize(f0_out, sp, ap, sr, frame_period=FRAME_PERIOD_MS)
    return out.astype(np.float32)


_DISPATCH = {
    "eq": _eq,
    "reverb": _reverb,
    "comp": _compress,
    "delay": _delay,
    "stretch": _stretch,
    "pitch": _pitch,
}


def apply_fx(file_bytes: bytes, fx_type: str, params: dict) -> Tuple[bytes, List[float], float, int]:
    """Uploaded vocal WAV → (processed WAV bytes, display peaks, duration, sr).

    Raises ValueError for an unknown fx_type (→ 400).
    """
    if fx_type not in _DISPATCH:
        raise ValueError(f"unknown fx_type: {fx_type}")

    y, sr = _decode_44k(file_bytes)
    if y.size == 0:
        raise ValueError("empty audio")
    if params.get("denoise"):
        y = denoise_vocal_light(y, sr)

    y = _DISPATCH[fx_type](y, sr, params or {})

    peak = float(np.max(np.abs(y))) if y.size else 0.0
    if peak > 1e-6:
        y = y * (0.99 / max(peak, 0.99))  # leave headroom, only attenuate hot takes
    y = y.astype(np.float32)

    buf = io.BytesIO()
    sf.write(buf, y, sr, format="WAV", subtype="PCM_16")
    return buf.getvalue(), _downsample_for_display(y, 400), (len(y) / sr if sr else 0.0), sr
