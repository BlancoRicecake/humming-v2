"""Learned note-level offset/duration correction.

Small conservative model trained on HumTrans onset+pitch matched rows. It only
adjusts note end times, keeping starts and note count intact.
"""
from __future__ import annotations

from pathlib import Path
from typing import Optional

import numpy as np


MODEL_PATH = Path(__file__).resolve().parent.parent / "models" / "offset_correction_v1.npz"
_MODEL: Optional[dict[str, object]] = None
_MODEL_ERROR: Optional[str] = None


def _source_id(value: str | None) -> int:
    if value == "assistant":
        return 1
    if value == "user":
        return 2
    if value == "model":
        return 3
    return 0


def _load_model() -> Optional[dict[str, object]]:
    global _MODEL, _MODEL_ERROR
    if _MODEL is not None:
        return _MODEL
    if _MODEL_ERROR is not None:
        return None
    try:
        data = np.load(MODEL_PATH, allow_pickle=True)
        _MODEL = {
            "feature_names": [str(x) for x in data["feature_names"]],
            "mean": data["mean"].astype(np.float32),
            "std": data["std"].astype(np.float32),
            "weights": data["weights"].astype(np.float32),
            "threshold": float(data["threshold"]) if "threshold" in data.files else 999.0,
            "clip": float(data["clip"]) if "clip" in data.files else 0.0,
        }
    except Exception as exc:
        _MODEL_ERROR = str(exc)
        return None
    return _MODEL


def _row(note: object, notes: list[object], index: int) -> dict[str, float]:
    prev_n = notes[index - 1] if index > 0 else note
    next_n = notes[index + 1] if index + 1 < len(notes) else note
    pitch = int(getattr(note, "pitch", 0))
    pitch_raw = float(getattr(note, "pitch_raw", pitch))
    return {
        "pred_duration": float(getattr(note, "duration", 0.0) or 0.0),
        "start_delta": 0.0,
        "pitch_class": float(pitch % 12),
        "pitch_raw_delta": pitch_raw - float(pitch),
        "confidence": float(getattr(note, "confidence", 0.0) or 0.0),
        "voiced_ratio": float(getattr(note, "voiced_ratio", 0.0) or 0.0),
        "prev_gap": float(note.start - prev_n.end) if index > 0 else 999.0,
        "next_gap": float(next_n.start - note.end) if index + 1 < len(notes) else 999.0,
        "prev_interval": float(pitch - int(getattr(prev_n, "pitch", pitch))),
        "next_interval": float(int(getattr(next_n, "pitch", pitch)) - pitch),
        "is_first": float(index == 0),
        "is_last": float(index + 1 == len(notes)),
        "assisted": float(bool(getattr(note, "assisted", False))),
        "source": float(_source_id(getattr(note, "source", "raw"))),
        "in_key": float(bool(getattr(note, "in_key", False))),
    }


def apply_learned_offset_correction(notes: list[object]) -> int:
    model = _load_model()
    if model is None or not notes:
        return 0
    feature_names = model["feature_names"]
    mean = model["mean"]
    std = model["std"]
    weights = model["weights"]
    threshold = float(model["threshold"])
    clip = float(model["clip"])
    xb_tail = np.ones(1, dtype=np.float32)
    applied = 0
    for i, note in enumerate(notes):
        if getattr(note, "kind", "pitched") != "pitched":
            continue
        features = _row(note, notes, i)
        x = np.asarray([float(features.get(name, 0.0)) for name in feature_names], dtype=np.float32)
        z = (x - mean) / std
        delta = float(np.concatenate([z, xb_tail]) @ weights)
        delta = float(np.clip(delta, -clip, clip))
        if abs(delta) < threshold:
            continue
        min_end = float(note.start) + 0.035
        if i + 1 < len(notes):
            max_end = float(notes[i + 1].start) - 0.006
        else:
            max_end = max(float(note.end + abs(delta)), float(note.end))
        new_end = max(min_end, min(max_end, float(note.end) + delta))
        if abs(new_end - float(note.end)) < 1e-5:
            continue
        note.end = new_end
        note.duration = max(0.0, new_end - float(note.start))
        applied += 1
    return applied
