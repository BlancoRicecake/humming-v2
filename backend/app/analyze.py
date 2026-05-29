"""SoundLab — voice-to-MIDI analysis pipeline (Stages 2-7 of the 9-stage map).

The full 9 stages (Stage 1 = browser recorder, Stages 8-9 = client playback +
MIDI download) are mapped to clearly-labelled sections below. Each new
feature should land inside the stage it belongs to so the structure stays
visible.
"""
from __future__ import annotations

import io
import math
import tempfile
import os
import uuid
from typing import List, Tuple

import numpy as np
import librosa
import soundfile as sf
from scipy.signal import medfilt

from .schemas import (
    AnalyzeOptions,
    AnalyzeResponse,
    Chunk,
    DetectedKey,
    EnvelopeInfo,
    KeyCandidate,
    Note,
    PitchTrack,
    Waveform,
)
from .envelope import (
    SUBDIVISION_MIN_CHUNK_DUR_SEC,
    compute_rms_envelope,
    compute_thresholds,
    post_process_chunks,
    segment_chunks_streaming,
    split_chunk_by_pitch,
    split_chunk_by_rms_dip,
)
from .pitch import extract_pitch_pyin, hz_to_midi_float
from .assistant import run_key_and_assistant
from .drums import classify_drum


TARGET_SR = 22050
HOP = 256


# ============================================================================
# Stage 2 — Preprocessing
# ============================================================================
def _load_audio(file_bytes: bytes) -> Tuple[np.ndarray, int]:
    """Decode any audio blob into mono float32 PCM at TARGET_SR."""
    bio = io.BytesIO(file_bytes)
    try:
        y, sr = sf.read(bio, dtype="float32", always_2d=False)
    except Exception:
        # m4a/mp3 etc. — librosa.load with audioread fallback needs a file path
        tmp = tempfile.NamedTemporaryFile(suffix=".audio", delete=False)
        try:
            tmp.write(file_bytes); tmp.flush(); tmp.close()
            y, sr = librosa.load(tmp.name, sr=None, mono=True)
        finally:
            try: os.unlink(tmp.name)
            except OSError: pass
    if y.ndim > 1:
        y = np.mean(y, axis=1)
    if sr != TARGET_SR:
        y = librosa.resample(y, orig_sr=sr, target_sr=TARGET_SR); sr = TARGET_SR
    peak = float(np.max(np.abs(y))) if y.size else 0.0
    if peak > 1e-6:
        y = y * (0.99 / max(peak, 0.99))
    return y.astype(np.float32), sr


def _downsample_for_display(y: np.ndarray, target_points: int = 1500) -> List[float]:
    if len(y) == 0:
        return []
    bucket = max(1, len(y) // target_points)
    n = (len(y) // bucket) * bucket
    return np.abs(y[:n]).reshape(-1, bucket).max(axis=1).astype(float).tolist()


# ============================================================================
# Vocal — 목소리 그대로(악기 변환 X). 가벼운 정리: 하이패스 + 소프트 노이즈 게이트
# ============================================================================
def denoise_vocal_light(y: np.ndarray, sr: int) -> np.ndarray:
    """80Hz 하이패스로 럼블/핸들링 제거 + 조용한 프레임 소프트 감쇠(완전 뮤트 X).
    목소리 자연스러움을 유지하는 '가벼운 정리' 수준."""
    from scipy.signal import butter, sosfilt
    if y.size == 0:
        return y
    sos = butter(2, 80.0 / (sr / 2), btype="highpass", output="sos")
    y = sosfilt(sos, y).astype(np.float32)

    frame, hop = 1024, 256
    rms = librosa.feature.rms(y=y, frame_length=frame, hop_length=hop)[0]
    if rms.size:
        noise = float(np.percentile(rms, 10))
        thr = noise * 1.8
        gain = np.ones_like(rms)
        gain[rms < thr] = 0.35  # ≈ -9 dB, 숨소리/배경만 살짝 누름
        gain = medfilt(gain, kernel_size=5)
        g = np.interp(np.arange(len(y)), np.arange(len(gain)) * hop, gain).astype(np.float32)
        y = y * g

    peak = float(np.max(np.abs(y))) if y.size else 0.0
    if peak > 1e-6:
        y = y * (0.99 / max(peak, 0.99))
    return y.astype(np.float32)


def process_vocal(file_bytes: bytes, denoise: bool = True) -> Tuple[bytes, List[float], float, int]:
    """업로드 WAV → (정리된 WAV bytes, 표시용 peaks, duration, sr)."""
    y, sr = _load_audio(file_bytes)
    if denoise:
        y = denoise_vocal_light(y, sr)
    buf = io.BytesIO()
    sf.write(buf, y, sr, format="WAV", subtype="PCM_16")
    return buf.getvalue(), _downsample_for_display(y, 400), (len(y) / sr if sr else 0.0), sr


# ============================================================================
# Stage 5 — per-chunk representative pitch
# ============================================================================
def _chunk_pitch(
    pitch_times: np.ndarray,
    pitch_midi: np.ndarray,
    voiced_prob: np.ndarray,
    t0: float,
    t1: float,
    voiced_threshold: float,
    trim_head: float = 0.15,
    trim_tail: float = 0.25,
) -> Tuple[float, float, float]:
    """Return ``(midi_median, mean_voiced_prob, voiced_ratio)``.

    Trims the leading ``trim_head`` fraction (glide-in / scoop) and trailing
    ``trim_tail`` (release / pitch fall-off) of the chunk, then takes the
    median over voiced frames. Single-frame octave jumps are absorbed by a
    5-frame median filter applied to the pitch contour first.
    """
    if t1 - t0 <= 0:
        return float("nan"), 0.0, 0.0
    dur = t1 - t0
    core_t0 = t0 + dur * trim_head
    core_t1 = t1 - dur * trim_tail
    if core_t1 <= core_t0:
        core_t0, core_t1 = t0, t1
    idx = np.where((pitch_times >= core_t0) & (pitch_times < core_t1))[0]
    if idx.size == 0:
        return float("nan"), 0.0, 0.0

    seg = pitch_midi[idx].copy()
    probs = voiced_prob[idx]
    if seg.size >= 5:
        nan_mask = ~np.isfinite(seg)
        if nan_mask.any():
            filled = seg.copy()
            fill = float(np.median(seg[~nan_mask])) if (~nan_mask).any() else 0.0
            filled[nan_mask] = fill
            seg = medfilt(filled, kernel_size=5); seg[nan_mask] = np.nan
        else:
            seg = medfilt(seg, kernel_size=5)
    finite_mask = np.isfinite(seg)
    voiced_mask = finite_mask & (probs >= voiced_threshold)
    voiced_ratio = float(voiced_mask.mean()) if probs.size else 0.0
    finite_ratio = float(finite_mask.mean()) if seg.size else 0.0

    # Preferred path: enough confidently-voiced frames.
    if voiced_mask.sum() >= 2:
        return float(np.median(seg[voiced_mask])), float(np.mean(probs[voiced_mask])), voiced_ratio

    # Fallback: pYIN locked a pitch but its voiced_prob stayed below the
    # threshold (common for short / soft attacks like "두", weak waltz beats,
    # quiet tail of a phrase). Trust the pitch — pyin already filtered out
    # noise by returning NaN there — and report confidence as the mean prob.
    # finite_ratio threshold paired with percussive_ratio in analyze_audio()
    # so a beatbox sample still flips into percussive mode.
    if finite_mask.sum() >= 3 and finite_ratio >= 0.25:
        return float(np.median(seg[finite_mask])), float(np.mean(probs[finite_mask])), finite_ratio

    return float("nan"), 0.0, voiced_ratio


def _chunk_velocity(peak_rms: float, global_peak: float) -> int:
    """Map chunk's peak RMS into MIDI velocity 20-120."""
    if global_peak <= 1e-6:
        return 64
    ratio = float(np.clip(peak_rms / global_peak, 0.0, 1.0))
    return int(max(1, min(127, round(20 + ratio * 100))))


# ============================================================================
# Main pipeline
# ============================================================================
def analyze_audio(file_bytes: bytes, opts: AnalyzeOptions) -> AnalyzeResponse:
    # ---- Stage 2: preprocessing -----------------------------------------------
    y, sr = _load_audio(file_bytes)
    duration = len(y) / sr if sr else 0.0

    # ---- Stage 3: voice region detection (RMS envelope + adaptive thresholds)
    env_times, rms = compute_rms_envelope(y, sr, hop=HOP)
    th = compute_thresholds(
        rms,
        enter_ratio=opts.enter_ratio,
        exit_ratio=opts.exit_ratio,
    )

    # ---- Stage 4: chunk segmentation (state machine + internal splitters) ----
    chunks_raw = segment_chunks_streaming(
        rms, env_times, th["enter"], th["exit"],
        exit_hold_sec=opts.exit_hold_sec,
    )
    chunks_raw = post_process_chunks(
        chunks_raw,
        min_chunk_dur_sec=opts.min_chunk_dur_sec,
        merge_gap_sec=opts.merge_gap_sec,
    )

    # Pitch contour (also a Stage 5 input — computed here so Stage 4 splitter
    # can use it). One pass over the whole audio.
    p_times, p_hz, _voiced, p_prob = extract_pitch_pyin(
        y, sr, opts.fmin_hz, opts.fmax_hz, hop_length=HOP,
    )
    p_midi = hz_to_midi_float(p_hz)

    # Internal subdivision for long legato chunks (same-note repeats and
    # different-note transitions). Skipped for short chunks to avoid vibrato
    # false splits.
    def _chunk_pitch_span(c) -> float:
        """Robust pitch span (p90-p10, smoothed) over a chunk, in semitones.
        Used to decide whether a chunk is a flat held note vs a moving glide."""
        idx = np.where((p_times >= c["start"]) & (p_times <= c["end"]))[0]
        fin = p_midi[idx]
        fin = fin[np.isfinite(fin)]
        if fin.size < 5:
            return 0.0
        fin = medfilt(fin, kernel_size=5)
        return float(np.percentile(fin, 90) - np.percentile(fin, 10))

    def _maybe_subdivide(cs):
        out = []
        for c in cs:
            if c["end"] - c["start"] < SUBDIVISION_MIN_CHUNK_DUR_SEC:
                out.append(c); continue
            pieces = [c]
            # rms-dip = "same note repeated softly" splitter → gate to flat-pitch
            # chunks so it doesn't chop a moving legato glide (pitch_split owns those).
            if opts.rms_dip_split and _chunk_pitch_span(c) <= opts.rms_dip_max_pitch_span_st:
                pieces = [p for q in pieces for p in split_chunk_by_rms_dip(q, env_times, rms)]
            if opts.pitch_split:
                pieces = [p for q in pieces for p in split_chunk_by_pitch(q, p_times, p_midi)]
            out.extend(pieces)
        return out
    chunks_final = _maybe_subdivide(chunks_raw)

    # ---- Stage 5 + 6: per-chunk pitch/velocity → note events -----------------
    global_peak = float(np.max(rms)) if rms.size else 1.0
    notes: List[Note] = []
    for c in chunks_final:
        t0, t1 = c["start"], c["end"]
        midi_med, conf, vratio = _chunk_pitch(
            p_times, p_midi, p_prob, t0, t1,
            voiced_threshold=opts.voiced_prob_threshold,
        )
        if not math.isfinite(midi_med):
            continue
        if vratio < 0.25:
            continue

        # ---- Stage 6: raw note (Stage 7 key/assistant applied after the loop) -
        pitch0 = int(round(midi_med))
        hz = float(440.0 * (2.0 ** ((pitch0 - 69) / 12.0)))
        notes.append(Note(
            start=t0, end=t1, duration=t1 - t0,
            pitch=pitch0,
            pitch_raw=float(midi_med),
            pitch_hz=hz,
            confidence=float(conf),
            velocity=_chunk_velocity(c["peak_rms"], global_peak),
            voiced_ratio=float(vratio),
            kind="pitched",
            pitch_original=pitch0,
        ))

    # Remember which chunks produced a melodic note so we can recover the rest.
    melodic_chunk_starts = {round(n.start, 6) for n in notes}

    # ---- Auto percussive fallback -------------------------------------------
    # If voicing analysis couldn't recover most chunks (typical for beatbox /
    # drum patterns), the sample is not a melodic line. Re-emit every chunk as
    # a generic GM snare hit so the user at least gets a 1:1 chunk→note mapping
    # to drive a drum machine downstream. Threshold tuned so a melodic sample
    # with a couple of weak attacks does NOT flip into this mode.
    PERCUSSIVE_FALLBACK_RATIO = 0.55  # voiced_notes / chunks < this → percussive
    is_percussive = (
        chunks_final and (len(notes) / len(chunks_final)) < PERCUSSIVE_FALLBACK_RATIO
    )

    if is_percussive:
        notes = []
        for c in chunks_final:
            t0, t1 = c["start"], c["end"]
            seg = y[int(round(t0 * sr)):int(round(t1 * sr))]
            drum_pitch = classify_drum(seg, sr)   # 36 kick / 38 snare / 42 hihat
            notes.append(Note(
                start=t0, end=t1, duration=t1 - t0,
                pitch=drum_pitch,        # GM percussion key (channel 10)
                pitch_raw=float(drum_pitch),
                pitch_hz=0.0,            # not meaningful for drum hits
                confidence=0.0,
                velocity=104,            # 드럼은 일정 볼륨(타격 세기 변화 없이)
                voiced_ratio=0.0,
                kind="percussive",
                pitch_original=drum_pitch,
                candidates=[drum_pitch],
            ))
    else:
        # ---- Melodic-mode chunk recovery ------------------------------------
        # Some chunks survived envelope detection (clear peak above noise) but
        # pyin couldn't lock a confident pitch — typical for fast attacks like
        # "두" where the consonant dominates. Borrow pitch from the nearest
        # melodic neighbours so the rhythm chunks don't disappear from the roll.
        noise_floor = th["noise_floor"]
        for c in chunks_final:
            if round(c["start"], 6) in melodic_chunk_starts:
                continue
            # Real noise has peak ≈ noise_floor. Require a clear margin.
            if c["peak_rms"] < noise_floor * 3.0:
                continue
            prev_n = None; next_n = None
            for n in notes:
                if n.kind != "pitched":
                    continue
                if n.end <= c["start"]:
                    prev_n = n
                elif n.start >= c["end"]:
                    next_n = n
                    break
            if prev_n is None and next_n is None:
                continue
            if prev_n and next_n:
                borrowed_pitch = int(round((prev_n.pitch + next_n.pitch) / 2))
                borrowed_raw = (prev_n.pitch_raw + next_n.pitch_raw) / 2
            elif prev_n:
                borrowed_pitch = prev_n.pitch
                borrowed_raw = prev_n.pitch_raw
            else:
                borrowed_pitch = next_n.pitch
                borrowed_raw = next_n.pitch_raw
            hz = float(440.0 * (2.0 ** ((borrowed_pitch - 69) / 12.0)))
            notes.append(Note(
                start=c["start"], end=c["end"], duration=c["end"] - c["start"],
                pitch=int(borrowed_pitch),
                pitch_raw=float(borrowed_raw),
                pitch_hz=hz,
                confidence=0.0,           # 0 = borrowed; UI can render it differently
                velocity=_chunk_velocity(c["peak_rms"], global_peak),
                voiced_ratio=0.0,
                kind="pitched",
            ))
        notes.sort(key=lambda n: n.start)

    # ---- Stage 7: Auto Key + Pitch Assistant (shared with /assist + diagnose) -
    detected_key = None
    assist_count = 0
    key_candidates: List[KeyCandidate] = []
    if not is_percussive:
        res = run_key_and_assistant(
            notes, opts.auto_key, opts.pitch_assistant, opts.key_tonic, opts.scale,
        )
        assist_count = res["applied"]
        detected_key = DetectedKey(
            tonic=res["tonic"], scale=res["scale"], confidence=float(res["confidence"]),
            key_tier=res["key_tier"], key_applied=res["key_applied"],
        )
        key_candidates = [KeyCandidate(**c) for c in res["top3"]]

    # ---- Pack response -------------------------------------------------------
    def _safe(arr: np.ndarray) -> List[float]:
        return [float(x) if math.isfinite(x) else float("nan") for x in arr.tolist()]

    return AnalyzeResponse(
        notes=notes,
        chunks=[Chunk(**c) for c in chunks_final],
        envelope=EnvelopeInfo(
            times=[float(t) for t in env_times.tolist()],
            rms=[float(x) for x in rms.tolist()],
            noise_floor=th["noise_floor"],
            peak_level=th["peak_level"],
            enter_threshold=th["enter"],
            exit_threshold=th["exit"],
        ),
        pitch_track=PitchTrack(
            times=[float(x) for x in p_times.tolist()],
            hz=_safe(p_hz),
            midi=_safe(p_midi),
            voiced_prob=[float(x) for x in p_prob.tolist()],
        ),
        waveform=Waveform(
            sample_rate=sr,
            duration=duration,
            peaks=_downsample_for_display(y),
        ),
        options=opts,
        audio_id=uuid.uuid4().hex,
        detected_key=detected_key,
        assist_applied_count=assist_count,
        key_candidates=key_candidates,
    )
