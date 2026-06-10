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
HIHAT_HIGH_RATIO = 0.22  # additional high-band evidence; used as a vote, not alone
KICK_CENTROID = 1800.0   # kick centroid below this (kick max ~1236 < snare min ~2494)
KICK_ZCR_MAX = 0.08      # ... AND zcr below this (kick max ~0.027 < snare min ~0.136)
KICK_ROLLOFF_MAX = 2600.0
KICK_FLATNESS_MAX = 0.015

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

    # Evidence voting keeps a single bright artifact from turning a snare/kick
    # into a hat. ZCR is still allowed to dominate because noisy hats are the
    # one class that consistently has very high crossing rates on phone mics.
    hat_votes = int(centroid >= HIHAT_CENTROID)
    hat_votes += int(rolloff >= HIHAT_ROLLOFF)
    hat_votes += int(zcr >= HIHAT_ZCR)
    hat_votes += int(high_ratio >= HIHAT_HIGH_RATIO)

    kick_votes = int(centroid <= KICK_CENTROID)
    kick_votes += int(zcr <= KICK_ZCR_MAX)
    kick_votes += int(rolloff <= KICK_ROLLOFF_MAX)
    kick_votes += int(flatness <= KICK_FLATNESS_MAX)

    if zcr >= HIHAT_ZCR or (hat_votes >= 2 and centroid >= 3000.0):
        note = HIHAT
    elif kick_votes >= 3 and high_ratio < HIHAT_HIGH_RATIO:
        note = KICK
    else:
        note = SNARE
    return DrumHit(note, GM_NAMES[note], centroid, low_ratio, high_ratio, zcr, rolloff, flatness)


def classify_drum(seg: np.ndarray, sr: int) -> int:
    """Return a GM drum note (36/38/42) for a percussive audio segment."""
    return classify_features(seg, sr).gm_note


# --- hybrid (within-take relative) thresholds ---
# A take recorded on one mic/voice has a stable centroid scale, so kick is the
# *lowest* centroid cluster regardless of the absolute level — far more robust
# than a fixed kick threshold that breaks when the mic/strength changes. But a
# UNIFORM take (e.g. all kicks) must not be split into kick/snare/hi-hat, so we
# only do a relative kick/snare split when there's a real bimodal gap; else we
# label the whole cluster by an absolute anchor.
KICK_SNARE_MIN_SPREAD = 800.0   # min centroid spread (Hz) to consider a kick/snare split
KICK_SNARE_GAP_FRAC = 0.35      # largest gap must be ≥ this fraction of the spread (bimodal)
KICK_SNARE_ANCHOR = 2000.0      # uniform non-hat cluster: ≤ this → kick, else snare


def classify_take(hits: List["DrumHit"]) -> List[int]:
    """Re-decide kick/snare/hi-hat for a whole take using *relative* timbre.

    Hi-hats stay absolute (bright/noisy survives the phone high-pass and is a
    robust threshold). The remaining hits (kick vs snare) are split by a
    within-take natural break on centroid — so kicks are simply the darker
    cluster, immune to mic/strength shifts. Falls back to the per-hit absolute
    label (``classify_features``) for short takes (<3 hits) where there's no
    distribution to lean on.
    """
    n = len(hits)
    base = [h.gm_note for h in hits]
    if n < 3:
        return base

    cents = np.array([h.centroid for h in hits], dtype=np.float64)
    zcrs = np.array([h.zcr for h in hits], dtype=np.float64)
    rolls = np.array([h.rolloff for h in hits], dtype=np.float64)
    highs = np.array([h.high_ratio for h in hits], dtype=np.float64)

    # hi-hat: absolute (robust). Anything bright/noisy.
    hat_votes = (
        (cents >= HIHAT_CENTROID).astype(np.int32)
        + (rolls >= HIHAT_ROLLOFF).astype(np.int32)
        + (zcrs >= HIHAT_ZCR).astype(np.int32)
        + (highs >= HIHAT_HIGH_RATIO).astype(np.int32)
    )
    is_hat = (zcrs >= HIHAT_ZCR) | ((hat_votes >= 2) & (cents >= 3000.0))
    out = [HIHAT if is_hat[i] else base[i] for i in range(n)]

    rest = [i for i in range(n) if not is_hat[i]]
    if len(rest) >= 2:
        rc = cents[rest]
        spread = float(rc.max() - rc.min())
        srt = np.sort(rc)
        gaps = np.diff(srt)
        max_gap = float(gaps.max()) if gaps.size else 0.0
        if spread >= KICK_SNARE_MIN_SPREAD and max_gap >= KICK_SNARE_GAP_FRAC * spread:
            # bimodal — split at the natural break (midpoint of the largest gap)
            gi = int(np.argmax(gaps))
            thresh = float((srt[gi] + srt[gi + 1]) / 2.0)
            for i in rest:
                out[i] = KICK if cents[i] <= thresh else SNARE
        else:
            # uniform cluster — all one type, decided by an absolute anchor
            label = KICK if float(rc.mean()) <= KICK_SNARE_ANCHOR else SNARE
            for i in rest:
                out[i] = label
    return out
