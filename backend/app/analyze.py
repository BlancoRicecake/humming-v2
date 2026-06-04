"""SoundLab — voice-to-MIDI analysis pipeline (Stages 2-7 of the 9-stage map).

The full 9 stages (Stage 1 = browser recorder, Stages 8-9 = client playback +
MIDI download) are mapped to clearly-labelled sections below. Each new
feature should land inside the stage it belongs to so the structure stays
visible.
"""
from __future__ import annotations

import io
import json
import logging
import math
import subprocess
import tempfile
import os
import uuid
from typing import Dict, List, Optional, Tuple

import numpy as np
import librosa
import soundfile as sf
from fastapi import HTTPException
from scipy.signal import medfilt

log = logging.getLogger("soundlab")

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
from .drums import classify_features
from .drum_onset import build_drum_notes


TARGET_SR = 22050
HOP = 256

# ============================================================================
# Decoder probe / debug surface (Opus integration)
# ============================================================================
# Last decode metadata — populated by _load_audio, consumed by analyze_audio()
# at response-pack time. Module-level is fine because analyze_audio runs
# under the per-request slot (Semaphore(2) in main.py) so there is no
# interleaving between concurrent /analyze calls within a single Python
# function frame.
_LAST_DECODE_INFO: Dict[str, Optional[object]] = {}


def _magic_is_wav(blob: bytes) -> bool:
    return len(blob) >= 12 and blob[:4] == b"RIFF" and blob[8:12] == b"WAVE"


def _magic_is_caf(blob: bytes) -> bool:
    return len(blob) >= 4 and blob[:4] == b"caff"


def _magic_is_ogg(blob: bytes) -> bool:
    return len(blob) >= 4 and blob[:4] == b"OggS"


def _magic_is_mp4(blob: bytes) -> bool:
    # ISO BMFF: ?? ?? ?? ?? 'ftyp' at offset 4
    return len(blob) >= 12 and blob[4:8] == b"ftyp"


def _ffprobe_info(blob: bytes) -> Dict[str, Optional[object]]:
    """Return {codec, sr, channels, bitrate_kbps}. Tolerates probe failure."""
    info: Dict[str, Optional[object]] = {
        "codec": None, "sr": None, "channels": None, "bitrate_kbps": None,
    }
    try:
        proc = subprocess.run(
            [
                "ffprobe", "-v", "error",
                "-show_streams", "-show_format", "-of", "json",
                "pipe:0",
            ],
            input=blob, capture_output=True, timeout=10,
        )
        if proc.returncode != 0:
            return info
        meta = json.loads(proc.stdout.decode("utf-8", errors="ignore"))
        streams = meta.get("streams") or []
        # Pick first audio stream
        astream = next((s for s in streams if s.get("codec_type") == "audio"), None)
        if astream:
            info["codec"] = astream.get("codec_name")
            sr_raw = astream.get("sample_rate")
            info["sr"] = int(sr_raw) if sr_raw else None
            info["channels"] = astream.get("channels")
            br = astream.get("bit_rate") or (meta.get("format") or {}).get("bit_rate")
            if br:
                try:
                    info["bitrate_kbps"] = max(1, int(round(int(br) / 1000)))
                except Exception:
                    pass
            # ffprobe over a stdin pipe cannot seek → bit_rate is often unset
            # for Ogg/Opus and MP4 containers. Estimate from blob size + duration.
            if not info["bitrate_kbps"]:
                dur_raw = astream.get("duration") or (meta.get("format") or {}).get("duration")
                try:
                    dur = float(dur_raw) if dur_raw else 0.0
                    if dur > 0.05 and len(blob) > 0:
                        info["bitrate_kbps"] = max(1, int(round(len(blob) * 8.0 / dur / 1000)))
                except (TypeError, ValueError):
                    pass
    except (subprocess.TimeoutExpired, FileNotFoundError, json.JSONDecodeError, ValueError):
        pass
    return info


def _ffmpeg_decode_to_pcm(
    blob: bytes, target_sr: int = TARGET_SR, mono: bool = True,
) -> Tuple[np.ndarray, int]:
    """Decode arbitrary container (Opus/m4a/CAF/AAC/...) → mono float32 PCM at target_sr.

    Uses ffmpeg subprocess. CAF (iOS `record` package output) cannot be demuxed
    from a non-seekable stdin pipe — its 64-bit chunk size + `-1` sentinel
    requires random seek. For CAF we spill to a temp file and pass a path;
    everything else stays on stdin for zero-copy.
    """
    ac = 1 if mono else 2
    use_tempfile = _magic_is_caf(blob)
    tmp_path: Optional[str] = None
    try:
        if use_tempfile:
            with tempfile.NamedTemporaryFile(suffix=".caf", delete=False) as tmp:
                tmp.write(blob)
                tmp_path = tmp.name
            cmd = [
                "ffmpeg", "-loglevel", "error",
                "-i", tmp_path,
                "-f", "s16le", "-ac", str(ac), "-ar", str(target_sr),
                "pipe:1",
            ]
            stdin_data: Optional[bytes] = None
        else:
            cmd = [
                "ffmpeg", "-loglevel", "error",
                "-i", "pipe:0",
                "-f", "s16le", "-ac", str(ac), "-ar", str(target_sr),
                "pipe:1",
            ]
            stdin_data = blob
        try:
            proc = subprocess.run(
                cmd, input=stdin_data, capture_output=True, timeout=30,
            )
        except subprocess.TimeoutExpired as exc:
            raise HTTPException(status_code=400, detail="audio decode timeout (ffmpeg > 30s)") from exc
        except FileNotFoundError as exc:
            raise HTTPException(status_code=500, detail="ffmpeg binary not available on server") from exc
    finally:
        if tmp_path is not None:
            try:
                os.unlink(tmp_path)
            except OSError:
                pass

    if proc.returncode != 0 or not proc.stdout:
        err = proc.stderr.decode("utf-8", errors="ignore")[:200] if proc.stderr else "unknown"
        head_hex = blob[:16].hex() if blob else "(empty)"
        head_ascii = "".join(chr(b) if 32 <= b < 127 else "." for b in blob[:16])
        log.warning(
            "ffmpeg decode failed: size=%d head_hex=%s head_ascii=%r err=%s",
            len(blob), head_hex, head_ascii, err[:120],
        )
        raise HTTPException(status_code=400, detail=f"audio decode failed (ffmpeg): {err}")

    pcm = np.frombuffer(proc.stdout, dtype=np.int16).astype(np.float32) / 32768.0
    return pcm, target_sr


# ============================================================================
# Stage 2 — Preprocessing
# ============================================================================
def _load_audio(file_bytes: bytes) -> Tuple[np.ndarray, int]:
    """Decode any audio blob into mono float32 PCM at TARGET_SR.

    Routing:
      - WAV (RIFF magic): keep the legacy soundfile path verbatim (no
        regression risk on PCM inputs).
      - Anything else (Opus/m4a/CAF/AAC/...): ffmpeg subprocess pipe.
      - Both paths populate ``_LAST_DECODE_INFO`` for the response debug
        surface.
    """
    probe = _ffprobe_info(file_bytes)
    # Container hint independent of ffprobe (for the input_codec label).
    if _magic_is_wav(file_bytes):
        container = "wav"
    elif _magic_is_caf(file_bytes):
        container = "caf"
    elif _magic_is_ogg(file_bytes):
        container = "opus" if (probe.get("codec") in {"opus", None}) else str(probe.get("codec"))
    elif _magic_is_mp4(file_bytes):
        # iOS may wrap Opus in MP4 (.m4a). Distinguish via codec probe.
        codec_name = probe.get("codec")
        if codec_name == "opus":
            container = "opus"
        elif codec_name in {"aac", "mp4a"}:
            container = "m4a"
        else:
            container = "m4a"
    else:
        container = str(probe.get("codec") or "unknown")

    decoded_via: str
    if _magic_is_wav(file_bytes):
        # ---- Legacy WAV path (unchanged for regression safety) -----------------
        bio = io.BytesIO(file_bytes)
        try:
            y, sr = sf.read(bio, dtype="float32", always_2d=False)
            decoded_via = "soundfile"
        except Exception:
            # Extremely rare: RIFF magic but libsndfile can't parse (e.g.
            # exotic subtype). Fall through to ffmpeg.
            y, sr = _ffmpeg_decode_to_pcm(file_bytes, target_sr=TARGET_SR, mono=True)
            decoded_via = "ffmpeg"
    else:
        # ---- Opus / m4a / CAF / AAC / ... -------------------------------------
        try:
            y, sr = _ffmpeg_decode_to_pcm(file_bytes, target_sr=TARGET_SR, mono=True)
            decoded_via = "ffmpeg"
        except HTTPException:
            # Final fallback: try soundfile (libsndfile may handle some Ogg/Opus).
            try:
                bio = io.BytesIO(file_bytes)
                y, sr = sf.read(bio, dtype="float32", always_2d=False)
                decoded_via = "soundfile"
            except Exception as exc:
                raise HTTPException(
                    status_code=400,
                    detail="unsupported audio format (ffmpeg + soundfile both failed)",
                ) from exc

    # Cache decode metadata for the response packer.
    probe_sr = probe.get("sr")
    bitrate_kbps = probe.get("bitrate_kbps")
    # ffprobe over stdin pipe can't seek → duration/bitrate often missing for
    # Ogg/Opus + MP4. Back-fill from blob size + decoded duration when the
    # decode used the lossy ffmpeg path.
    if bitrate_kbps is None and decoded_via == "ffmpeg":
        ch = 1
        dur_decoded = (len(y) / float(sr) / ch) if sr else 0.0
        if dur_decoded > 0.05:
            bitrate_kbps = max(1, int(round(len(file_bytes) * 8.0 / dur_decoded / 1000)))
    _LAST_DECODE_INFO.clear()
    _LAST_DECODE_INFO.update({
        "input_codec": container,
        "input_sr": int(probe_sr) if probe_sr else int(sr),
        "input_channels": probe.get("channels"),
        "input_bitrate_kbps": bitrate_kbps,
        "decoded_via": decoded_via,
    })

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


FLAT_VELOCITY = 100  # 모든 변환 노트를 일정한 세기로(MIDI 기본 — 강약은 분석에서 넣지 않음)


def _chunk_velocity(peak_rms: float, global_peak: float) -> int:
    """Uniform velocity for every converted note.

    흥얼거림의 진폭 변동을 노트 세기에 반영하면 강약이 들쭉날쭉해진다. MIDI 처럼
    모든 노트를 일정 세기로 둔다(시그니처는 유지 — 호출부 무변경).
    """
    return FLAT_VELOCITY


# ============================================================================
# Main pipeline
# ============================================================================
def analyze_audio(file_bytes: bytes, opts: AnalyzeOptions) -> AnalyzeResponse:
    # ---- Stage 2: preprocessing -----------------------------------------------
    y, sr = _load_audio(file_bytes)
    duration = len(y) / sr if sr else 0.0

    # ---- Drum mode: skip the melodic pipeline entirely -----------------------
    # Notes come from onsets (not pYIN pitch), so unpitched percussion no longer
    # vanishes. The melodic path below is untouched → no auto-percussive misfire.
    if opts.as_drums:
        return _analyze_drums(y, sr, duration, opts)

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
    # can use it). One pass over the whole audio. The CREPE backend is lazily
    # imported so its dependency weight never touches the default pYIN path.
    if opts.pitch_model == "crepe":
        from .pitch import extract_pitch_crepe
        p_times, p_hz, _voiced, p_prob = extract_pitch_crepe(
            y, sr, opts.fmin_hz, opts.fmax_hz, hop_length=HOP,
            conf_threshold=opts.voiced_prob_threshold,
        )
    else:
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

    # ---- Melodic-mode chunk recovery ----------------------------------------
    # Some chunks survived envelope detection (clear peak above noise) but pyin
    # couldn't lock a confident pitch — typical for fast attacks like "두" where
    # the consonant dominates. Borrow pitch from the nearest melodic neighbours
    # so the rhythm chunks don't disappear from the roll.
    # NOTE: Auto-percussive fallback removed. Drum conversion only happens when
    # the user explicitly picks a drum instrument (handled outside analyze).
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

    # ---- Drum timbre classification (Stage 6 add-on) -------------------------
    # Classify each note's onset segment into a GM kit piece by SPECTRUM
    # (kick/snare/hi-hat). Done for every note and exposed for debug; the
    # client applies `drum` only for drum-role tracks. Cheap: one rfft per hit.
    for n in notes:
        a = max(0, int(round(n.start * sr)))
        b = min(len(y), int(round(n.end * sr)))
        hit = classify_features(y[a:b], sr)
        n.drum = hit.gm_note
        n.drum_name = hit.name
        n.drum_centroid = hit.centroid
        n.drum_low_ratio = hit.low_ratio
        n.drum_high_ratio = hit.high_ratio
        n.drum_zcr = hit.zcr
        n.drum_rolloff = hit.rolloff
        n.drum_flatness = hit.flatness

    # ---- Stage 7: Auto Key + Pitch Assistant (shared with /assist + diagnose) -
    res = run_key_and_assistant(
        notes, opts.auto_key, opts.pitch_assistant, opts.key_tonic, opts.scale,
        assist_aggressive=opts.assist_aggressive,
    )
    assist_count = res["applied"]
    detected_key = DetectedKey(
        tonic=res["tonic"], scale=res["scale"], confidence=float(res["confidence"]),
        key_tier=res["key_tier"], key_applied=res["key_applied"],
    )
    key_candidates = [KeyCandidate(**c) for c in res["top3"]]

    return _pack_response(
        notes=notes,
        chunks=[Chunk(**c) for c in chunks_final],
        y=y, sr=sr, duration=duration, opts=opts,
        env_times=env_times, rms=rms, th=th,
        pitch_track=PitchTrack(
            times=[float(x) for x in p_times.tolist()],
            hz=_safe(p_hz),
            midi=_safe(p_midi),
            voiced_prob=[float(x) for x in p_prob.tolist()],
            model=opts.pitch_model,
        ),
        detected_key=detected_key,
        assist_count=assist_count,
        key_candidates=key_candidates,
    )


# ============================================================================
# Drum mode — onset-based, timbre-classified (as_drums); pitch-independent
# ============================================================================
def _analyze_drums(y: np.ndarray, sr: int, duration: float, opts: AnalyzeOptions) -> AnalyzeResponse:
    """One note per onset, classified by timbre (drum_onset.build_drum_notes).

    Does NOT run the melodic pitch/recovery/key path — drums have no pitch or
    key. Envelope is still computed for the debug overlay; pitch_track is empty.
    """
    env_times, rms = compute_rms_envelope(y, sr, hop=HOP)
    th = compute_thresholds(rms, enter_ratio=opts.enter_ratio, exit_ratio=opts.exit_ratio)
    global_peak_rms = float(np.max(rms)) if rms.size else 1.0
    notes = build_drum_notes(y, sr, classify_features, hop=HOP, global_peak_rms=global_peak_rms)
    return _pack_response(
        notes=notes,
        chunks=[],
        y=y, sr=sr, duration=duration, opts=opts,
        env_times=env_times, rms=rms, th=th,
        pitch_track=PitchTrack(times=[], hz=[], midi=[], voiced_prob=[]),
        detected_key=None,
        assist_count=0,
        key_candidates=[],
    )


def _safe(arr: np.ndarray) -> List[float]:
    return [float(x) if math.isfinite(x) else float("nan") for x in arr.tolist()]


def _pack_response(
    *, notes, chunks, y, sr, duration, opts,
    env_times, rms, th, pitch_track, detected_key, assist_count, key_candidates,
) -> AnalyzeResponse:
    """Assemble the AnalyzeResponse. Shared by the melodic and drum paths so the
    response shape never drifts between them. Decode debug metadata (codec/sr/
    channels/bitrate/via) is sourced from module-level _LAST_DECODE_INFO populated
    by _load_audio."""
    decode_info = dict(_LAST_DECODE_INFO)
    return AnalyzeResponse(
        notes=notes,
        chunks=chunks,
        input_codec=decode_info.get("input_codec"),
        input_sr=decode_info.get("input_sr"),
        input_channels=decode_info.get("input_channels"),
        input_bitrate_kbps=decode_info.get("input_bitrate_kbps"),
        decoded_via=decode_info.get("decoded_via"),
        envelope=EnvelopeInfo(
            times=[float(t) for t in env_times.tolist()],
            rms=[float(x) for x in rms.tolist()],
            noise_floor=th["noise_floor"],
            peak_level=th["peak_level"],
            enter_threshold=th["enter"],
            exit_threshold=th["exit"],
        ),
        pitch_track=pitch_track,
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
