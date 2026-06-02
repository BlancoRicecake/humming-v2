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
from .drums import classify_features


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
    oenv = librosa.onset.onset_strength(y=y, sr=sr, hop_length=hop)
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


def _velocity(peak_rms: float, global_peak: float) -> int:
    """Map a hit's peak RMS into MIDI velocity 20-120 (mirrors analyze._chunk_velocity)."""
    if global_peak <= 1e-6:
        return 64
    ratio = float(np.clip(peak_rms / global_peak, 0.0, 1.0))
    return int(max(1, min(127, round(20 + ratio * 100))))


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
    notes: List[Note] = []
    for i, t in enumerate(times):
        a = int(round(float(t) * sr))
        b = min(len(y), a + win)
        seg = y[a:b]
        # amplitude gate: a real hit is loud; the start fade-in / handling noise
        # that spectral flux false-triggers on is not.
        if seg.size == 0 or float(np.max(np.abs(seg))) < min_peak_ratio * global_peak_amp:
            continue
        hit = classify_fn(seg, sr)

        # note end = next onset, clamped so a sparse hit isn't an over-long note
        nxt = float(times[i + 1]) if i + 1 < times.size else float(t) + max_note_sec
        end = min(nxt, float(t) + max_note_sec)
        if end <= float(t):
            end = float(t) + 0.03

        peak_rms = float(np.sqrt(np.mean(seg ** 2))) if seg.size else 0.0
        strength_norm = float(strengths[i] / str_max) if str_max > 0 else 0.0

        notes.append(Note(
            start=float(t), end=float(end), duration=float(end - float(t)),
            pitch=int(hit.gm_note),
            pitch_raw=float(hit.gm_note),
            pitch_hz=0.0,
            velocity=_velocity(peak_rms, global_peak_rms),
            confidence=strength_norm,
            voiced_ratio=0.0,
            kind="percussive",
            pitch_original=int(hit.gm_note),
            drum=int(hit.gm_note),
            drum_name=hit.name,
            drum_centroid=hit.centroid,
            drum_low_ratio=hit.low_ratio,
            drum_high_ratio=hit.high_ratio,
            drum_zcr=hit.zcr,
            drum_rolloff=hit.rolloff,
            drum_flatness=hit.flatness,
            onset_strength=float(strengths[i]),
        ))
    return notes
