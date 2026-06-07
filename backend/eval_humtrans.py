"""Evaluate HumTrack note extraction on HumTrans WAV/MIDI pairs.

Supports extracted directories and ZIP files:
  all_wav/<id>.wav or all_wav.zip
  all_midi/<id>.mid or all_midi.zip

Example:
  .\\.venv\\Scripts\\python eval_humtrans.py --root C:\\data\\HumTrans --limit 50
"""
from __future__ import annotations

import argparse
import csv
import gzip
import hashlib
import io
import json
import logging
import math
import random
import statistics
import subprocess
import sys
import warnings
import zipfile
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

import mido
import numpy as np

from app.analyze import analyze_audio
from app.schemas import AnalyzeOptions
from app.scales import scale_pitch_classes

warnings.filterwarnings("ignore")
logging.disable(logging.WARNING)


@dataclass(frozen=True)
class MidiNote:
    start: float
    end: float
    pitch: int
    velocity: int = 90
    pitch_raw: float | None = None
    pitch_original: int | None = None
    confidence: float | None = None
    voiced_ratio: float | None = None
    assisted: bool | None = None
    source: str | None = None
    in_key: bool | None = None

    @property
    def duration(self) -> float:
        return max(0.0, self.end - self.start)


@dataclass(frozen=True)
class AssetRef:
    path: Path
    member: str | None = None

    def read_bytes(self) -> bytes:
        if self.member is None:
            return self.path.read_bytes()
        with zipfile.ZipFile(self.path) as zf:
            return zf.read(self.member)

    def label(self) -> str:
        return str(self.path) if self.member is None else f"{self.path}!{self.member}"


@dataclass(frozen=True)
class Pair:
    key: str
    wav: AssetRef
    midi: AssetRef


ERROR_KEYS = [
    "missed_onset",
    "extra_onset",
    "wrong_pitch",
    "bad_offset",
    "merged_notes",
    "false_split",
    "octave_error",
]


def _note_name(pitch: int) -> str:
    names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    return f"{names[pitch % 12]}{pitch // 12 - 1}"


def _find_dir(root: Path, names: Iterable[str]) -> Path | None:
    for name in names:
        p = root / name
        if p.is_dir():
            return p
    lowered = {n.lower() for n in names}
    for p in root.rglob("*"):
        if p.is_dir() and p.name.lower() in lowered:
            return p
    return None


def _zip_items(path: Path, suffixes: tuple[str, ...]) -> dict[str, AssetRef]:
    out: dict[str, AssetRef] = {}
    with zipfile.ZipFile(path) as zf:
        for name in zf.namelist():
            if name.endswith("/"):
                continue
            p = Path(name)
            if p.suffix.lower() in suffixes:
                out[p.stem] = AssetRef(path, name)
    return out


def find_pairs(
    root: Path | None,
    wav_dir: Path | None,
    midi_dir: Path | None,
    wav_zip: Path | None,
    midi_zip: Path | None,
) -> list[Pair]:
    if root is not None:
        wav_zip = wav_zip or (root / "all_wav.zip" if (root / "all_wav.zip").is_file() else None)
        midi_zip = midi_zip or (root / "all_midi.zip" if (root / "all_midi.zip").is_file() else None)
        # HumTrans can have partial extracted dirs from debug/cache work. The
        # official ZIPs are complete, so prefer them unless explicit dirs were
        # passed by the caller.
        if wav_zip is None:
            wav_dir = wav_dir or _find_dir(root, ["all_wav", "wav", "wavs", "audio"])
        if midi_zip is None:
            midi_dir = midi_dir or _find_dir(root, ["all_midi", "midi", "midis", "labels"])

    if wav_dir is not None:
        if not wav_dir.is_dir():
            raise SystemExit(f"WAV directory not found: {wav_dir}")
        wavs = {p.stem: AssetRef(p) for p in wav_dir.rglob("*.wav")}
    elif wav_zip is not None:
        if not wav_zip.is_file():
            raise SystemExit(f"WAV ZIP not found: {wav_zip}")
        wavs = _zip_items(wav_zip, (".wav",))
    else:
        raise SystemExit("Missing WAV source. Pass --root, --wav-dir, or --wav-zip.")

    if midi_dir is not None:
        if not midi_dir.is_dir():
            raise SystemExit(f"MIDI directory not found: {midi_dir}")
        midis = {p.stem: AssetRef(p) for p in midi_dir.rglob("*.mid")}
        midis.update({p.stem: AssetRef(p) for p in midi_dir.rglob("*.midi")})
    elif midi_zip is not None:
        if not midi_zip.is_file():
            raise SystemExit(f"MIDI ZIP not found: {midi_zip}")
        midis = _zip_items(midi_zip, (".mid", ".midi"))
    else:
        raise SystemExit("Missing MIDI source. Pass --root, --midi-dir, or --midi-zip.")

    keys = sorted(set(wavs) & set(midis))
    return [Pair(k, wavs[k], midis[k]) for k in keys]


def read_midi_notes(src: AssetRef, min_dur: float = 0.03) -> list[MidiNote]:
    mid = mido.MidiFile(file=io.BytesIO(src.read_bytes()))
    tempo = 500000
    seconds_per_tick = tempo / 1_000_000.0 / mid.ticks_per_beat
    active: dict[tuple[int, int], list[tuple[float, int]]] = {}
    notes: list[MidiNote] = []

    t = 0.0
    for msg in mido.merge_tracks(mid.tracks):
        t += msg.time * seconds_per_tick
        if msg.type == "set_tempo":
            tempo = msg.tempo
            seconds_per_tick = tempo / 1_000_000.0 / mid.ticks_per_beat
            continue
        if not hasattr(msg, "note"):
            continue
        key = (int(getattr(msg, "channel", 0)), int(msg.note))
        if msg.type == "note_on" and int(getattr(msg, "velocity", 0)) > 0:
            active.setdefault(key, []).append((t, int(msg.velocity)))
        elif msg.type in ("note_off", "note_on"):
            starts = active.get(key)
            if not starts:
                continue
            start, vel = starts.pop(0)
            if t - start >= min_dur:
                notes.append(MidiNote(start=start, end=t, pitch=int(msg.note), velocity=vel))

    notes.sort(key=lambda n: (n.start, n.pitch, n.end))
    return notes


def predicted_notes(wav: AssetRef, opts: AnalyzeOptions) -> tuple[list[MidiNote], dict[str, object]]:
    res = analyze_audio(wav.read_bytes(), opts)
    notes = [
        MidiNote(
            float(n.start),
            float(n.end),
            int(n.pitch),
            int(n.velocity),
            pitch_raw=float(n.pitch_raw),
            pitch_original=int(n.pitch_original),
            confidence=float(n.confidence),
            voiced_ratio=float(n.voiced_ratio),
            assisted=bool(n.assisted),
            source=str(n.source),
            in_key=bool(n.in_key),
        )
        for n in res.notes
        if n.kind == "pitched" and n.end > n.start
    ]
    notes.sort(key=lambda n: (n.start, n.pitch, n.end))
    detected_key = {}
    if res.detected_key is not None:
        detected_key = {
            "tonic": res.detected_key.tonic,
            "scale": res.detected_key.scale,
            "confidence": float(res.detected_key.confidence),
            "tier": res.detected_key.key_tier,
            "applied": bool(res.detected_key.key_applied),
        }
    return notes, {
        "detected_key": detected_key,
        "assist_applied_count": int(res.assist_applied_count),
        "key_candidates": [
            {"tonic": c.tonic, "scale": c.scale, "correlation": float(c.correlation)}
            for c in res.key_candidates
        ],
        "envelope_times": [float(x) for x in res.envelope.times],
        "envelope_rms": [float(x) for x in res.envelope.rms],
        "pitch_times": [float(x) for x in res.pitch_track.times],
        "pitch_midi": [float(x) for x in res.pitch_track.midi],
        "voiced_prob": [float(x) for x in res.pitch_track.voiced_prob],
    }


def best_global_pitch_shift(ref: list[MidiNote], pred: list[MidiNote], max_shift: int = 24) -> int:
    if not ref or not pred:
        return 0
    scores: list[tuple[int, int, int]] = []
    for shift in range(-max_shift, max_shift + 1):
        hits = 0
        err = 0.0
        for r in ref:
            best = None
            for p in pred:
                if abs(p.start - r.start) > 0.4:
                    continue
                d = abs((p.pitch + shift) - r.pitch)
                if best is None or d < best:
                    best = d
            if best is not None:
                hits += 1
                err += best
        scores.append((hits, -int(round(err * 1000)), shift))
    scores.sort(reverse=True)
    return scores[0][2]


def estimate_time_shift(ref: list[MidiNote], pred: list[MidiNote], pitch_shift: int, max_diff: float = 1.0) -> float:
    diffs: list[float] = []
    for p in pred:
        best = None
        for r in ref:
            if r.pitch != p.pitch + pitch_shift:
                continue
            d = r.start - p.start
            if abs(d) > max_diff:
                continue
            if best is None or abs(d) < abs(best):
                best = d
        if best is not None:
            diffs.append(best)
    return float(statistics.median(diffs)) if diffs else 0.0


def shift_notes(notes: list[MidiNote], shift: float) -> list[MidiNote]:
    if abs(shift) < 1e-6:
        return notes
    return [
        MidiNote(
            max(0.0, n.start + shift),
            max(0.0, n.end + shift),
            n.pitch,
            n.velocity,
            pitch_raw=n.pitch_raw,
            pitch_original=n.pitch_original,
            confidence=n.confidence,
            voiced_ratio=n.voiced_ratio,
            assisted=n.assisted,
            source=n.source,
            in_key=n.in_key,
        )
        for n in notes
    ]


def note_to_dict(n: MidiNote) -> dict[str, object]:
    out = {
        "start": round(float(n.start), 6),
        "end": round(float(n.end), 6),
        "duration": round(float(n.duration), 6),
        "pitch": int(n.pitch),
        "name": _note_name(int(n.pitch)),
        "velocity": int(n.velocity),
    }
    if n.pitch_raw is not None:
        out["pitch_raw"] = round(float(n.pitch_raw), 4)
    if n.pitch_original is not None:
        out["pitch_original"] = int(n.pitch_original)
    if n.confidence is not None:
        out["confidence"] = round(float(n.confidence), 4)
    if n.voiced_ratio is not None:
        out["voiced_ratio"] = round(float(n.voiced_ratio), 4)
    if n.assisted is not None:
        out["assisted"] = bool(n.assisted)
    if n.source is not None:
        out["source"] = str(n.source)
    if n.in_key is not None:
        out["in_key"] = bool(n.in_key)
    return out


def note_from_dict(data: dict[str, object]) -> MidiNote:
    return MidiNote(
        start=float(data["start"]),
        end=float(data["end"]),
        pitch=int(data["pitch"]),
        velocity=int(data.get("velocity", 90)),
        pitch_raw=(
            float(data["pitch_raw"]) if data.get("pitch_raw") is not None else None
        ),
        pitch_original=(
            int(data["pitch_original"]) if data.get("pitch_original") is not None else None
        ),
        confidence=(
            float(data["confidence"]) if data.get("confidence") is not None else None
        ),
        voiced_ratio=(
            float(data["voiced_ratio"]) if data.get("voiced_ratio") is not None else None
        ),
        assisted=(
            bool(data["assisted"]) if data.get("assisted") is not None else None
        ),
        source=(str(data["source"]) if data.get("source") is not None else None),
        in_key=(bool(data["in_key"]) if data.get("in_key") is not None else None),
    )


def cache_file_path(cache_dir: Path, split: str, key: str) -> Path:
    return cache_dir / split / f"{key}.json.gz"


def read_cache_file(path: Path) -> dict[str, object]:
    with gzip.open(path, "rt", encoding="utf-8") as f:
        return json.load(f)


def write_cache_file(path: Path, payload: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with gzip.open(path, "wt", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False, separators=(",", ":"))


def load_cached_pair(cache_dir: Path | None, split: str, key: str) -> tuple[list[MidiNote], list[MidiNote], dict[str, object]] | None:
    if cache_dir is None:
        return None
    path = cache_file_path(cache_dir, split, key)
    if not path.is_file():
        return None
    data = read_cache_file(path)
    return (
        [note_from_dict(x) for x in data.get("ref_notes", [])],
        [note_from_dict(x) for x in data.get("pred_notes", [])],
        dict(data.get("analysis_meta", {})),
    )


def note_with_pitch_shift(n: MidiNote, pitch_shift: int) -> MidiNote:
    if pitch_shift == 0:
        return n
    return MidiNote(
        n.start,
        n.end,
        n.pitch + pitch_shift,
        n.velocity,
        pitch_raw=(n.pitch_raw + pitch_shift if n.pitch_raw is not None else None),
        pitch_original=(
            n.pitch_original + pitch_shift if n.pitch_original is not None else None
        ),
        confidence=n.confidence,
        voiced_ratio=n.voiced_ratio,
        assisted=n.assisted,
        source=n.source,
        in_key=n.in_key,
    )


def _source_id(value: str | None) -> int:
    if value == "assistant":
        return 1
    if value == "user":
        return 2
    if value == "model":
        return 3
    return 0


def _candidate_key_features(pitch: int, tonic: str, scale: str) -> dict[str, int]:
    if not tonic or not scale or scale == "chromatic":
        return {
            "pitch_in_detected_key": 1,
            "plus1_in_detected_key": 1,
            "minus1_in_detected_key": 1,
        }
    try:
        pcs = set(scale_pitch_classes(tonic, scale))
    except Exception:
        return {
            "pitch_in_detected_key": 0,
            "plus1_in_detected_key": 0,
            "minus1_in_detected_key": 0,
        }
    return {
        "pitch_in_detected_key": int(pitch % 12 in pcs),
        "plus1_in_detected_key": int((pitch + 1) % 12 in pcs),
        "minus1_in_detected_key": int((pitch - 1) % 12 in pcs),
    }


def _pitch_correction_row(
    note: MidiNote,
    notes: list[MidiNote],
    index: int,
    analysis_meta: dict[str, object],
) -> dict[str, float]:
    detected = analysis_meta.get("detected_key") or {}
    tonic = str(detected.get("tonic") or "") if isinstance(detected, dict) else ""
    scale = str(detected.get("scale") or "") if isinstance(detected, dict) else ""
    prev_pitch = notes[index - 1].pitch if index > 0 else note.pitch
    next_pitch = notes[index + 1].pitch if index + 1 < len(notes) else note.pitch
    pitch_raw = float(note.pitch_raw if note.pitch_raw is not None else note.pitch)
    raw_delta_from_pitch = pitch_raw - float(note.pitch)
    row: dict[str, float] = {
        "pitch_raw_frac": pitch_raw - int(pitch_raw),
        "raw_delta_from_pitch": raw_delta_from_pitch,
        "raw_abs_delta_from_pitch": abs(raw_delta_from_pitch),
        "confidence": float(note.confidence or 0.0),
        "voiced_ratio": float(note.voiced_ratio or 0.0),
        "duration": float(note.duration),
        "pitch_class": float(note.pitch % 12),
        "prev_interval": float(note.pitch - prev_pitch),
        "next_interval": float(next_pitch - note.pitch),
        "assisted": float(bool(note.assisted)),
        "source": float(_source_id(note.source)),
        "in_key": float(bool(note.in_key)),
    }
    row.update({k: float(v) for k, v in _candidate_key_features(note.pitch, tonic, scale).items()})
    return row


def load_pitch_correction_model(path: Path | None) -> dict[str, object] | None:
    if path is None:
        return None
    data = np.load(path, allow_pickle=True)
    return {
        "feature_names": [str(x) for x in data["feature_names"]],
        "classes": data["classes"].astype(np.int32),
        "mean": data["mean"].astype(np.float32),
        "std": data["std"].astype(np.float32),
        "weights": data["weights"].astype(np.float32),
        "margin": float(data["margin"]) if "margin" in data.files else 0.0,
        "path": str(path),
    }


def apply_pitch_correction_model(
    notes: list[MidiNote],
    analysis_meta: dict[str, object],
    model: dict[str, object] | None,
) -> tuple[list[MidiNote], int]:
    if model is None or not notes:
        return notes, 0
    feature_names = model["feature_names"]
    classes = model["classes"]
    mean = model["mean"]
    std = model["std"]
    weights = model["weights"]
    margin = float(model["margin"])
    out: list[MidiNote] = []
    corrections = 0
    zero_idx = int(np.where(classes == 0)[0][0])
    for i, note in enumerate(notes):
        row = _pitch_correction_row(note, notes, i, analysis_meta)
        x = np.asarray([float(row.get(name, 0.0)) for name in feature_names], dtype=np.float32)
        z = (x - mean) / std
        xb = np.concatenate([z, np.ones(1, dtype=np.float32)])
        scores = 1.0 / (1.0 + np.exp(-np.clip(weights @ xb, -40.0, 40.0)))
        pred_idx = int(np.argmax(scores))
        delta = int(classes[pred_idx])
        if delta != 0 and float(scores[pred_idx]) < float(scores[zero_idx]) + margin:
            delta = 0
        if delta == 0:
            out.append(note)
            continue
        corrections += 1
        new_pitch = int(max(0, min(127, note.pitch + delta)))
        out.append(
            MidiNote(
                note.start,
                note.end,
                new_pitch,
                note.velocity,
                pitch_raw=note.pitch_raw,
                pitch_original=note.pitch_original,
                confidence=note.confidence,
                voiced_ratio=note.voiced_ratio,
                assisted=note.assisted,
                source="model",
                in_key=note.in_key,
            )
        )
    return out, corrections


def load_offset_correction_model(path: Path | None) -> dict[str, object] | None:
    if path is None:
        return None
    data = np.load(path, allow_pickle=True)
    return {
        "feature_names": [str(x) for x in data["feature_names"]],
        "mean": data["mean"].astype(np.float32),
        "std": data["std"].astype(np.float32),
        "weights": data["weights"].astype(np.float32),
        "threshold": float(data["threshold"]) if "threshold" in data.files else 999.0,
        "clip": float(data["clip"]) if "clip" in data.files else 0.0,
        "path": str(path),
    }


def _offset_correction_row(note: MidiNote, notes: list[MidiNote], index: int) -> dict[str, float]:
    prev_n = notes[index - 1] if index > 0 else note
    next_n = notes[index + 1] if index + 1 < len(notes) else note
    pitch_raw = float(note.pitch_raw if note.pitch_raw is not None else note.pitch)
    return {
        "pred_duration": float(note.duration),
        "start_delta": 0.0,
        "pitch_class": float(note.pitch % 12),
        "pitch_raw_delta": pitch_raw - float(note.pitch),
        "confidence": float(note.confidence or 0.0),
        "voiced_ratio": float(note.voiced_ratio or 0.0),
        "prev_gap": float(note.start - prev_n.end) if index > 0 else 999.0,
        "next_gap": float(next_n.start - note.end) if index + 1 < len(notes) else 999.0,
        "prev_interval": float(note.pitch - prev_n.pitch),
        "next_interval": float(next_n.pitch - note.pitch),
        "is_first": float(index == 0),
        "is_last": float(index + 1 == len(notes)),
        "assisted": float(bool(note.assisted)),
        "source": float(_source_id(note.source)),
        "in_key": float(bool(note.in_key)),
    }


def apply_offset_correction_model(
    notes: list[MidiNote],
    model: dict[str, object] | None,
) -> tuple[list[MidiNote], int]:
    if model is None or not notes:
        return notes, 0
    feature_names = model["feature_names"]
    mean = model["mean"]
    std = model["std"]
    weights = model["weights"]
    threshold = float(model["threshold"])
    clip = float(model["clip"])
    out: list[MidiNote] = []
    changed = 0
    xb_tail = np.ones(1, dtype=np.float32)
    for i, note in enumerate(notes):
        row = _offset_correction_row(note, notes, i)
        x = np.asarray([float(row.get(name, 0.0)) for name in feature_names], dtype=np.float32)
        z = (x - mean) / std
        delta = float(np.concatenate([z, xb_tail]) @ weights)
        delta = float(np.clip(delta, -clip, clip))
        if abs(delta) < threshold:
            delta = 0.0
        min_end = note.start + 0.035
        max_end = notes[i + 1].start - 0.006 if i + 1 < len(notes) else max(note.end + abs(delta), note.end)
        new_end = max(min_end, min(max_end, note.end + delta))
        if abs(new_end - note.end) < 1e-5:
            out.append(note)
            continue
        changed += 1
        out.append(
            MidiNote(
                note.start,
                new_end,
                note.pitch,
                note.velocity,
                pitch_raw=note.pitch_raw,
                pitch_original=note.pitch_original,
                confidence=note.confidence,
                voiced_ratio=note.voiced_ratio,
                assisted=note.assisted,
                source=note.source,
                in_key=note.in_key,
            )
        )
    return out, changed


def load_split_candidate_model(path: Path | None) -> dict[str, object] | None:
    if path is None:
        return None
    data = np.load(path, allow_pickle=True)
    return {
        "feature_names": [str(x) for x in data["feature_names"]],
        "mean": data["mean"].astype(np.float32),
        "std": data["std"].astype(np.float32),
        "weights": data["weights"].astype(np.float32),
        "threshold": float(data["threshold"]) if "threshold" in data.files else 0.95,
        "path": str(path),
    }


def _arr(meta: dict[str, object], name: str) -> np.ndarray:
    return np.asarray(meta.get(name, []) or [], dtype=np.float32)


def _interp_arr(t: np.ndarray, v: np.ndarray, x: float, fill: float = 0.0) -> float:
    if t.size == 0 or v.size == 0:
        return fill
    vals = np.nan_to_num(v, nan=fill, posinf=fill, neginf=fill)
    return float(np.interp(x, t, vals, left=fill, right=fill))


def _win(t: np.ndarray, v: np.ndarray, start: float, end: float) -> np.ndarray:
    idx = np.where((t >= start) & (t <= end))[0] if t.size else np.zeros(0, dtype=np.int32)
    return v[idx] if idx.size else np.zeros(0, dtype=np.float32)


def _med(a: np.ndarray, default: float = 0.0) -> float:
    a = a[np.isfinite(a)]
    return float(np.median(a)) if a.size else default


def _std(a: np.ndarray) -> float:
    a = a[np.isfinite(a)]
    return float(np.std(a)) if a.size else 0.0


def _split_features(
    note: MidiNote,
    t: float,
    env_t: np.ndarray,
    rms: np.ndarray,
    pitch_t: np.ndarray,
    pitch_midi: np.ndarray,
    voiced: np.ndarray,
    onset: np.ndarray,
    context: float = 0.08,
) -> dict[str, float]:
    left_m = _win(pitch_t, pitch_midi, t - context, t - 0.015)
    right_m = _win(pitch_t, pitch_midi, t + 0.015, t + context)
    left_v = _win(pitch_t, voiced, t - context, t - 0.015)
    right_v = _win(pitch_t, voiced, t + 0.015, t + context)
    local_rms = _win(env_t, rms, t - context, t + context)
    left_rms = _win(env_t, rms, t - context, t - 0.015)
    right_rms = _win(env_t, rms, t + 0.015, t + context)
    lm = _med(left_m, float(note.pitch))
    rm = _med(right_m, float(note.pitch))
    lv = _med(left_v, 0.0)
    rv = _med(right_v, 0.0)
    rms_here = _interp_arr(env_t, rms, t)
    rms_med = float(np.median(local_rms)) if local_rms.size else rms_here
    rms_min = float(np.min(local_rms)) if local_rms.size else rms_here
    return {
        "note_duration": float(note.duration),
        "pos_ratio": (t - note.start) / max(float(note.duration), 1e-6),
        "time_from_start": t - note.start,
        "time_to_end": note.end - t,
        "note_pitch": float(note.pitch),
        "note_confidence": float(note.confidence or 0.0),
        "note_voiced_ratio": float(note.voiced_ratio or 0.0),
        "rms_here": rms_here,
        "rms_min_ratio": rms_min / max(rms_med, 1e-7),
        "rms_left": float(np.median(left_rms)) if left_rms.size else rms_here,
        "rms_right": float(np.median(right_rms)) if right_rms.size else rms_here,
        "onset_here": _interp_arr(env_t, onset, t),
        "pitch_left": lm,
        "pitch_right": rm,
        "pitch_delta_lr": rm - lm,
        "pitch_abs_delta_lr": abs(rm - lm),
        "pitch_std_left": _std(left_m),
        "pitch_std_right": _std(right_m),
        "voiced_left": lv,
        "voiced_right": rv,
        "voiced_delta": rv - lv,
        "same_rounded_pitch": float(round(lm) == round(rm)),
    }


def apply_split_candidate_model(
    notes: list[MidiNote],
    analysis_meta: dict[str, object],
    model: dict[str, object] | None,
    *,
    pitch_mode: str = "local",
) -> tuple[list[MidiNote], int]:
    if model is None or not notes:
        return notes, 0
    env_t = _arr(analysis_meta, "envelope_times")
    rms = _arr(analysis_meta, "envelope_rms")
    pitch_t = _arr(analysis_meta, "pitch_times")
    pitch_midi = _arr(analysis_meta, "pitch_midi")
    voiced = _arr(analysis_meta, "voiced_prob")
    onset = np.zeros_like(rms)
    if rms.size >= 2:
        onset = np.maximum(0.0, np.diff(rms, prepend=rms[0])).astype(np.float32)
        hi = float(np.percentile(onset, 95)) if onset.size else 0.0
        if hi > 1e-9:
            onset = np.clip(onset / hi, 0.0, 1.0)
    feature_names = model["feature_names"]
    mean = model["mean"]
    std = model["std"]
    weights = model["weights"]
    threshold = float(model["threshold"])
    out: list[MidiNote] = []
    splits = 0
    for note in notes:
        if note.duration < 0.16:
            out.append(note)
            continue
        cand_start = note.start + 0.055
        cand_end = note.end - 0.055
        candidates = pitch_t[(pitch_t >= cand_start) & (pitch_t <= cand_end)]
        if candidates.size == 0:
            out.append(note)
            continue
        best_t = None
        best_p = 0.0
        best_feats: dict[str, float] | None = None
        for t0 in candidates:
            t = float(t0)
            feats = _split_features(note, t, env_t, rms, pitch_t, pitch_midi, voiced, onset)
            salient = (
                feats["onset_here"] >= 0.08
                or feats["rms_min_ratio"] <= 0.82
                or feats["pitch_abs_delta_lr"] >= 0.45
                or abs(feats["voiced_delta"]) >= 0.25
            )
            if not salient:
                continue
            x = np.asarray([float(feats.get(name, 0.0)) for name in feature_names], dtype=np.float32)
            z = (x - mean) / std
            xb = np.concatenate([z, np.ones(1, dtype=np.float32)])
            prob = float(1.0 / (1.0 + np.exp(-np.clip(weights @ xb, -40.0, 40.0))))
            if prob > best_p:
                best_p = prob
                best_t = t
                best_feats = feats
        if best_t is None or best_p < threshold:
            out.append(note)
            continue
        left_pitch = int(round(float(best_feats["pitch_left"]))) if best_feats else note.pitch
        right_pitch = int(round(float(best_feats["pitch_right"]))) if best_feats else note.pitch
        if pitch_mode == "original":
            left_pitch = int(note.pitch)
            right_pitch = int(note.pitch)
        elif pitch_mode == "conservative":
            pitch_delta = abs(float(best_feats.get("pitch_delta_lr", 0.0))) if best_feats else 0.0
            same_rounded = bool(best_feats.get("same_rounded_pitch", 0.0)) if best_feats else True
            if same_rounded or pitch_delta < 1.20:
                left_pitch = int(note.pitch)
                right_pitch = int(note.pitch)
        if abs(right_pitch - left_pitch) > 12:
            out.append(note)
            continue
        split_t = float(best_t)
        if split_t - note.start < 0.055 or note.end - split_t < 0.055:
            out.append(note)
            continue
        splits += 1
        out.append(
            MidiNote(
                note.start,
                split_t,
                max(0, min(127, left_pitch)),
                note.velocity,
                pitch_raw=note.pitch_raw,
                pitch_original=note.pitch_original,
                confidence=note.confidence,
                voiced_ratio=note.voiced_ratio,
                assisted=note.assisted,
                source="split_model",
                in_key=note.in_key,
            )
        )
        out.append(
            MidiNote(
                split_t,
                note.end,
                max(0, min(127, right_pitch)),
                note.velocity,
                pitch_raw=note.pitch_raw,
                pitch_original=note.pitch_original,
                confidence=note.confidence,
                voiced_ratio=note.voiced_ratio,
                assisted=note.assisted,
                source="split_model",
                in_key=note.in_key,
            )
        )
    out.sort(key=lambda n: (n.start, n.end, n.pitch))
    return out, splits


def match_notes(
    ref: list[MidiNote],
    pred: list[MidiNote],
    onset_tol: float,
    offset_tol: float,
    pitch_tol: int,
    pitch_shift: int,
) -> tuple[list[tuple[MidiNote, MidiNote]], list[MidiNote], list[MidiNote]]:
    candidates: list[tuple[float, int, int]] = []
    for i, r in enumerate(ref):
        for j, p0 in enumerate(pred):
            p = MidiNote(p0.start, p0.end, p0.pitch + pitch_shift, p0.velocity)
            onset = abs(p.start - r.start)
            offset = abs(p.end - r.end)
            pitch = abs(p.pitch - r.pitch)
            if onset <= onset_tol and offset <= offset_tol and pitch <= pitch_tol:
                candidates.append((onset + offset + pitch * 0.05, i, j))
    candidates.sort()

    used_r: set[int] = set()
    used_p: set[int] = set()
    matches: list[tuple[MidiNote, MidiNote]] = []
    for _, i, j in candidates:
        if i in used_r or j in used_p:
            continue
        used_r.add(i)
        used_p.add(j)
        p0 = pred[j]
        matches.append((ref[i], note_with_pitch_shift(p0, pitch_shift)))

    return (
        matches,
        [n for i, n in enumerate(ref) if i not in used_r],
        [n for j, n in enumerate(pred) if j not in used_p],
    )


def match_onsets(
    ref: list[MidiNote],
    pred: list[MidiNote],
    onset_tol: float,
    pitch_shift: int,
) -> tuple[list[tuple[MidiNote, MidiNote]], list[MidiNote], list[MidiNote]]:
    """One-to-one onset match, ignoring pitch and duration.

    This separates rhythm segmentation from pitch selection. Final note F1 can
    be low even when the note count/onsets are good, so this metric shows where
    the downstream pitch assistant is the bottleneck.
    """
    candidates: list[tuple[float, int, int]] = []
    for i, r in enumerate(ref):
        for j, p0 in enumerate(pred):
            onset = abs(p0.start - r.start)
            if onset <= onset_tol:
                candidates.append((onset, i, j))
    candidates.sort()

    used_r: set[int] = set()
    used_p: set[int] = set()
    matches: list[tuple[MidiNote, MidiNote]] = []
    for _, i, j in candidates:
        if i in used_r or j in used_p:
            continue
        used_r.add(i)
        used_p.add(j)
        p0 = pred[j]
        matches.append((ref[i], note_with_pitch_shift(p0, pitch_shift)))

    return (
        matches,
        [n for i, n in enumerate(ref) if i not in used_r],
        [n for j, n in enumerate(pred) if j not in used_p],
    )


def classify_errors(
    ref: list[MidiNote],
    pred: list[MidiNote],
    onset_matches: list[tuple[MidiNote, MidiNote]],
    onset_missed: list[MidiNote],
    onset_extra: list[MidiNote],
    offset_tol: float,
    pitch_tol: int,
) -> dict[str, int]:
    out = {key: 0 for key in ERROR_KEYS}
    out["missed_onset"] = len(onset_missed)
    out["extra_onset"] = len(onset_extra)

    for r, p in onset_matches:
        pitch_delta = int(p.pitch - r.pitch)
        pitch_bad = abs(pitch_delta) > pitch_tol
        if pitch_bad:
            out["wrong_pitch"] += 1
            if abs(pitch_delta) >= 12 and abs(pitch_delta) % 12 == 0:
                out["octave_error"] += 1
        if not pitch_bad and abs(p.end - r.end) > offset_tol:
            out["bad_offset"] += 1

    for p in pred:
        contained = [
            r for r in ref
            if r.start >= p.start - 0.02 and r.end <= p.end + 0.02
        ]
        if len(contained) >= 2:
            out["merged_notes"] += 1

    for r in ref:
        contained = [
            p for p in pred
            if p.start >= r.start - 0.02 and p.end <= r.end + 0.02
        ]
        if len(contained) >= 2:
            out["false_split"] += 1

    return out


def _prf(matches: int, pred_count: int, ref_count: int) -> tuple[float, float, float]:
    precision = matches / pred_count if pred_count else 0.0
    recall = matches / ref_count if ref_count else 0.0
    f1 = 2 * precision * recall / (precision + recall) if precision + recall else 0.0
    return precision, recall, f1


def frame_accuracy(
    ref: list[MidiNote],
    pred: list[MidiNote],
    pitch_shift: int,
    hop: float = 0.02,
    pitch_tol: float = 0.5,
) -> tuple[float, float, float]:
    if not ref:
        return 0.0, 0.0, 0.0
    end = max([n.end for n in ref] + [n.end for n in pred] + [0.0])
    if end <= 0:
        return 0.0, 0.0, 0.0
    times = np.arange(0.0, end, hop)
    ref_pitch = np.full(times.shape, np.nan)
    pred_pitch = np.full(times.shape, np.nan)
    for arr, notes, shift in ((ref_pitch, ref, 0), (pred_pitch, pred, pitch_shift)):
        for n in notes:
            a = max(0, int(math.floor(n.start / hop)))
            b = min(len(arr), int(math.ceil(n.end / hop)))
            if b > a:
                arr[a:b] = n.pitch + shift

    ref_voiced = np.isfinite(ref_pitch)
    pred_voiced = np.isfinite(pred_pitch)
    if not np.any(ref_voiced):
        return 0.0, 0.0, 0.0
    recall = float(np.mean(pred_voiced[ref_voiced]))
    false_alarm = float(np.mean(pred_voiced[~ref_voiced])) if np.any(~ref_voiced) else 0.0
    both = ref_voiced & pred_voiced
    pitch_acc = float(np.mean(np.abs(ref_pitch[both] - pred_pitch[both]) <= pitch_tol)) if np.any(both) else 0.0
    return pitch_acc, recall, false_alarm


def refine_note_offsets(
    pred: list[MidiNote],
    analysis_meta: dict,
    decay_ratio: float = 0.5,
    max_extend: float = 0.30,
) -> list[MidiNote]:
    """Re-estimate each note END from energy-decay evidence (structural offset fix).

    The note end is set to the first frame after the note's RMS peak where RMS
    falls to decay_ratio * peak, searched in [start, min(next_start, end+max_extend)].
    Targets the structural offset gap (A3): offset-boundary evidence presence is
    ~0.99, but the chunk-end definition misses ~1/4 of true ends.
    """
    import dataclasses
    et = np.asarray(analysis_meta.get("envelope_times", []) or [], dtype=float)
    rms = np.asarray(analysis_meta.get("envelope_rms", []) or [], dtype=float)
    if et.size < 3 or rms.size < 3 or not pred:
        return pred
    out: list[MidiNote] = []
    for idx, n in enumerate(pred):
        nxt = pred[idx + 1].start if idx + 1 < len(pred) else float(et[-1])
        s, e = n.start, n.end
        hi = min(nxt, e + max_extend)
        a = int(np.searchsorted(et, s, "left"))
        b = int(np.searchsorted(et, hi, "right"))
        be = int(np.searchsorted(et, e, "right"))
        if b - a < 2:
            out.append(n)
            continue
        body = rms[a:max(be, a + 1)]
        peak = float(np.max(body)) if body.size else float(np.max(rms[a:b]))
        thr = decay_ratio * peak
        peak_i = a + (int(np.argmax(body)) if body.size else 0)
        new_end = e
        for k in range(peak_i, b):
            if rms[k] <= thr:
                new_end = float(et[k])
                break
        new_end = max(s + 0.04, min(new_end, nxt))
        out.append(dataclasses.replace(n, end=new_end))
    return out


def eval_pair(pair: Pair, args: argparse.Namespace) -> dict[str, object]:
    opts = AnalyzeOptions(
        pitch_model=args.pitch_model,
        auto_key=not args.no_auto_key,
        pitch_assistant=not args.no_pitch_assistant,
        assist_aggressive=args.assist_aggressive,
        learned_pitch_correction=not args.no_learned_pitch_correction,
        learned_offset_correction=bool(args.enable_learned_offset_correction),
        timing_refine=not args.no_timing_refine,
        timing_grid_quantize=False,
        quantize_strength=args.backend_quantize_strength,
        tempo_bpm=args.tempo_bpm,
        timing_attack_lookback_sec=args.timing_attack_lookback_sec,
        timing_max_advance_sec=args.timing_max_advance_sec,
        timing_max_delay_sec=args.timing_max_delay_sec,
        timing_fill_gaps=not args.no_timing_fill_gaps,
        timing_fill_max_gap_sec=args.timing_fill_max_gap_sec,
    )
    cached = load_cached_pair(getattr(args, "cache_dir", None), args.split, pair.key)
    cache_hit = cached is not None
    if cached is not None:
        ref, pred, analysis_meta = cached
    else:
        ref = read_midi_notes(pair.midi, min_dur=args.min_ref_dur)
        pred, analysis_meta = predicted_notes(pair.wav, opts)
    pred, pitch_model_corrections = apply_pitch_correction_model(
        pred, analysis_meta, getattr(args, "pitch_correction", None)
    )
    pred, split_model_corrections = apply_split_candidate_model(
        pred,
        analysis_meta,
        getattr(args, "split_candidate", None),
        pitch_mode=getattr(args, "split_candidate_pitch_mode", "local"),
    )
    pred, offset_model_corrections = apply_offset_correction_model(
        pred, getattr(args, "offset_correction", None)
    )
    if getattr(args, "refine_offsets", False):
        pred = refine_note_offsets(
            pred, analysis_meta,
            decay_ratio=getattr(args, "refine_decay_ratio", 0.5),
            max_extend=getattr(args, "refine_max_extend", 0.30),
        )
    pitch_shift = best_global_pitch_shift(ref, pred) if args.normalize_key else 0
    time_shift = estimate_time_shift(ref, pred, pitch_shift) if args.align_time else 0.0
    pred_unshifted = pred
    pred = shift_notes(pred_unshifted, time_shift)
    matches, missed, extra = match_notes(
        ref, pred, args.onset_tol, args.offset_tol, args.pitch_tol, pitch_shift
    )
    onset_matches, onset_missed, onset_extra = match_onsets(
        ref, pred, args.onset_tol, pitch_shift
    )
    errors = classify_errors(
        ref,
        pred,
        onset_matches,
        onset_missed,
        onset_extra,
        args.offset_tol,
        args.pitch_tol,
    )

    precision, recall, f1 = _prf(len(matches), len(pred), len(ref))
    onset_precision, onset_recall, onset_f1 = _prf(len(onset_matches), len(pred), len(ref))
    onset_mae = statistics.fmean(abs(r.start - p.start) for r, p in matches) if matches else 0.0
    offset_mae = statistics.fmean(abs(r.end - p.end) for r, p in matches) if matches else 0.0
    dur_mae = statistics.fmean(abs(r.duration - p.duration) for r, p in matches) if matches else 0.0
    pitch_mae = statistics.fmean(abs(r.pitch - p.pitch) for r, p in matches) if matches else 0.0
    onset_only_mae = (
        statistics.fmean(abs(r.start - p.start) for r, p in onset_matches)
        if onset_matches
        else 0.0
    )
    onset_pitch_hits = sum(
        1 for r, p in onset_matches if abs(r.pitch - p.pitch) <= args.pitch_tol
    )
    onset_offset_hits = sum(
        1 for r, p in onset_matches if abs(r.end - p.end) <= args.offset_tol
    )
    onset_pitch_acc = onset_pitch_hits / len(onset_matches) if onset_matches else 0.0
    onset_offset_acc = onset_offset_hits / len(onset_matches) if onset_matches else 0.0
    onset_pitch_mae = (
        statistics.fmean(abs(r.pitch - p.pitch) for r, p in onset_matches)
        if onset_matches
        else 0.0
    )
    frame_pitch, frame_voice_recall, frame_false_alarm = frame_accuracy(
        ref, pred, pitch_shift, hop=args.frame_hop, pitch_tol=args.frame_pitch_tol
    )
    if args.details_dir is not None:
        args.details_dir.mkdir(parents=True, exist_ok=True)
        detail = {
            "key": pair.key,
            "pitch_shift_st": pitch_shift,
            "time_shift_sec": time_shift,
            "cache_hit": cache_hit,
            "errors": errors,
            "analysis": analysis_meta,
            "options": {
                "pitch_model": args.pitch_model,
                "onset_tol": args.onset_tol,
                "offset_tol": args.offset_tol,
                "pitch_tol": args.pitch_tol,
                "learned_pitch_correction": not args.no_learned_pitch_correction,
                "learned_offset_correction": bool(args.enable_learned_offset_correction),
            },
            "ref": [note_to_dict(n) for n in ref],
            "pred_unshifted": [note_to_dict(n) for n in pred_unshifted],
            "pred": [note_to_dict(n) for n in pred],
            "matches": [
                {
                    "ref": note_to_dict(r),
                    "pred": note_to_dict(p),
                    "onset_delta_ms": round((p.start - r.start) * 1000.0, 3),
                    "offset_delta_ms": round((p.end - r.end) * 1000.0, 3),
                    "pitch_delta_st": int(p.pitch - r.pitch),
                }
                for r, p in matches
            ],
            "onset_matches": [
                {
                    "ref": note_to_dict(r),
                    "pred": note_to_dict(p),
                    "onset_delta_ms": round((p.start - r.start) * 1000.0, 3),
                    "offset_delta_ms": round((p.end - r.end) * 1000.0, 3),
                    "pitch_delta_st": int(p.pitch - r.pitch),
                }
                for r, p in onset_matches
            ],
            "missed": [note_to_dict(n) for n in missed],
            "extra": [note_to_dict(n) for n in extra],
            "onset_missed": [note_to_dict(n) for n in onset_missed],
            "onset_extra": [note_to_dict(n) for n in onset_extra],
        }
        (args.details_dir / f"{pair.key}.json").write_text(
            json.dumps(detail, indent=2, ensure_ascii=False),
            encoding="utf-8",
        )
    return {
        "key": pair.key,
        "ref_notes": len(ref),
        "pred_notes": len(pred),
        "pitch_model_corrections": pitch_model_corrections,
        "split_model_corrections": split_model_corrections,
        "offset_model_corrections": offset_model_corrections,
        "cache_hit": int(cache_hit),
        "matches": len(matches),
        "missed": len(missed),
        "extra": len(extra),
        "precision": precision,
        "recall": recall,
        "f1": f1,
        "note_accuracy": recall,
        "onset_matches": len(onset_matches),
        "onset_missed": len(onset_missed),
        "onset_extra": len(onset_extra),
        **errors,
        "onset_precision": onset_precision,
        "onset_recall": onset_recall,
        "onset_f1": onset_f1,
        "onset_only_mae_ms": onset_only_mae * 1000.0,
        "onset_pitch_acc": onset_pitch_acc,
        "onset_pitch_mae_st": onset_pitch_mae,
        "onset_offset_acc": onset_offset_acc,
        "onset_mae_ms": onset_mae * 1000.0,
        "offset_mae_ms": offset_mae * 1000.0,
        "duration_mae_ms": dur_mae * 1000.0,
        "pitch_mae_st": pitch_mae,
        "global_shift_st": pitch_shift,
        "time_shift_ms": time_shift * 1000.0,
        "frame_pitch_acc": frame_pitch,
        "frame_voice_recall": frame_voice_recall,
        "frame_false_alarm": frame_false_alarm,
        "wav": pair.wav.label(),
        "midi": pair.midi.label(),
        "missed_preview": " ".join(_note_name(n.pitch) for n in missed[:8]),
        "extra_preview": " ".join(_note_name(n.pitch) for n in extra[:8]),
        "onset_missed_preview": " ".join(_note_name(n.pitch) for n in onset_missed[:8]),
        "onset_extra_preview": " ".join(_note_name(n.pitch) for n in onset_extra[:8]),
    }


def _mean(rows: list[dict[str, object]], key: str) -> float:
    vals = [float(r[key]) for r in rows]
    return statistics.fmean(vals) if vals else 0.0


def _weighted_onset_pitch_upper(rows: list[dict[str, object]]) -> dict[str, float]:
    """Upper bound if every onset+pitch match also got a correct offset."""
    exact = sum(float(r["onset_matches"]) * float(r["onset_pitch_acc"]) for r in rows)
    pred_count = sum(float(r["pred_notes"]) for r in rows)
    ref_count = sum(float(r["ref_notes"]) for r in rows)
    precision = exact / pred_count if pred_count else 0.0
    recall = exact / ref_count if ref_count else 0.0
    f1 = 2.0 * precision * recall / (precision + recall) if precision + recall else 0.0
    return {
        "matches": exact,
        "precision": precision,
        "recall": recall,
        "f1": f1,
    }


def _sum_int(rows: list[dict[str, object]], key: str) -> int:
    return int(sum(int(r.get(key, 0)) for r in rows))


def _git_revision() -> dict[str, object]:
    try:
        rev = subprocess.check_output(
            ["git", "rev-parse", "--short", "HEAD"],
            cwd=Path(__file__).resolve().parent.parent,
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
    except Exception:
        rev = ""
    try:
        dirty = bool(subprocess.check_output(
            ["git", "status", "--porcelain"],
            cwd=Path(__file__).resolve().parent.parent,
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip())
    except Exception:
        dirty = False
    return {"revision": rev, "dirty": dirty}


def _config_hash(options: dict[str, object]) -> str:
    raw = json.dumps(options, sort_keys=True, ensure_ascii=False).encode("utf-8")
    return hashlib.sha256(raw).hexdigest()[:16]


def split_pairs(
    pairs: list[Pair],
    split: str,
    train_ratio: float,
    dev_ratio: float,
    seed: int,
) -> tuple[list[Pair], dict[str, str]]:
    if split == "all":
        return pairs, {p.key: "all" for p in pairs}
    if train_ratio <= 0 or dev_ratio <= 0 or train_ratio + dev_ratio >= 1:
        raise SystemExit("--train-ratio and --dev-ratio must leave a positive test split.")

    shuffled = list(pairs)
    random.Random(seed).shuffle(shuffled)
    n = len(shuffled)
    train_end = int(round(n * train_ratio))
    dev_end = train_end + int(round(n * dev_ratio))
    split_by_key: dict[str, str] = {}
    for i, pair in enumerate(shuffled):
        if i < train_end:
            split_by_key[pair.key] = "train"
        elif i < dev_end:
            split_by_key[pair.key] = "dev"
        else:
            split_by_key[pair.key] = "test"
    return [p for p in pairs if split_by_key[p.key] == split], split_by_key


def write_manifest(path: Path, pairs: list[Pair], split_by_key: dict[str, str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=["key", "split", "wav", "midi"])
        writer.writeheader()
        for pair in pairs:
            writer.writerow(
                {
                    "key": pair.key,
                    "split": split_by_key.get(pair.key, "all"),
                    "wav": pair.wav.label(),
                    "midi": pair.midi.label(),
                }
            )


def read_manifest_splits(path: Path) -> dict[str, str]:
    out: dict[str, str] = {}
    with path.open(newline="", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            key = str(row.get("key") or "")
            split = str(row.get("split") or "")
            if key and split:
                out[key] = split
    return out


def choose_pairs(
    all_pairs: list[Pair],
    args: argparse.Namespace,
) -> tuple[list[Pair], dict[str, str], str]:
    manifest_path = args.split_manifest_csv
    if manifest_path is None and args.root is not None:
        candidate = args.root / "humtrans_manifest.csv"
        if candidate.is_file():
            manifest_path = candidate
    if manifest_path is not None:
        split_by_key = read_manifest_splits(manifest_path)
        if args.split == "all":
            return all_pairs, split_by_key, str(manifest_path)
        return (
            [p for p in all_pairs if split_by_key.get(p.key) == args.split],
            split_by_key,
            str(manifest_path),
        )
    pairs, split_by_key = split_pairs(
        all_pairs, args.split, args.train_ratio, args.dev_ratio, args.seed
    )
    return pairs, split_by_key, ""


def summarize(rows: list[dict[str, object]], args: argparse.Namespace, total_pairs: int) -> dict[str, object]:
    onset_pitch_upper = _weighted_onset_pitch_upper(rows)
    options = {
        "pitch_model": args.pitch_model,
        "normalize_key": bool(args.normalize_key),
        "align_time": bool(args.align_time),
        "onset_tol": args.onset_tol,
        "offset_tol": args.offset_tol,
        "backend_quantize_strength": args.backend_quantize_strength,
        "assist_aggressive": bool(args.assist_aggressive),
        "timing_attack_lookback_sec": args.timing_attack_lookback_sec,
        "timing_max_advance_sec": args.timing_max_advance_sec,
        "timing_max_delay_sec": args.timing_max_delay_sec,
        "timing_fill_gaps": not args.no_timing_fill_gaps,
        "timing_fill_max_gap_sec": args.timing_fill_max_gap_sec,
        "pitch_correction_model": str(args.pitch_correction_model or ""),
        "split_candidate_model": str(args.split_candidate_model or ""),
        "split_candidate_pitch_mode": str(args.split_candidate_pitch_mode),
        "offset_correction_model": str(args.offset_correction_model or ""),
        "learned_pitch_correction": not args.no_learned_pitch_correction,
        "learned_offset_correction": bool(args.enable_learned_offset_correction),
        "cache_dir": str(args.cache_dir or ""),
    }
    error_counts = {key: _sum_int(rows, key) for key in ERROR_KEYS}
    return {
        "pairs_evaluated": len(rows),
        "pairs_requested": total_pairs,
        "split": args.split,
        "limit": args.limit,
        "offset": args.offset,
        "seed": args.seed,
        "split_manifest_csv": str(args.active_split_manifest_csv or ""),
        "git": _git_revision(),
        "config_hash": _config_hash(options),
        "cache_hits": _sum_int(rows, "cache_hit"),
        "cache_hit_rate": _mean(rows, "cache_hit"),
        "note_precision": _mean(rows, "precision"),
        "note_recall": _mean(rows, "recall"),
        "note_f1": _mean(rows, "f1"),
        "note_accuracy": _mean(rows, "note_accuracy"),
        "onset_precision": _mean(rows, "onset_precision"),
        "onset_recall": _mean(rows, "onset_recall"),
        "onset_f1": _mean(rows, "onset_f1"),
        "onset_only_mae_ms": _mean(rows, "onset_only_mae_ms"),
        "onset_pitch_accuracy": _mean(rows, "onset_pitch_acc"),
        "onset_pitch_mae_st": _mean(rows, "onset_pitch_mae_st"),
        "onset_offset_accuracy": _mean(rows, "onset_offset_acc"),
        "upper_if_offsets_fixed_f1": onset_pitch_upper["f1"],
        "upper_if_offsets_fixed_precision": onset_pitch_upper["precision"],
        "upper_if_offsets_fixed_recall": onset_pitch_upper["recall"],
        "pitch_model_corrections": _mean(rows, "pitch_model_corrections"),
        "split_model_corrections": _mean(rows, "split_model_corrections"),
        "offset_model_corrections": _mean(rows, "offset_model_corrections"),
        "onset_mae_ms": _mean(rows, "onset_mae_ms"),
        "duration_mae_ms": _mean(rows, "duration_mae_ms"),
        "pitch_mae_st": _mean(rows, "pitch_mae_st"),
        "time_shift_ms": _mean(rows, "time_shift_ms"),
        "frame_pitch_accuracy": _mean(rows, "frame_pitch_acc"),
        "frame_voice_recall": _mean(rows, "frame_voice_recall"),
        "frame_false_alarm": _mean(rows, "frame_false_alarm"),
        "errors": error_counts,
        "options": options,
    }


def main() -> int:
    ap = argparse.ArgumentParser(description="Evaluate HumTrack on HumTrans WAV/MIDI pairs.")
    ap.add_argument("--root", type=Path, help="HumTrans root containing all_wav/all_midi dirs or ZIP files.")
    ap.add_argument("--wav-dir", type=Path)
    ap.add_argument("--midi-dir", type=Path)
    ap.add_argument("--wav-zip", type=Path)
    ap.add_argument("--midi-zip", type=Path)
    ap.add_argument("--csv", type=Path, default=Path("humtrans_eval.csv"))
    ap.add_argument("--summary-json", type=Path)
    ap.add_argument("--details-dir", type=Path)
    ap.add_argument("--cache-dir", type=Path)
    ap.add_argument("--manifest-csv", type=Path)
    ap.add_argument("--split-manifest-csv", type=Path)
    ap.add_argument("--split", choices=["all", "train", "dev", "test"], default="all")
    ap.add_argument("--train-ratio", type=float, default=0.80)
    ap.add_argument("--dev-ratio", type=float, default=0.10)
    ap.add_argument("--seed", type=int, default=20260605)
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--offset", type=int, default=0)
    ap.add_argument("--pitch-model", choices=["pyin", "crepe"], default="pyin")
    ap.add_argument("--tempo-bpm", type=int, default=90)
    ap.add_argument("--backend-quantize-strength", type=float, default=0.45)
    ap.add_argument("--no-auto-key", action="store_true")
    ap.add_argument("--no-pitch-assistant", action="store_true")
    ap.add_argument("--assist-aggressive", dest="assist_aggressive", action="store_true", default=True)
    ap.add_argument("--no-assist-aggressive", dest="assist_aggressive", action="store_false")
    ap.add_argument("--no-learned-pitch-correction", action="store_true")
    ap.add_argument("--enable-learned-offset-correction", action="store_true")
    ap.add_argument("--no-timing-refine", action="store_true")
    ap.add_argument("--timing-attack-lookback-sec", type=float, default=0.24)
    ap.add_argument("--timing-max-advance-sec", type=float, default=0.28)
    ap.add_argument("--timing-max-delay-sec", type=float, default=0.06)
    ap.add_argument("--no-timing-fill-gaps", action="store_true")
    ap.add_argument("--timing-fill-max-gap-sec", type=float, default=0.50)
    ap.add_argument("--normalize-key", action="store_true", help="Allow one global semitone shift per file.")
    ap.add_argument("--align-time", action="store_true", help="Estimate one global time shift per file.")
    ap.add_argument("--onset-tol", type=float, default=0.12)
    ap.add_argument("--offset-tol", type=float, default=0.18)
    ap.add_argument("--pitch-tol", type=int, default=0)
    ap.add_argument("--pitch-correction-model", type=Path)
    ap.add_argument("--split-candidate-model", type=Path)
    ap.add_argument(
        "--split-candidate-pitch-mode",
        choices=["local", "original", "conservative"],
        default="local",
        help="How split-candidate notes choose pitch after a split.",
    )
    ap.add_argument("--offset-correction-model", type=Path)
    ap.add_argument("--refine-offsets", action="store_true", help="Energy-decay note-END refinement.")
    ap.add_argument("--refine-decay-ratio", type=float, default=0.5)
    ap.add_argument("--refine-max-extend", type=float, default=0.30)
    ap.add_argument("--frame-hop", type=float, default=0.02)
    ap.add_argument("--frame-pitch-tol", type=float, default=0.5)
    ap.add_argument("--min-ref-dur", type=float, default=0.03)
    args = ap.parse_args()
    args.pitch_correction = load_pitch_correction_model(args.pitch_correction_model)
    args.split_candidate = load_split_candidate_model(args.split_candidate_model)
    args.offset_correction = load_offset_correction_model(args.offset_correction_model)

    all_pairs = find_pairs(args.root, args.wav_dir, args.midi_dir, args.wav_zip, args.midi_zip)
    pairs, split_by_key, active_manifest = choose_pairs(all_pairs, args)
    args.active_split_manifest_csv = active_manifest
    if args.manifest_csv is not None:
        write_manifest(args.manifest_csv, all_pairs, split_by_key)
    if args.offset:
        pairs = pairs[args.offset:]
    if args.limit > 0:
        pairs = pairs[: args.limit]
    if not pairs:
        raise SystemExit("No matching WAV/MIDI pairs found.")

    rows: list[dict[str, object]] = []
    for i, pair in enumerate(pairs, 1):
        try:
            row = eval_pair(pair, args)
            rows.append(row)
            print(
                f"[{i:04d}/{len(pairs):04d}] {pair.key} "
                f"F1={float(row['f1']):.3f} P={float(row['precision']):.3f} "
                f"R={float(row['recall']):.3f} notes={row['pred_notes']}/{row['ref_notes']} "
                f"onsetF1={float(row['onset_f1']):.3f} "
                f"onsetPitch={float(row['onset_pitch_acc']):.3f} "
                f"onset={float(row['onset_mae_ms']):.1f}ms "
                f"pitch_shift={row['global_shift_st']} time_shift={float(row['time_shift_ms']):.1f}ms"
            )
        except Exception as exc:
            print(f"[{i:04d}/{len(pairs):04d}] {pair.key} FAILED: {exc}", file=sys.stderr)

    if rows:
        args.csv.parent.mkdir(parents=True, exist_ok=True)
        with args.csv.open("w", newline="", encoding="utf-8") as f:
            writer = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
            writer.writeheader()
            writer.writerows(rows)
    summary = summarize(rows, args, len(pairs))
    if args.summary_json is not None:
        args.summary_json.parent.mkdir(parents=True, exist_ok=True)
        args.summary_json.write_text(
            json.dumps(summary, indent=2, ensure_ascii=False),
            encoding="utf-8",
        )

    print("=" * 78)
    print(f"pairs evaluated      : {summary['pairs_evaluated']} / {summary['pairs_requested']}")
    print(f"split                : {args.split}")
    print(f"csv                  : {args.csv}")
    print(f"summary json         : {args.summary_json or ''}")
    print(f"cache hits           : {summary['cache_hits']} ({float(summary['cache_hit_rate']):.2f})")
    print(f"config hash          : {summary['config_hash']}")
    print(f"note precision       : {float(summary['note_precision']):.3f}")
    print(f"note recall          : {float(summary['note_recall']):.3f}")
    print(f"note f1              : {float(summary['note_f1']):.3f}")
    print(f"note accuracy        : {float(summary['note_accuracy']):.3f}")
    print(f"onset f1             : {float(summary['onset_f1']):.3f}")
    print(f"onset-only mae       : {float(summary['onset_only_mae_ms']):.1f} ms")
    print(f"onset pitch accuracy : {float(summary['onset_pitch_accuracy']):.3f}")
    print(f"onset pitch mae      : {float(summary['onset_pitch_mae_st']):.2f} st")
    print(f"onset offset accuracy: {float(summary['onset_offset_accuracy']):.3f}")
    print(f"offset-fixed upper f1: {float(summary['upper_if_offsets_fixed_f1']):.3f}")
    print(f"pitch model changes  : {float(summary['pitch_model_corrections']):.1f} / file")
    print(f"split model changes  : {float(summary['split_model_corrections']):.1f} / file")
    print(f"offset model changes : {float(summary['offset_model_corrections']):.1f} / file")
    print(f"onset mae            : {float(summary['onset_mae_ms']):.1f} ms")
    print(f"duration mae         : {float(summary['duration_mae_ms']):.1f} ms")
    print(f"pitch mae            : {float(summary['pitch_mae_st']):.2f} st")
    print(f"time shift           : {float(summary['time_shift_ms']):.1f} ms")
    print(f"frame pitch accuracy : {float(summary['frame_pitch_accuracy']):.3f}")
    print(f"frame voice recall   : {float(summary['frame_voice_recall']):.3f}")
    print(f"frame false alarm    : {float(summary['frame_false_alarm']):.3f}")
    print(f"errors               : {json.dumps(summary['errors'], ensure_ascii=False)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
