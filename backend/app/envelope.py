"""Stage 3-4 — envelope-based voice region detection and chunk segmentation.

Pure DSP module. No I/O, no schemas. Returns plain dicts/arrays so callers
can serialize them however they want.

Conceptually streaming: ``segment_chunks_streaming`` runs a single forward
pass over the RMS envelope, just like a human watching the waveform from
left to right. The actual implementation is batch but the function body
never looks backwards — it can be lifted into a real streaming loop unchanged.

Parameters here are passed in directly by the caller (no preset table) so the
defaults live in ``schemas.AnalyzeOptions``. This keeps the tuning surface
in exactly one place.
"""
from __future__ import annotations

from typing import Dict, List, Tuple

import numpy as np
import librosa
from scipy.signal import medfilt


def compute_rms_envelope(
    y: np.ndarray,
    sr: int,
    hop: int = 256,
    frame: int = 1024,
    smooth_window: int = 5,
) -> Tuple[np.ndarray, np.ndarray]:
    """Return ``(times, rms)`` aligned frame-by-frame.

    ``smooth_window`` is the median filter kernel applied to the raw RMS
    (default 5 ≈ 58 ms at sr=22050, hop=256). Removes single-frame spikes.
    """
    rms = librosa.feature.rms(y=y, frame_length=frame, hop_length=hop)[0]
    if smooth_window > 1:
        k = smooth_window if smooth_window % 2 == 1 else smooth_window + 1
        rms = medfilt(rms.astype(np.float64), kernel_size=k).astype(np.float32)
    times = librosa.times_like(rms, sr=sr, hop_length=hop)
    return times, rms


def compute_thresholds(
    rms: np.ndarray,
    enter_ratio: float = 0.20,
    exit_ratio: float = 0.12,
    noise_pct: float = 15.0,
    peak_pct: float = 95.0,
) -> Dict[str, float]:
    """Adaptive hysteresis thresholds derived from the RMS distribution.

    ``peak_pct=95`` rather than ``max`` so a single loud transient doesn't
    inflate the range.
    """
    if rms.size == 0:
        return {"noise_floor": 0.0, "peak_level": 0.0, "enter": 0.0, "exit": 0.0}
    noise_floor = float(np.percentile(rms, noise_pct))
    peak_level = float(np.percentile(rms, peak_pct))
    dyn = max(peak_level - noise_floor, 1e-6)
    return {
        "noise_floor": noise_floor,
        "peak_level": peak_level,
        "enter": noise_floor + dyn * enter_ratio,
        "exit": noise_floor + dyn * exit_ratio,
    }


def segment_chunks_streaming(
    rms: np.ndarray,
    times: np.ndarray,
    enter: float,
    exit_: float,
    exit_hold_sec: float = 0.025,
) -> List[Dict[str, float]]:
    """Single forward pass state machine (silence ⇄ active) with hysteresis."""
    if rms.size < 2 or times.size != rms.size:
        return []
    dt = float(times[1] - times[0])
    hold_frames = max(1, int(round(exit_hold_sec / dt)))

    chunks: List[Dict[str, float]] = []
    state = "silence"
    start_t: float | None = None
    below = 0
    peak = 0.0

    for i in range(rms.size):
        val = float(rms[i])
        t = float(times[i])
        if state == "silence":
            if val > enter:
                state = "active"
                start_t = t
                below = 0
                peak = val
        else:  # active
            if val > peak:
                peak = val
            if val < exit_:
                below += 1
                if below >= hold_frames:
                    end_t = float(times[max(0, i - below)])
                    chunks.append({"start": float(start_t), "end": end_t, "peak_rms": peak})
                    state = "silence"
                    start_t = None
                    below = 0
                    peak = 0.0
            else:
                below = 0
    if state == "active" and start_t is not None:
        chunks.append({"start": float(start_t), "end": float(times[-1]), "peak_rms": peak})
    return chunks


def post_process_chunks(
    chunks: List[Dict[str, float]],
    min_chunk_dur_sec: float = 0.06,
    merge_gap_sec: float = 0.04,
) -> List[Dict[str, float]]:
    """Merge tight neighbors then drop too-short fragments.

    Order matters: merge first so a real note split into two near-touching
    chunks rejoins before the min-duration filter sees the pieces.
    """
    if not chunks:
        return []
    merged: List[Dict[str, float]] = [dict(chunks[0])]
    for c in chunks[1:]:
        gap = c["start"] - merged[-1]["end"]
        if gap < merge_gap_sec:
            merged[-1]["end"] = c["end"]
            merged[-1]["peak_rms"] = max(merged[-1]["peak_rms"], c["peak_rms"])
        else:
            merged.append(dict(c))
    return [c for c in merged if (c["end"] - c["start"]) >= min_chunk_dur_sec]


# -- internal subdivision (used for "C3-C3-C3 legato" + "G#3 → C3 legato") -----

def split_chunk_by_pitch(
    chunk: Dict[str, float],
    pitch_times: np.ndarray,
    pitch_midi: np.ndarray,
    min_change_semitones: float = 1.0,
    min_hold_sec: float = 0.12,
    min_split_gap_sec: float = 0.10,
) -> List[Dict[str, float]]:
    """Split a long chunk where the smoothed pitch contour transitions to a new
    anchor pitch (≥``min_change_semitones`` held for ≥``min_hold_sec``)."""
    t0, t1 = chunk["start"], chunk["end"]
    idx = np.where((pitch_times >= t0) & (pitch_times <= t1))[0]
    if idx.size < 8:
        return [chunk]
    seg_t = pitch_times[idx]
    seg_m = pitch_midi[idx]

    nan_mask = ~np.isfinite(seg_m)
    if nan_mask.any():
        filled = seg_m.copy()
        finite_vals = seg_m[~nan_mask]
        fill_val = float(np.median(finite_vals)) if finite_vals.size else 0.0
        filled[nan_mask] = fill_val
        m_smooth = medfilt(filled, kernel_size=5)
        m_smooth[nan_mask] = np.nan
    else:
        m_smooth = medfilt(seg_m, kernel_size=5)

    dt = float(seg_t[1] - seg_t[0]) if seg_t.size > 1 else 0.01
    hold_frames = max(1, int(round(min_hold_sec / dt)))

    voiced = np.isfinite(m_smooth)
    if voiced.sum() < 5:
        return [chunk]
    first_voiced_idx = np.where(voiced)[0][:5]
    anchor = float(np.median(m_smooth[first_voiced_idx]))

    splits: List[float] = [t0]
    streak = 0
    candidate_pitch = anchor
    i = first_voiced_idx[-1] + 1
    while i < m_smooth.size:
        v = m_smooth[i]
        if not np.isfinite(v):
            streak = 0; i += 1; continue
        if abs(v - anchor) >= min_change_semitones:
            if streak == 0:
                candidate_pitch = v; streak = 1
            elif abs(v - candidate_pitch) <= 0.5:
                streak += 1
            else:
                candidate_pitch = v; streak = 1
            if streak >= hold_frames:
                split_t = float(seg_t[i - hold_frames + 1])
                if split_t - splits[-1] >= min_split_gap_sec:
                    splits.append(split_t); anchor = candidate_pitch
                streak = 0
        else:
            streak = 0
        i += 1
    splits.append(t1)
    if len(splits) <= 2:
        return [chunk]
    return [
        {"start": float(splits[k]), "end": float(splits[k + 1]), "peak_rms": chunk["peak_rms"]}
        for k in range(len(splits) - 1)
    ]


def split_chunk_by_rms_dip(
    chunk: Dict[str, float],
    env_times: np.ndarray,
    env_rms: np.ndarray,
    dip_ratio: float = 0.40,
    min_sub_chunk_sec: float = 0.12,
    neighborhood_frames: int = 4,
) -> List[Dict[str, float]]:
    """Split a long chunk on internal RMS local minima that fall to ≤
    ``dip_ratio * chunk_peak``. Targets "same note repeated softly" — pitch
    doesn't change so ``split_chunk_by_pitch`` is blind to it."""
    t0, t1 = chunk["start"], chunk["end"]
    lo = int(np.searchsorted(env_times, t0))
    hi = int(np.searchsorted(env_times, t1, side="right"))
    if hi - lo < neighborhood_frames * 2 + 3:
        return [chunk]
    seg = env_rms[lo:hi]; seg_t = env_times[lo:hi]
    peak = float(seg.max())
    if peak <= 0:
        return [chunk]
    threshold = peak * dip_ratio

    W = neighborhood_frames
    candidates: List[Tuple[float, float]] = []
    for i in range(W, len(seg) - W):
        v = float(seg[i])
        if v > threshold:
            continue
        window = seg[i - W:i + W + 1]
        if v <= float(window.min()) + 1e-9:
            candidates.append((float(seg_t[i]), v))
    if not candidates:
        return [chunk]

    deduped: List[Tuple[float, float]] = []
    for t, v in candidates:
        if deduped and (t - deduped[-1][0]) < min_sub_chunk_sec:
            if v < deduped[-1][1]:
                deduped[-1] = (t, v)
            continue
        deduped.append((t, v))

    splits = [t0]
    for t, _ in deduped:
        if (t - splits[-1]) >= min_sub_chunk_sec and (t1 - t) >= min_sub_chunk_sec:
            splits.append(t)
    splits.append(t1)
    if len(splits) <= 2:
        return [chunk]
    return [
        {"start": float(splits[k]), "end": float(splits[k + 1]), "peak_rms": chunk["peak_rms"]}
        for k in range(len(splits) - 1)
    ]


# Subdivision is only applied to chunks longer than this — protects vibrato
# from being treated as a transition / dip. Set just below the "two short
# notes share one envelope chunk" cases observed in sample 4 (Du): chunks of
# ~0.35 s with a clearly deeper-than-vibrato internal dip.
SUBDIVISION_MIN_CHUNK_DUR_SEC = 0.30
