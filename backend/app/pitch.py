"""Stage 5 helper — pitch contour via pYIN (librosa).

Single backend. We intentionally drop the optional CREPE path for this
minimal build; it can be re-added later if real-recording accuracy turns
out to need a deep-learning tracker.
"""
from __future__ import annotations

from typing import Optional, Tuple

import numpy as np
import librosa


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
