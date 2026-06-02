"""Drum hit classification — kick / snare / hi-hat from a short onset segment.

Pure DSP heuristic (numpy rfft), no model / no training. Wired into the
``as_drums`` onset path (drum_onset.py) and the per-note melodic loop in
analyze.py. Returns a GM percussion note number (channel 10).

GM mapping used:
- 36 = Bass Drum 1 (kick)
- 38 = Acoustic Snare
- 42 = Closed Hi-Hat

PHONE-MIC NOTE: smartphone mics aggressively high-pass below ~200Hz (measured
on iPhone/Android), so the kick's sub-150Hz fundamental is largely stripped.
The classifier therefore does NOT gate kick on absolute sub-150Hz energy
(``low_ratio``, kept for debug only). Instead it uses features the phone mic
preserves:
- spectral CENTROID  — brightness (kick low, hi-hat high)
- spectral ROLLOFF   — 85% energy frequency (kick low, hi-hat high)
- ZERO-CROSSING RATE — high for noisy/bright hi-hats
- spectral FLATNESS  — kick↔snare separator: snare is broadband noise (high
  flatness), kick is a tonal body (low flatness) even after the phone strips
  its sub-bass.
"""
from __future__ import annotations

from dataclasses import dataclass

import numpy as np

KICK = 36
SNARE = 38
HIHAT = 42

# --- tuning thresholds (CALIBRATED against labeled device recordings) ---
# Calibrated 2026-06-02 on a labeled 16-hit NATURAL beat pattern (upload_095,
# Galaxy S10 mic) + isolated snare/hi-hat takes (084/085). The natural pattern is
# the real use case, so it's the primary reference. Measured clusters (095):
#   Kick : centroid  910-1236, rolloff 1134-2089, zcr 0.019-0.027, flat ~0.002
#   Snare: centroid 2494-2963, rolloff 4779-6868, zcr 0.136-0.182, flat ~0.02
#   HiHat: centroid 5243-6017, rolloff 8758-9158, zcr 0.496-0.617, flat ~0.28
# Findings: (1) the natural kick is a pure low boom — very low centroid AND very
# low zcr (a tight, tonal hit), cleanly separable from snare on every axis.
# (2) FLATNESS does not separate kick/snare reliably (kept for debug only).
# NOTE: an isolated "kick" take (083) came out much brighter (centroid ~2400,
# overlapping snare) — an unrepresentative rendition; we optimize for the
# natural pattern. Re-run diagnose_drums.py to recalibrate a different mic/voice.
HIHAT_CENTROID = 4000.0  # centroid above this → hi-hat (snare max ~3344)
HIHAT_ROLLOFF = 8000.0   # 85% rolloff above this → hi-hat (snare max ~7891 < hi-hat min ~8758)
HIHAT_ZCR = 0.30         # zero-crossing rate above this → hi-hat (snare max ~0.18 < hi-hat min ~0.50)
KICK_CENTROID = 1800.0   # kick centroid below this (kick max ~1236 < snare min ~2494)
KICK_ZCR_MAX = 0.08      # ... AND zcr below this (kick max ~0.027 < snare min ~0.136)

# debug-only band edges (not used in the decision)
LOW_HZ = 150.0
HIGH_HZ = 5000.0

GM_NAMES = {KICK: "Kick", SNARE: "Snare", HIHAT: "HiHat"}
DRUM_NAMES = GM_NAMES  # back-compat alias


@dataclass
class DrumHit:
    """Classification result + the spectral features behind it (for debug)."""
    gm_note: int        # 36 / 38 / 42
    name: str           # "Kick" | "Snare" | "HiHat"
    centroid: float     # spectral centroid (Hz)
    low_ratio: float    # energy fraction below LOW_HZ (debug only — phone-stripped)
    high_ratio: float   # energy fraction above HIGH_HZ (debug)
    zcr: float          # zero-crossing rate (0-1)
    rolloff: float      # 85% spectral rolloff (Hz)
    flatness: float     # spectral flatness (0-1)


def classify_features(seg: np.ndarray, sr: int) -> DrumHit:
    """Classify a percussive audio segment and return features + GM note.

    The decision is *absolute* (per-hit timbre), not relative to a track
    average — so a take of all hi-hats stays all hi-hats, and a run of
    identical kicks all classify as kick (no boundary to randomly straddle).
    """
    seg = np.asarray(seg, dtype=np.float64)
    if seg.size < 64:
        return DrumHit(SNARE, GM_NAMES[SNARE], 0.0, 0.0, 0.0, 0.0, 0.0, 0.0)

    n = seg.size
    spec = np.abs(np.fft.rfft(seg * np.hanning(n)))
    freqs = np.fft.rfftfreq(n, 1.0 / sr)
    total = float(spec.sum()) + 1e-12

    low_ratio = float(spec[freqs < LOW_HZ].sum()) / total
    high_ratio = float(spec[freqs > HIGH_HZ].sum()) / total
    centroid = float((freqs * spec).sum()) / total
    zcr = float(np.mean(np.abs(np.diff(np.sign(seg))))) / 2.0

    # 85% spectral rolloff
    cumulative = np.cumsum(spec)
    roll_idx = int(np.searchsorted(cumulative, 0.85 * cumulative[-1]))
    roll_idx = min(roll_idx, freqs.size - 1)
    rolloff = float(freqs[roll_idx])

    # spectral flatness = geometric mean / arithmetic mean of the power spectrum.
    # ~1.0 for white noise (snare/hi-hat), → 0 for a tonal sound (kick body).
    power = spec ** 2 + 1e-12
    flatness = float(np.exp(np.mean(np.log(power))) / (np.mean(power) + 1e-12))

    # hi-hat first (bright/noisy — survives the phone high-pass cleanly),
    # then kick (dark, low rolloff), else snare. Rolloff is the kick/snare axis
    # (flatness doesn't separate them for this voice — see threshold notes).
    if centroid >= HIHAT_CENTROID or rolloff >= HIHAT_ROLLOFF or zcr >= HIHAT_ZCR:
        note = HIHAT
    elif centroid <= KICK_CENTROID and zcr <= KICK_ZCR_MAX:
        note = KICK
    else:
        note = SNARE
    return DrumHit(note, GM_NAMES[note], centroid, low_ratio, high_ratio, zcr, rolloff, flatness)


def classify_drum(seg: np.ndarray, sr: int) -> int:
    """Return a GM drum note (36/38/42) for a percussive audio segment."""
    return classify_features(seg, sr).gm_note
