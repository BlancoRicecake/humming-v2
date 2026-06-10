"""Shared spectral feature extraction for the drum-voice classifier.

ONE source of truth for the feature vector so the offline trainer
(train_drum_classifier_model.py) and the runtime classifier (drum_classifier.py)
never drift. Pure numpy, no model here.

Feature design follows the AVP analysis (docs/experiments/drum_pipeline_90_plan.md):
the raw timbre axes (centroid/rolloff/zcr/flatness) separate kick from the bright
pair, and the band-energy ratios (low-mid body vs very-high air) plus temporal
sustain are what give a linear model any purchase on voiced snare vs hi-hat.
"""
from __future__ import annotations

import numpy as np

FEATURE_NAMES = [
    "centroid",
    "log_centroid",
    "rolloff",
    "zcr",
    "flatness",
    "high_ratio",       # > 5000 Hz
    "lowmid_200_2k",    # 200-2000 Hz  (snare/kick body)
    "mid_500_3k",       # 500-3000 Hz
    "vhigh_8k",         # > 8000 Hz    (hi-hat air)
    "sustain_ratio",    # 2nd-half / 1st-half RMS over the long window
]

SPECTRAL_BANDS = (
    (80.0, 180.0, "band_80_180"),
    (180.0, 350.0, "band_180_350"),
    (350.0, 700.0, "band_350_700"),
    (700.0, 1400.0, "band_700_1400"),
    (1400.0, 2800.0, "band_1400_2800"),
    (2800.0, 5600.0, "band_2800_5600"),
    (5600.0, 9000.0, "band_5600_9000"),
    (9000.0, 24000.0, "band_9000_plus"),
)

FEATURE_NAMES_V2 = FEATURE_NAMES + [
    name for _, _, name in SPECTRAL_BANDS
] + [
    "ratio_mid_vhigh",
    "ratio_lowmid_vhigh",
    "early_rms_ratio",
    "body_rms_ratio",
    "tail_rms_ratio",
    "early_zcr",
    "tail_zcr",
]


def feature_names(version: str = "v1") -> list[str]:
    """Return the feature contract for a saved drum classifier model."""
    return list(FEATURE_NAMES_V2 if version == "v2" else FEATURE_NAMES)


def extract(seg: np.ndarray, seg_long: np.ndarray | None, sr: int) -> list[float]:
    """Return the feature vector (order == FEATURE_NAMES) for one onset segment.

    ``seg`` is the short timbre window (~45 ms). ``seg_long`` is an optional
    longer window (~120 ms) used only for the sustain/decay feature; falls back
    to ``seg`` when not supplied.
    """
    seg = np.asarray(seg, dtype=np.float64)
    if seg.size < 64:
        return [0.0] * len(FEATURE_NAMES)

    n = seg.size
    spec = np.abs(np.fft.rfft(seg * np.hanning(n)))
    freqs = np.fft.rfftfreq(n, 1.0 / sr)
    total = float(spec.sum()) + 1e-12

    centroid = float((freqs * spec).sum()) / total
    zcr = float(np.mean(np.abs(np.diff(np.sign(seg))))) / 2.0

    cumulative = np.cumsum(spec)
    roll_idx = min(int(np.searchsorted(cumulative, 0.85 * cumulative[-1])), freqs.size - 1)
    rolloff = float(freqs[roll_idx])

    power = spec ** 2 + 1e-12
    flatness = float(np.exp(np.mean(np.log(power))) / (np.mean(power) + 1e-12))

    def band(lo: float, hi: float) -> float:
        return float(spec[(freqs >= lo) & (freqs < hi)].sum()) / total

    high_ratio = band(5000.0, sr / 2.0)
    lowmid = band(200.0, 2000.0)
    mid = band(500.0, 3000.0)
    vhigh = band(8000.0, sr / 2.0)

    sl = np.asarray(seg_long if seg_long is not None else seg, dtype=np.float64)
    half = sl.size // 2
    if half > 16:
        e1 = float(np.sqrt(np.mean(sl[:half] ** 2))) + 1e-9
        e2 = float(np.sqrt(np.mean(sl[half:] ** 2))) + 1e-9
        sustain = e2 / e1
    else:
        sustain = 0.0

    return [
        centroid,
        float(np.log1p(centroid)),
        rolloff,
        zcr,
        flatness,
        high_ratio,
        lowmid,
        mid,
        vhigh,
        float(sustain),
    ]


def _zcr(x: np.ndarray) -> float:
    return float(np.mean(np.abs(np.diff(np.sign(x))))) / 2.0 if x.size > 1 else 0.0


def _rms(x: np.ndarray) -> float:
    return float(np.sqrt(np.mean(x ** 2))) if x.size else 0.0


def extract_v2(seg: np.ndarray, seg_long: np.ndarray | None, sr: int) -> list[float]:
    """Richer AVP-oriented feature vector for the v2 drum-voice model.

    v1 is intentionally kept stable for the shipped ``drum_classifier_v1.npz``.
    v2 adds narrow normalized spectral bands plus simple early/body/tail shape
    cues, which target the AVP failure mode where voiced snare and hi-hat share
    broad brightness but differ in body/air balance and decay.
    """
    base = extract(seg, seg_long, sr)
    seg = np.asarray(seg, dtype=np.float64)
    if seg.size < 64:
        return [0.0] * len(FEATURE_NAMES_V2)

    n = seg.size
    spec = np.abs(np.fft.rfft(seg * np.hanning(n)))
    freqs = np.fft.rfftfreq(n, 1.0 / sr)
    total = float(spec.sum()) + 1e-12

    bands: list[float] = []
    for lo, hi, _ in SPECTRAL_BANDS:
        upper = min(hi, sr / 2.0)
        if upper <= lo:
            bands.append(0.0)
        else:
            bands.append(float(spec[(freqs >= lo) & (freqs < upper)].sum()) / total)

    mid = base[7]
    lowmid = base[6]
    vhigh = base[8]
    ratio_mid_vhigh = (mid + 1e-6) / (vhigh + 1e-6)
    ratio_lowmid_vhigh = (lowmid + 1e-6) / (vhigh + 1e-6)

    sl = np.asarray(seg_long if seg_long is not None else seg, dtype=np.float64)
    if sl.size < 64:
        early = body = tail = np.asarray([], dtype=np.float64)
    else:
        early_n = max(1, min(sl.size, int(round(0.015 * sr))))
        body_n = max(early_n + 1, min(sl.size, int(round(0.045 * sr))))
        early = sl[:early_n]
        body = sl[early_n:body_n]
        tail = sl[body_n:]
    total_rms = _rms(sl) + 1e-9
    early_rms_ratio = _rms(early) / total_rms
    body_rms_ratio = _rms(body) / total_rms
    tail_rms_ratio = _rms(tail) / total_rms

    return base + bands + [
        float(ratio_mid_vhigh),
        float(ratio_lowmid_vhigh),
        float(early_rms_ratio),
        float(body_rms_ratio),
        float(tail_rms_ratio),
        float(_zcr(early)),
        float(_zcr(tail)),
    ]


def extract_for_names(names: list[str], seg: np.ndarray, seg_long: np.ndarray | None, sr: int) -> list[float]:
    """Extract the feature vector matching a saved model's feature names."""
    if list(names) == list(FEATURE_NAMES_V2):
        return extract_v2(seg, seg_long, sr)
    if list(names) == list(FEATURE_NAMES):
        return extract(seg, seg_long, sr)
    raise ValueError(f"unknown drum feature contract: {names}")
