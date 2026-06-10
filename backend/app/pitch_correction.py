"""Learned note-level pitch correction.

Small conservative model trained on HumTrans pitch-correction rows. It only
predicts {-1, 0, +1} semitone corrections and keeps the model's saved margin,
so "no correction" remains the default unless the model is clearly confident.
"""
from __future__ import annotations

from pathlib import Path
from typing import Optional

import numpy as np

from .scales import scale_pitch_classes


MODEL_PATH = Path(__file__).resolve().parent.parent / "models" / "pitch_correction_v1.npz"
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


def _candidate_key_features(pitch: int, tonic: str | None, scale: str | None) -> dict[str, int]:
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
            "classes": data["classes"].astype(np.int32),
            "mean": data["mean"].astype(np.float32),
            "std": data["std"].astype(np.float32),
            "weights": data["weights"].astype(np.float32),
            "margin": float(data["margin"]) if "margin" in data.files else 0.0,
        }
    except Exception as exc:
        _MODEL_ERROR = str(exc)
        return None
    return _MODEL


def _row(note: object, notes: list[object], index: int, tonic: str | None, scale: str | None) -> dict[str, float]:
    pitch = int(getattr(note, "pitch", 0))
    pitch_raw = float(getattr(note, "pitch_raw", pitch))
    prev_pitch = int(getattr(notes[index - 1], "pitch", pitch)) if index > 0 else pitch
    next_pitch = int(getattr(notes[index + 1], "pitch", pitch)) if index + 1 < len(notes) else pitch
    raw_delta_from_pitch = pitch_raw - float(pitch)
    out: dict[str, float] = {
        "pitch_raw_frac": pitch_raw - int(pitch_raw),
        "raw_delta_from_pitch": raw_delta_from_pitch,
        "raw_abs_delta_from_pitch": abs(raw_delta_from_pitch),
        "confidence": float(getattr(note, "confidence", 0.0) or 0.0),
        "voiced_ratio": float(getattr(note, "voiced_ratio", 0.0) or 0.0),
        "duration": float(getattr(note, "duration", 0.0) or 0.0),
        "pitch_class": float(pitch % 12),
        "prev_interval": float(pitch - prev_pitch),
        "next_interval": float(next_pitch - pitch),
        "assisted": float(bool(getattr(note, "assisted", False))),
        "source": float(_source_id(getattr(note, "source", "raw"))),
        "in_key": float(bool(getattr(note, "in_key", False))),
    }
    out.update({k: float(v) for k, v in _candidate_key_features(pitch, tonic, scale).items()})
    return out


def apply_learned_pitch_correction(notes: list[object], tonic: str | None, scale: str | None) -> int:
    model = _load_model()
    if model is None or not notes:
        return 0
    feature_names = model["feature_names"]
    classes = model["classes"]
    mean = model["mean"]
    std = model["std"]
    weights = model["weights"]
    margin = float(model["margin"])
    zero_idx = int(np.where(classes == 0)[0][0])
    applied = 0
    for i, note in enumerate(notes):
        if getattr(note, "kind", "pitched") != "pitched":
            continue
        features = _row(note, notes, i, tonic, scale)
        x = np.asarray([float(features.get(name, 0.0)) for name in feature_names], dtype=np.float32)
        z = (x - mean) / std
        xb = np.concatenate([z, np.ones(1, dtype=np.float32)])
        scores = 1.0 / (1.0 + np.exp(-np.clip(weights @ xb, -40.0, 40.0)))
        pred_idx = int(np.argmax(scores))
        delta = int(classes[pred_idx])
        if delta != 0 and float(scores[pred_idx]) < float(scores[zero_idx]) + margin:
            delta = 0
        if delta == 0:
            continue
        old_pitch = int(getattr(note, "pitch", 0))
        new_pitch = int(max(0, min(127, old_pitch + delta)))
        if new_pitch == old_pitch:
            continue
        note.pitch = new_pitch
        note.pitch_hz = float(440.0 * (2.0 ** ((new_pitch - 69) / 12.0)))
        note.source = "model"
        note.correction_cents = round((new_pitch - float(getattr(note, "pitch_raw", new_pitch))) * 100.0, 1)
        applied += 1
    return applied
