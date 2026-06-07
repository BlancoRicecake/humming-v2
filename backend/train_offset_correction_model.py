"""Train a conservative note-level offset correction model.

The model predicts reference_end - predicted_end for onset+pitch matched notes.
During evaluation/integration, the predicted delta should be clipped and only
applied when it is large enough to matter.
"""
from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path

import numpy as np


FEATURES = [
    "pred_duration",
    "start_delta",
    "pitch_class",
    "pitch_raw_delta",
    "confidence",
    "voiced_ratio",
    "prev_gap",
    "next_gap",
    "prev_interval",
    "next_interval",
    "is_first",
    "is_last",
    "assisted",
    "source",
    "in_key",
]


def _read_csv(path: Path) -> tuple[np.ndarray, np.ndarray]:
    rows: list[list[float]] = []
    y: list[float] = []
    with path.open(newline="", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            rows.append([float(row[name]) for name in FEATURES])
            y.append(float(row["target_delta"]))
    if not rows:
        raise SystemExit(f"No usable rows in {path}")
    return np.asarray(rows, dtype=np.float32), np.asarray(y, dtype=np.float32)


def _fit_ridge(x: np.ndarray, y: np.ndarray, alpha: float) -> np.ndarray:
    xb = np.concatenate([x, np.ones((x.shape[0], 1), dtype=np.float32)], axis=1)
    reg = np.eye(xb.shape[1], dtype=np.float32) * float(alpha)
    reg[-1, -1] = 0.0
    return np.linalg.solve(xb.T @ xb + reg, xb.T @ y).astype(np.float32)


def _predict(x: np.ndarray, w: np.ndarray) -> np.ndarray:
    xb = np.concatenate([x, np.ones((x.shape[0], 1), dtype=np.float32)], axis=1)
    return xb @ w


def _metrics(y: np.ndarray, pred: np.ndarray, threshold: float, clip: float) -> dict[str, float]:
    applied_delta = np.clip(pred, -clip, clip)
    applied_delta[np.abs(applied_delta) < threshold] = 0.0
    before_ok = np.abs(y) <= 0.18
    after_ok = np.abs(y - applied_delta) <= 0.18
    return {
        "rows": int(y.size),
        "baseline_offset_accuracy": float(np.mean(before_ok)),
        "model_offset_accuracy": float(np.mean(after_ok)),
        "fixed_offsets": int(np.sum(~before_ok & after_ok)),
        "damaged_offsets": int(np.sum(before_ok & ~after_ok)),
        "net_gain": int(np.sum(~before_ok & after_ok) - np.sum(before_ok & ~after_ok)),
        "applied_rate": float(np.mean(applied_delta != 0.0)),
        "threshold": float(threshold),
        "clip": float(clip),
    }


def _best_policy(y: np.ndarray, pred: np.ndarray) -> dict[str, float]:
    best = _metrics(y, pred, threshold=999.0, clip=0.0)
    for threshold in np.linspace(0.02, 0.20, 10):
        for clip in (0.08, 0.12, 0.18, 0.24, 0.32):
            row = _metrics(y, pred, float(threshold), float(clip))
            if (row["net_gain"], row["model_offset_accuracy"]) > (
                best["net_gain"],
                best["model_offset_accuracy"],
            ):
                best = row
    return best


def main() -> int:
    ap = argparse.ArgumentParser(description="Train offset correction ridge baseline.")
    ap.add_argument("--train", type=Path, required=True)
    ap.add_argument("--dev", type=Path, required=True)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--summary-json", type=Path)
    ap.add_argument("--alpha", type=float, default=5.0)
    args = ap.parse_args()

    train_x, train_y = _read_csv(args.train)
    dev_x, dev_y = _read_csv(args.dev)
    mean = train_x.mean(axis=0).astype(np.float32)
    std = np.maximum(train_x.std(axis=0), 1e-4).astype(np.float32)
    train_z = (train_x - mean) / std
    dev_z = (dev_x - mean) / std
    weights = _fit_ridge(train_z, train_y, args.alpha)
    dev_pred = _predict(dev_z, weights)
    summary = _best_policy(dev_y, dev_pred)
    summary.update(
        {
            "features": FEATURES,
            "train_rows": int(train_y.size),
            "dev_rows": int(dev_y.size),
            "alpha": args.alpha,
            "out": str(args.out),
        }
    )
    args.out.parent.mkdir(parents=True, exist_ok=True)
    np.savez_compressed(
        args.out,
        feature_names=np.asarray(FEATURES),
        mean=mean,
        std=std,
        weights=weights,
        threshold=np.float32(summary["threshold"]),
        clip=np.float32(summary["clip"]),
    )
    if args.summary_json is not None:
        args.summary_json.parent.mkdir(parents=True, exist_ok=True)
        args.summary_json.write_text(json.dumps(summary, indent=2), encoding="utf-8")
    print(json.dumps(summary, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
