"""Train a note-level pitch correction baseline from HumTrans CSV rows.

The first model is intentionally conservative: one-vs-rest logistic heads for
small pitch deltas. Large pitch errors are kept in the report but not used as
correction targets yet; they usually come from bad contour segmentation and need
a different fix.
"""
from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path

import numpy as np


FEATURES = [
    "pitch_raw_frac",
    "raw_delta_from_pitch",
    "raw_abs_delta_from_pitch",
    "confidence",
    "voiced_ratio",
    "duration",
    "pitch_class",
    "prev_interval",
    "next_interval",
    "assisted",
    "source",
    "in_key",
    "pitch_in_detected_key",
    "plus1_in_detected_key",
    "minus1_in_detected_key",
]
DEFAULT_CLASSES = [-1, 0, 1]


def _sigmoid(z: np.ndarray) -> np.ndarray:
    return 1.0 / (1.0 + np.exp(-np.clip(z, -40.0, 40.0)))


def _read_csv(path: Path, classes: list[int]) -> tuple[np.ndarray, np.ndarray]:
    rows: list[list[float]] = []
    y: list[int] = []
    with path.open(newline="", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            delta = int(row["pitch_delta"])
            if delta not in classes:
                continue
            rows.append([float(row[name]) for name in FEATURES])
            y.append(delta)
    if not rows:
        raise SystemExit(f"No usable rows in {path}")
    return np.asarray(rows, dtype=np.float32), np.asarray(y, dtype=np.int32)


def _fit_ovr(
    x: np.ndarray,
    y: np.ndarray,
    classes: list[int],
    epochs: int,
    lr: float,
    l2: float,
) -> np.ndarray:
    xb = np.concatenate([x, np.ones((x.shape[0], 1), dtype=np.float32)], axis=1)
    weights = np.zeros((len(classes), xb.shape[1]), dtype=np.float32)
    for ci, cls in enumerate(classes):
        target = (y == cls).astype(np.float32)
        pos = float(target.sum())
        neg = float(target.size - pos)
        pos_weight = min(30.0, neg / max(pos, 1.0))
        w = np.zeros(xb.shape[1], dtype=np.float32)
        step = lr
        for epoch in range(epochs):
            pred = _sigmoid(xb @ w)
            sample_w = np.where(target > 0.5, pos_weight, 1.0).astype(np.float32)
            grad = (xb.T @ ((pred - target) * sample_w)) / max(1, target.size)
            grad[:-1] += l2 * w[:-1]
            w -= step * grad.astype(np.float32)
            if epoch and epoch % 80 == 0:
                step *= 0.7
        weights[ci] = w
    return weights


def _predict(
    x: np.ndarray,
    weights: np.ndarray,
    classes: list[int],
    margin: float = 0.0,
) -> tuple[np.ndarray, np.ndarray]:
    xb = np.concatenate([x, np.ones((x.shape[0], 1), dtype=np.float32)], axis=1)
    scores = _sigmoid(xb @ weights.T)
    # Prefer no correction unless a non-zero class is clearly stronger.
    pred_idx = np.argmax(scores, axis=1)
    pred = np.asarray([classes[i] for i in pred_idx], dtype=np.int32)
    zero_idx = classes.index(0)
    if margin > 0:
        zero_score = scores[:, zero_idx]
        chosen_score = scores[np.arange(scores.shape[0]), pred_idx]
        pred[(pred != 0) & (chosen_score < zero_score + margin)] = 0
    return pred, scores


def _metrics(y: np.ndarray, pred: np.ndarray) -> dict[str, float]:
    before = float(np.mean(y == 0))
    after = float(np.mean(y == pred))
    corrected = int(np.sum((y != 0) & (y == pred)))
    damaged = int(np.sum((y == 0) & (pred != 0)))
    return {
        "rows": int(y.size),
        "baseline_accuracy": before,
        "model_accuracy": after,
        "corrected_errors": corrected,
        "damaged_correct_notes": damaged,
        "net_gain": corrected - damaged,
    }


def _best_margin(
    y: np.ndarray,
    x: np.ndarray,
    weights: np.ndarray,
    classes: list[int],
) -> tuple[float, dict[str, float]]:
    best_margin = 0.0
    best = _metrics(y, _predict(x, weights, classes, 0.0)[0])
    for margin in np.linspace(0.02, 0.80, 40):
        pred, _scores = _predict(x, weights, classes, float(margin))
        row = _metrics(y, pred)
        if (row["net_gain"], row["model_accuracy"]) > (best["net_gain"], best["model_accuracy"]):
            best_margin = float(margin)
            best = row
    return best_margin, best


def main() -> int:
    ap = argparse.ArgumentParser(description="Train pitch correction baseline.")
    ap.add_argument("--train", type=Path, required=True)
    ap.add_argument("--dev", type=Path, required=True)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--summary-json", type=Path)
    ap.add_argument("--epochs", type=int, default=300)
    ap.add_argument("--lr", type=float, default=0.05)
    ap.add_argument("--l2", type=float, default=0.002)
    ap.add_argument(
        "--classes",
        default=",".join(str(x) for x in DEFAULT_CLASSES),
        help="Comma-separated pitch deltas to train, e.g. -2,-1,0,1,2.",
    )
    args = ap.parse_args()

    classes = [int(x.strip()) for x in args.classes.split(",") if x.strip()]
    if 0 not in classes:
        raise SystemExit("--classes must include 0")
    classes = sorted(set(classes))
    train_x, train_y = _read_csv(args.train, classes)
    dev_x, dev_y = _read_csv(args.dev, classes)
    mean = train_x.mean(axis=0).astype(np.float32)
    std = np.maximum(train_x.std(axis=0), 1e-4).astype(np.float32)
    train_z = (train_x - mean) / std
    dev_z = (dev_x - mean) / std
    weights = _fit_ovr(train_z, train_y, classes, args.epochs, args.lr, args.l2)
    best_margin, summary = _best_margin(dev_y, dev_z, weights, classes)
    summary.update(
        {
            "features": FEATURES,
            "classes": classes,
            "train_rows": int(train_y.size),
            "dev_rows": int(dev_y.size),
            "margin": best_margin,
            "out": str(args.out),
        }
    )
    args.out.parent.mkdir(parents=True, exist_ok=True)
    np.savez_compressed(
        args.out,
        feature_names=np.asarray(FEATURES),
        classes=np.asarray(classes, dtype=np.int32),
        mean=mean,
        std=std,
        weights=weights,
        margin=np.float32(best_margin),
    )
    if args.summary_json is not None:
        args.summary_json.parent.mkdir(parents=True, exist_ok=True)
        args.summary_json.write_text(json.dumps(summary, indent=2), encoding="utf-8")
    print(json.dumps(summary, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
