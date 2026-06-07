"""Drum onset detection + onset-synchronous note building (as_drums mode).

Pure DSP (librosa spectral-flux onsets + numpy), no model / no training. Used
only when ``AnalyzeOptions.as_drums`` is set (drum-role tracks). Emits one note
per onset, classified by timbre via ``drums.classify_features`` — independent of
pYIN pitch, so unpitched percussion (hi-hats) no longer disappears the way it
does in the melodic pipeline (which drops chunks pYIN can't pitch).

This module never touches the melodic path, so the auto-percussive misfire bug
(commit 3265742, weak humming flipping to drums) cannot return.
"""
from __future__ import annotations

from typing import Callable, List, Tuple

import numpy as np
import librosa

from .schemas import Note
from .drums import classify_features, classify_take, GM_NAMES
from . import drum_classifier
from .drum_features import extract as extract_drum_features


def _norm_env(x: np.ndarray) -> np.ndarray:
    x = np.asarray(x, dtype=np.float64)
    if x.size == 0:
        return x
    lo = float(np.percentile(x, 10))
    hi = float(np.percentile(x, 98))
    if hi <= lo + 1e-12:
        return np.zeros_like(x, dtype=np.float64)
    return np.clip((x - lo) / (hi - lo), 0.0, 1.0)


def _align_len(x: np.ndarray, n: int) -> np.ndarray:
    if x.size == n:
        return x
    if x.size > n:
        return x[:n]
    return np.pad(x, (0, n - x.size))


def _band_flux_envelope(y: np.ndarray, sr: int, hop: int, base: np.ndarray) -> np.ndarray:
    """Combine full-band onset strength with low/mid/high-band flux.

    Beatboxed drums often have class-specific transients: kicks can be strongest
    in the low-mid body, hats in noisy highs, and snares in broadband mids. A
    single full-band envelope can under-rank one of those, so use band envelopes
    as additional onset evidence while keeping librosa's full-band curve as the
    anchor.
    """
    if y.size < 1024:
        return base
    try:
        n_fft = 1024
        spec = np.abs(librosa.stft(y, n_fft=n_fft, hop_length=hop, center=True))
        freqs = librosa.fft_frequencies(sr=sr, n_fft=n_fft)
    except Exception:
        return base

    n = base.size
    combined = 0.55 * _norm_env(base)
    for lo, hi, weight in (
        (45.0, 260.0, 0.16),
        (260.0, 2500.0, 0.17),
        (2500.0, min(11000.0, sr / 2.0), 0.12),
    ):
        mask = (freqs >= lo) & (freqs < hi)
        if not np.any(mask):
            continue
        energy = np.log1p(spec[mask].sum(axis=0))
        flux = np.maximum(0.0, np.diff(energy, prepend=energy[0]))
        combined += weight * _align_len(_norm_env(flux), n)
    return _norm_env(combined)


def detect_onsets(
    y: np.ndarray,
    sr: int,
    hop: int = 256,
    delta: float = 0.06,
    wait_frames: int = 3,
    pre_max: int = 3,
    post_max: int = 3,
    pre_avg: int = 10,
    post_avg: int = 10,
    min_interval_sec: float = 0.08,
) -> Tuple[np.ndarray, np.ndarray]:
    """Return ``(onset_times_sec, onset_strength_at_each_onset)``.

    Spectral-flux onset envelope → peak-pick. ``backtrack=False`` so each
    detected peak marks the transient itself; classification then reads a short
    *forward* window from it (delayed-decision — keeps the next hit out of the
    window). ``delta`` (peak threshold above local mean) is the main sensitivity
    knob.

    ``min_interval_sec`` then merges onsets closer than this, keeping the
    STRONGER peak — a single drum hit's attack-click and body can fire two
    onsets ~50-60ms apart; greedy ``wait`` would keep the (bright) click, so we
    keep the stronger (body) instead.
    """
    if y.size < hop * 2:
        return np.array([]), np.array([])
    base_oenv = librosa.onset.onset_strength(y=y, sr=sr, hop_length=hop)
    oenv = _band_flux_envelope(y, sr, hop, base_oenv)
    frames = librosa.onset.onset_detect(
        onset_envelope=oenv, sr=sr, hop_length=hop, backtrack=False,
        pre_max=pre_max, post_max=post_max, pre_avg=pre_avg, post_avg=post_avg,
        delta=delta, wait=wait_frames,
    )
    if len(frames) == 0:
        return np.array([]), np.array([])

    # merge close double-triggers, keeping the stronger peak
    min_gap = min_interval_sec * sr / hop
    kept = [int(frames[0])]
    for fr in frames[1:]:
        fr = int(fr)
        if fr - kept[-1] < min_gap:
            if oenv[fr] > oenv[kept[-1]]:
                kept[-1] = fr
        else:
            kept.append(fr)
    frames = np.asarray(kept)

    times = librosa.frames_to_time(frames, sr=sr, hop_length=hop)
    strength = oenv[frames].astype(float)
    return times, strength


# 드럼도 일정 세기 — 강약(velocity 변동) 없이 균일하게(사용자 요청: "다 일정").
FLAT_VELOCITY = 100


def _velocity(peak_rms: float, global_peak: float) -> int:
    """Uniform velocity for every drum hit (no amplitude-derived dynamics)."""
    return FLAT_VELOCITY


def build_drum_notes(
    y: np.ndarray,
    sr: int,
    classify_fn: Callable = classify_features,
    hop: int = 256,
    win_sec: float = 0.045,
    max_note_sec: float = 0.18,
    min_peak_ratio: float = 0.12,
    global_peak_rms: float | None = None,
    detect_kwargs: dict | None = None,
) -> List[Note]:
    """One timbre-classified Note per onset. Independent of pYIN pitch.

    win_sec    — forward window from the onset used for timbre classification.
    max_note_sec — cap on note length (a one-shot drum decays naturally in the
                   soundfont; end time is mostly cosmetic).
    min_peak_ratio — skip onsets whose window peak amplitude is below this
                   fraction of the take's peak. Kills the spectral-flux false
                   onset on the recording's silence→fade-in ramp (a real hit is
                   far louder than that start noise).
    """
    times, strengths = detect_onsets(y, sr, hop=hop, **(detect_kwargs or {}))
    if times.size == 0:
        return []

    if global_peak_rms is None:
        rms = librosa.feature.rms(y=y, frame_length=1024, hop_length=hop)[0]
        global_peak_rms = float(np.max(rms)) if rms.size else 1.0
    str_max = float(np.max(strengths)) if strengths.size else 1.0
    global_peak_amp = float(np.max(np.abs(y))) if y.size else 1.0

    win = int(win_sec * sr)
    win_long = int(0.120 * sr)  # longer window for the model's sustain/decay feature

    # Pass 1: per-onset features (absolute baseline). Keep only onsets that pass
    # the amplitude gate, tracking their original index for note timing.
    kept: List[dict] = []
    for i, t in enumerate(times):
        a = int(round(float(t) * sr))
        b = min(len(y), a + win)
        seg = y[a:b]
        # amplitude gate: a real hit is loud; the start fade-in / handling noise
        # that spectral flux false-triggers on is not.
        if seg.size == 0 or float(np.max(np.abs(seg))) < min_peak_ratio * global_peak_amp:
            continue
        seg_long = y[a:min(len(y), a + win_long)]
        kept.append({"i": i, "t": float(t), "seg": seg, "seg_long": seg_long,
                     "feat": extract_drum_features(seg, seg_long, sr),
                     "hit": classify_fn(seg, sr)})

    if not kept:
        return []

    # Pass 2: label each hit. The local voice model (drum_classifier) wins when
    # present — it's the only thing that separates voiced snare from hi-hat
    # (~70% feature overlap). Without a model, fall back to the within-take
    # relative heuristic. Either way the DrumHit features are kept for debug.
    if drum_classifier.available():
        take_notes = [
            drum_classifier.predict_segment(k["seg"], k["seg_long"], sr) or k["hit"].gm_note
            for k in kept
        ]
    else:
        take_notes = classify_take([k["hit"] for k in kept])

    notes: List[Note] = []
    for k, gm in zip(kept, take_notes):
        i, t, seg, hit, feat = k["i"], k["t"], k["seg"], k["hit"], k["feat"]

        # note end = next onset, clamped so a sparse hit isn't an over-long note
        nxt = float(times[i + 1]) if i + 1 < times.size else float(t) + max_note_sec
        end = min(nxt, float(t) + max_note_sec)
        if end <= float(t):
            end = float(t) + 0.03

        peak_rms = float(np.sqrt(np.mean(seg ** 2))) if seg.size else 0.0
        strength_norm = float(strengths[i] / str_max) if str_max > 0 else 0.0
        gm_name = GM_NAMES.get(gm, hit.name)

        notes.append(Note(
            start=float(t), end=float(end), duration=float(end - float(t)),
            pitch=int(gm),
            pitch_raw=float(gm),
            pitch_hz=0.0,
            velocity=_velocity(peak_rms, global_peak_rms),
            confidence=strength_norm,
            voiced_ratio=0.0,
            kind="percussive",
            pitch_original=int(gm),
            drum=int(gm),
            drum_name=gm_name,
            drum_centroid=hit.centroid,
            drum_low_ratio=hit.low_ratio,
            drum_high_ratio=hit.high_ratio,
            drum_zcr=hit.zcr,
            drum_rolloff=hit.rolloff,
            drum_flatness=hit.flatness,
            # classifier-input band/sustain features (FEATURE_NAMES order: 6,7,8,9)
            drum_lowmid_ratio=float(feat[6]),
            drum_mid_ratio=float(feat[7]),
            drum_vhigh_ratio=float(feat[8]),
            drum_sustain_ratio=float(feat[9]),
            onset_strength=float(strengths[i]),
        ))
    return notes
