"""Drum hit classification — kick / snare / hi-hat from a chunk of audio.

Pure DSP heuristic (numpy rfft), no model / no training. Used by the
percussive fallback in analyze.py so a beatbox take maps to a real GM kit
instead of one snare. Returns a GM percussion note number (channel 10).

GM mapping used:
- 36 = Bass Drum 1 (kick)
- 38 = Acoustic Snare
- 42 = Closed Hi-Hat
"""
from __future__ import annotations

import numpy as np

KICK = 36
SNARE = 38
HIHAT = 42

# --- tuning thresholds (adjust after reviewing the drum dump) ---
# Calibrated on sample "5. 비트.wav": kicks cluster at centroid <~1.4kHz with
# 20-40% low-band energy; hi-hats at centroid ~5kHz / high ZCR; snares in between.
LOW_HZ = 150.0          # below this = "low band" (kick territory)
HIGH_HZ = 5000.0        # above this = "high band" (hi-hat territory)
KICK_CENTROID = 1600.0  # spectral centroid below this (+ low energy) → kick
KICK_LOW_RATIO = 0.18   # ... with at least this much low-band energy
HIHAT_HIGH_RATIO = 0.22 # high-band energy fraction → hi-hat
HIHAT_CENTROID = 3500.0 # ... or spectral centroid above this
HIHAT_ZCR = 0.25        # ... or zero-crossing rate above this


def classify_drum(seg: np.ndarray, sr: int) -> int:
    """Return a GM drum note (36/38/42) for a percussive audio segment."""
    seg = np.asarray(seg, dtype=np.float64)
    if seg.size < 64:
        return SNARE

    n = seg.size
    spec = np.abs(np.fft.rfft(seg * np.hanning(n)))
    freqs = np.fft.rfftfreq(n, 1.0 / sr)
    total = float(spec.sum()) + 1e-12
    low_ratio = float(spec[freqs < LOW_HZ].sum()) / total
    high_ratio = float(spec[freqs > HIGH_HZ].sum()) / total
    centroid = float((freqs * spec).sum()) / total
    zcr = float(np.mean(np.abs(np.diff(np.sign(seg))))) / 2.0

    # kick first (low, dark), then hi-hat (bright/noisy), else snare
    if centroid <= KICK_CENTROID and low_ratio >= KICK_LOW_RATIO:
        return KICK
    if high_ratio >= HIHAT_HIGH_RATIO or centroid >= HIHAT_CENTROID or zcr >= HIHAT_ZCR:
        return HIHAT
    return SNARE


DRUM_NAMES = {KICK: "Kick", SNARE: "Snare", HIHAT: "HiHat"}
