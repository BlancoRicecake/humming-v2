"""Local drum-voice classifier inference (kick / snare / hihat).

Pure-numpy classifier models trained offline on AVP voice beatbox
(train_drum_classifier_model.py), loaded from ``models/drum_classifier_v2.npz``
when present or the existing ``drum_classifier_v1.npz`` fallback. No sklearn is
used at serve time. Returns a GM note (36/38/42) or None when no compatible model
is present, so callers fall back to the hand-tuned heuristic in
drums.classify_features.

The model exists because voiced snare and hi-hat overlap ~70% on every single
spectral feature; a learned combination is the only thing that separates them
(see docs/experiments/drum_pipeline_90_plan.md).
"""
from __future__ import annotations

import os
from pathlib import Path
from typing import Optional

import numpy as np

from .drum_features import FEATURE_NAMES, FEATURE_NAMES_V2, extract_for_names

MODEL_DIR = Path(__file__).resolve().parent.parent / "models"
MODEL_PATHS = (
    MODEL_DIR / "drum_classifier_v2.npz",
    MODEL_DIR / "drum_classifier_v1.npz",
)
_MODEL: Optional[dict[str, object]] = None
_MODEL_ERROR: Optional[str] = None


def _known_feature_names(names: list[str]) -> bool:
    return names in (list(FEATURE_NAMES_V2), list(FEATURE_NAMES))


def _load() -> Optional[dict[str, object]]:
    global _MODEL, _MODEL_ERROR
    if _MODEL is not None:
        return _MODEL
    if _MODEL_ERROR is not None:
        return None
    errors: list[str] = []
    for path in MODEL_PATHS:
        if not path.exists():
            continue
        try:
            data = np.load(path, allow_pickle=True)
            names = [str(x) for x in data["feature_names"]]
            if not _known_feature_names(names):
                raise ValueError(f"feature mismatch: model={names}")
            mtype = str(data["model_type"]) if "model_type" in data.files else "logistic"
            m: dict[str, object] = {
                "type": mtype,
                "classes": data["classes"].astype(np.int32),
                "feature_names": names,
                "path": str(path),
            }
            if mtype == "rf":
                m["trees"] = [
                    (data["rf_cl"][i], data["rf_cr"][i], data["rf_feat"][i],
                     data["rf_thr"][i], data["rf_val"][i])
                    for i in range(len(data["rf_cl"]))
                ]
            else:
                m["mean"] = data["mean"].astype(np.float32)
                m["std"] = data["std"].astype(np.float32)
                m["weights"] = data["weights"].astype(np.float32)
            _MODEL = m
            return _MODEL
        except Exception as exc:  # missing file, bad format, feature drift
            errors.append(f"{path.name}: {exc}")
    _MODEL_ERROR = "; ".join(errors) if errors else "no drum classifier model"
    return None


def _forest_class_idx(trees, x: np.ndarray) -> int:
    """Average leaf class-probabilities across the forest; return the 0/1/2 index."""
    votes = np.zeros(3, dtype=np.float64)
    for cl, cr, feat, thr, val in trees:
        node = 0
        while cl[node] != -1:
            node = cl[node] if x[feat[node]] <= thr[node] else cr[node]
        votes += val[node]
    return int(np.argmax(votes))


def available() -> bool:
    """Model is ON by default — disable with ``HUMTRACK_DRUM_MODEL=0``.

    The shipped v1 RandomForest is trained on AVP *detected-onset* voice beatbox
    (serve-aligned) and lifts end-to-end improv ``drum_f1`` 0.484→0.618 with healthy
    per-class recall (kick 0.77 / snare 0.62 / hihat 0.80). It is voice-tuned, so
    set ``HUMTRACK_DRUM_MODEL=0`` to fall back to the hand-tuned heuristic (e.g. for
    acoustic-drum input). See docs/experiments/drum_pipeline_90_plan.md.
    """
    if os.environ.get("HUMTRACK_DRUM_MODEL", "") in ("0", "false", "False"):
        return False
    return _load() is not None


def predict_features(x: np.ndarray) -> Optional[int]:
    """Return GM note (36/38/42) for a precomputed feature vector, or None."""
    model = _load()
    if model is None:
        return None
    x = np.asarray(x, dtype=np.float32)
    if model["type"] == "rf":
        idx = _forest_class_idx(model["trees"], x)
    else:
        z = (x - model["mean"]) / model["std"]
        xb = np.concatenate([z, np.ones(1, dtype=np.float32)])
        scores = 1.0 / (1.0 + np.exp(-np.clip(model["weights"] @ xb, -40.0, 40.0)))
        idx = int(np.argmax(scores))
    return int(model["classes"][idx])


def predict_segment(seg: np.ndarray, seg_long: np.ndarray | None, sr: int) -> Optional[int]:
    """Return GM note (36/38/42) for a percussive segment, or None if no model."""
    model = _load()
    if model is None:
        return None
    return predict_features(extract_for_names(model["feature_names"], seg, seg_long, sr))
