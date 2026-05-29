"""Auto Key detection — Krumhansl-Schmuckler key finding (major/minor only).

Pure DSP / arithmetic (numpy). No I/O, no model, no training. Given a
duration-weighted pitch-class histogram, correlate it against the 24 rotated
Krumhansl-Kessler key profiles and return the best (tonic, mode).
"""
from __future__ import annotations

from typing import List, Optional, Tuple

import numpy as np

# Krumhansl-Kessler tone profiles (perceived stability of each scale degree).
KK_MAJOR = np.array(
    [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
)
KK_MINOR = np.array(
    [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]
)

PC_NAMES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

# --- tuning constants (adjust after reviewing diagnose.py dumps) ---
KEY_CONF_HIGH = 0.15      # >= : full assistant
KEY_CONF_LOW = 0.05       # <  : suppress auto-correction (recommend only)
DURATION_CAP = 0.8        # seconds — cap so one long note can't dominate the key
CONF_FLOOR = 0.10         # min pitch-confidence weight contribution
VOICED_FLOOR = 0.15       # min voiced-ratio weight contribution
MIN_NOTES_FULL = 4        # fewer pitched notes → confidence penalty
MIN_UNIQUE_PC = 3         # fewer distinct pitch classes → confidence penalty
MIN_TOTAL_DUR = 1.0       # seconds — shorter total → confidence penalty


def build_pc_histogram(midi_values: List[int], weights: List[float]) -> np.ndarray:
    """Weighted 12-bin pitch-class histogram."""
    hist = np.zeros(12, dtype=np.float64)
    for m, w in zip(midi_values, weights):
        if m is None or not np.isfinite(m):
            continue
        hist[int(round(m)) % 12] += max(float(w), 0.0)
    return hist


def key_weight(duration: float, confidence: float, voiced_ratio: float) -> float:
    """Per-note contribution to the key histogram.

    Caps duration (so one long sustain can't dominate), down-weights low
    pitch-confidence / low-voiced notes. Floors keep borrowed/weak notes from
    contributing zero but small.
    """
    d = min(float(duration), DURATION_CAP)
    c = min(max(float(confidence), CONF_FLOOR), 1.0)
    v = min(max(float(voiced_ratio), VOICED_FLOOR), 1.0)
    return d * c * v


def _pearson(a: np.ndarray, b: np.ndarray) -> float:
    a = a - a.mean()
    b = b - b.mean()
    denom = float(np.sqrt((a * a).sum() * (b * b).sum()))
    if denom <= 1e-12:
        return 0.0
    return float((a * b).sum() / denom)


def score_keys(hist: np.ndarray) -> List[Tuple[float, str, str]]:
    """All 24 keys scored by correlation, descending: ``(corr, tonic_name, mode)``."""
    scored: List[Tuple[float, str, str]] = []
    for tonic in range(12):
        scored.append((_pearson(hist, np.roll(KK_MAJOR, tonic)), PC_NAMES[tonic], "major"))
        scored.append((_pearson(hist, np.roll(KK_MINOR, tonic)), PC_NAMES[tonic], "minor"))
    scored.sort(key=lambda x: x[0], reverse=True)
    return scored


def detect_key(
    hist: np.ndarray,
    n_notes: Optional[int] = None,
    total_dur: Optional[float] = None,
    min_weight: float = 1e-6,
) -> Tuple[Optional[str], Optional[str], float]:
    """Return ``(tonic_name, "major"|"minor", confidence)``.

    Base ``confidence`` is the margin between the best and second-best
    correlation, then multiplied by guard penalties for thin input (few notes /
    few distinct pitch classes / short total duration) so short hummings end up
    low-confidence and the assistant treats them conservatively. Flat / empty
    histogram → (None, None, 0.0).
    """
    if hist is None or hist.sum() <= min_weight or np.ptp(hist) <= 1e-9:
        return None, None, 0.0

    scored = score_keys(hist)
    best_corr, best_tonic, best_mode = scored[0]
    second_corr = scored[1][0] if len(scored) > 1 else 0.0
    confidence = max(0.0, best_corr - second_corr)
    if best_corr <= 0.0:
        return None, None, 0.0

    # --- guard penalties for thin / unreliable input ---
    penalty = 1.0
    if n_notes is not None and n_notes < MIN_NOTES_FULL:
        penalty *= n_notes / MIN_NOTES_FULL
    unique_pc = int((hist > 0).sum())
    if unique_pc < MIN_UNIQUE_PC:
        penalty *= 0.5
    if total_dur is not None and total_dur < MIN_TOTAL_DUR:
        penalty *= total_dur / MIN_TOTAL_DUR
    confidence *= penalty

    return best_tonic, best_mode, confidence
