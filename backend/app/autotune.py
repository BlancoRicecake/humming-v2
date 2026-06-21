"""Vocal autotune — WORLD-vocoder pitch correction toward the song's scale.

Pipeline: decode @44.1k → (optional) light denoise → WORLD analysis
(dio+stonemask f0 / CheapTrick envelope / D4C aperiodicity) → per-frame
in-scale target with hysteresis + median smoothing (no warble) → one-pole
retune-speed smoothing of the correction → resynthesize with the corrected f0.

WORLD keeps the spectral envelope fixed while f0 moves, so formants are
preserved (no chipmunk) and continuously-varying correction curves are native
— exactly what per-frame scale snapping needs. librosa's phase-vocoder
pitch_shift (constant shift per segment, boundary phasiness) was rejected.
"""
from __future__ import annotations

import io
import math
from typing import List, Tuple

import numpy as np
import soundfile as sf
from fastapi import HTTPException
from scipy.ndimage import median_filter

from .analyze import _downsample_for_display, _ffmpeg_decode_to_pcm, _magic_is_wav, denoise_vocal_light
from .scales import scale_pitch_classes

AT_SR = 44100  # quality path — bypasses analyze.py's 22050 default
FRAME_PERIOD_MS = 5.0
MAX_DURATION_SEC = 60.0
MIN_DURATION_SEC = 0.3
MIN_INPUT_RMS = 0.0015
MIN_VOICED_RATIO = 0.02
MIN_VOICED_SEC = 0.12
# hysteresis: switch target notes only when the new nearest scale tone is
# closer than the held one by this margin (semitones)
HYSTERESIS_ST = 0.6
# median kernel over the target-note track ≈ 45 ms at 5 ms frames
TARGET_MEDFILT = 9
# treat an unvoiced gap longer than this as a phrase break (reset smoothing)
PHRASE_GAP_FRAMES = 40  # 200 ms


def _nearest_scale_midi(m: float, pcs: List[int]) -> int:
    """Nearest in-scale MIDI note to float [m] (mirrors quantize_midi_to_scale)."""
    base = int(round(m))
    best, best_dist = base, 1e9
    for octave_shift in (-1, 0, 1):
        for pc in pcs:
            candidate = base - base % 12 + pc + 12 * octave_shift
            dist = abs(candidate - m)
            if dist < best_dist:
                best_dist = dist
                best = candidate
    return best


def retune_f0(
    f0: np.ndarray,
    tonic: str,
    scale: str,
    strength: float = 1.0,
    retune_ms: float = 80.0,
    frame_period_ms: float = FRAME_PERIOD_MS,
) -> np.ndarray:
    """Corrected f0 track: per-frame nearest in-scale target (with hysteresis +
    median smoothing), correction eased in with a [retune_ms] one-pole, scaled
    by [strength]. Unvoiced frames (f0==0) pass through untouched."""
    pcs = scale_pitch_classes(tonic, scale)
    out = f0.astype(np.float64).copy()
    voiced_idx = np.nonzero(f0 > 0)[0]
    if voiced_idx.size == 0:
        return out

    midi = 69.0 + 12.0 * np.log2(f0[voiced_idx] / 440.0)

    # 1) per-frame target note with hysteresis (don't flap between neighbors)
    targets = np.empty(voiced_idx.size, dtype=np.float64)
    held: int | None = None
    last_i = None
    for k, i in enumerate(voiced_idx):
        m = midi[k]
        cand = _nearest_scale_midi(m, pcs)
        if held is None or (last_i is not None and i - last_i > PHRASE_GAP_FRAMES):
            held = cand
        elif cand != held and (abs(m - held) - abs(m - cand)) > HYSTERESIS_ST:
            held = cand
        targets[k] = held
        last_i = i

    # 2) median-smooth the target track PER voiced phrase (kernel of note
    #    values stays in-scale). Segmenting at phrase gaps + 'nearest' edge
    #    handling avoids medfilt's zero-padding, which would bias targets
    #    toward 0 at phrase edges and smear targets across phrase breaks.
    gap_starts = np.nonzero(np.diff(voiced_idx) > PHRASE_GAP_FRAMES)[0] + 1
    for seg in np.split(targets, gap_starts):  # views — edits land in targets
        if seg.size >= 3:
            seg[:] = median_filter(seg, size=TARGET_MEDFILT, mode="nearest")

    # 3) retune-speed: one-pole the correction; reset at phrase breaks
    alpha = 1.0 - math.exp(-frame_period_ms / max(retune_ms, 1.0))
    smoothed = 0.0
    last_i = None
    for k, i in enumerate(voiced_idx):
        if last_i is not None and i - last_i > PHRASE_GAP_FRAMES:
            smoothed = 0.0
        corr = targets[k] - midi[k]
        smoothed += alpha * (corr - smoothed)
        out[i] = f0[i] * 2.0 ** (strength * smoothed / 12.0)
        last_i = i
    return out


def _decode_44k(file_bytes: bytes) -> Tuple[np.ndarray, int]:
    if _magic_is_wav(file_bytes):
        try:
            y, sr = sf.read(io.BytesIO(file_bytes), dtype="float32", always_2d=False)
        except sf.LibsndfileError as e:  # corrupt/truncated WAV → client error
            raise HTTPException(status_code=400, detail=f"audio decode failed (wav): {e}")
        if y.ndim > 1:
            y = y.mean(axis=1).astype(np.float32)
        if sr != AT_SR:
            import librosa

            y = librosa.resample(y, orig_sr=sr, target_sr=AT_SR)
            sr = AT_SR
        return y.astype(np.float32), sr
    return _ffmpeg_decode_to_pcm(file_bytes, target_sr=AT_SR, mono=True)


def autotune_vocal(
    file_bytes: bytes,
    tonic: str,
    scale: str,
    strength: float = 1.0,
    retune_ms: float = 80.0,
    denoise: bool = True,
) -> Tuple[bytes, List[float], float, int]:
    """Uploaded vocal → (corrected WAV bytes, display peaks, duration, sr).

    Raises ValueError for unknown tonic/scale or over-long input (→ 400).
    """
    import pyworld as pw  # lazy: heavy C extension

    scale_pitch_classes(tonic, scale)  # validate early → ValueError → 400

    y, sr = _decode_44k(file_bytes)
    duration = y.size / sr if sr else 0.0
    if duration > MAX_DURATION_SEC:
        raise ValueError(f"audio too long (> {MAX_DURATION_SEC:.0f}s)")
    if duration < MIN_DURATION_SEC:
        raise ValueError("vocal recording is too short")
    rms = float(np.sqrt(np.mean(np.square(y)))) if y.size else 0.0
    if rms < MIN_INPUT_RMS:
        raise ValueError("vocal recording is too quiet")
    if denoise:
        y = denoise_vocal_light(y, sr)

    y64 = y.astype(np.float64)
    f0, t = pw.dio(y64, sr, frame_period=FRAME_PERIOD_MS)
    f0 = pw.stonemask(y64, f0, t, sr)
    voiced = np.count_nonzero(f0 > 0)
    voiced_ratio = voiced / max(len(f0), 1)
    voiced_sec = voiced * FRAME_PERIOD_MS / 1000.0
    if voiced_ratio < MIN_VOICED_RATIO or voiced_sec < MIN_VOICED_SEC:
        raise ValueError("no clear vocal pitch detected")
    sp = pw.cheaptrick(y64, f0, t, sr)
    ap = pw.d4c(y64, f0, t, sr)

    f0_out = retune_f0(f0, tonic, scale, strength=strength, retune_ms=retune_ms)
    y_out = pw.synthesize(f0_out, sp, ap, sr, frame_period=FRAME_PERIOD_MS)

    peak = float(np.max(np.abs(y_out))) if y_out.size else 0.0
    if peak > 1e-6:
        y_out = y_out * (0.99 / max(peak, 0.99))
    y_out = y_out.astype(np.float32)

    buf = io.BytesIO()
    sf.write(buf, y_out, sr, format="WAV", subtype="PCM_16")
    return buf.getvalue(), _downsample_for_display(y_out, 400), (len(y_out) / sr if sr else 0.0), sr
