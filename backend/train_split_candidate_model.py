"""Train a split-candidate classifier for hidden note boundaries."""
from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path

import numpy as np


FEATURES = [
    "note_duration",
    "pos_ratio",
    "time_from_start",
    "time_to_end",
    "note_pitch",
    "note_confidence",
    "note_voiced_ratio",
    "rms_here",
    "rms_min_ratio",
    "rms_left",
    "rms_right",
    "onset_here",
    "pitch_left",
    "pitch_right",
    "pitch_delta_lr",
    "pitch_abs_delta_lr",
    "pitch_std_left",
    "pitch_std_right",
    "voiced_left",
    "voiced_right",
    "voiced_delta",
    "same_rounded_pitch",
]


def _sigmoid(z: np.ndarray) -> np.ndarray:
    return 1.0 / (1.0 + np.exp(-np.clip(z, -40.0, 40.0)))


def _read_csv(path: Path) -> tuple[np.ndarray, np.ndarray, list[str]]:
    rows: list[list[float]] = []
    y: list[int] = []
    groups: list[str] = []
    with path.open(newline="", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            rows.append([float(row[name]) for name in FEATURES])
            y.append(int(row["label"]))
            groups.append(f"{row['key']}::{row['note_index']}")
    if not rows:
        raise SystemExit(f"No rows in {path}")
    return np.asarray(rows, dtype=np.float32), np.asarray(y, dtype=np.float32), groups


def _fit(x: np.ndarray, y: np.ndarray, epochs: int, lr: float, l2: float) -> np.ndarray:
    xb = np.concatenate([x, np.ones((x.shape[0], 1), dtype=np.float32)], axis=1)
    w = np.zeros(xb.shape[1], dtype=np.float32)
    pos = float(np.sum(y))
    neg = float(y.size - pos)
    pos_weight = min(80.0, neg / max(pos, 1.0))
    step = lr
    for epoch in range(epochs):
        pred = _sigmoid(xb @ w)
        sample_w = np.where(y > 0.5, pos_weight, 1.0).astype(np.float32)
        grad = (xb.T @ ((pred - y) * sample_w)) / max(1, y.size)
        grad[:-1] += l2 * w[:-1]
        w -= step * grad.astype(np.float32)
        if epoch and epoch % 80 == 0:
            step *= 0.75
    return w


def _predict(x: np.ndarray, w: np.ndarray) -> np.ndarray:
    xb = np.concatenate([x, np.ones((x.shape[0], 1), dtype=np.float32)], axis=1)
    return _sigmoid(xb @ w)


def _metrics(y: np.ndarray, p: np.ndarray, threshold: float) -> dict[str, float]:
    pred = p >= threshold
    truth = y > 0.5
    tp = float(np.sum(pred & truth))
    fp = float(np.sum(pred & ~truth))
    fn = float(np.sum(~pred & truth))
    precision = tp / (tp + fp) if tp + fp else 0.0
    recall = tp / (tp + fn) if tp + fn else 0.0
    f1 = 2.0 * precision * recall / (precision + recall) if precision + recall else 0.0
    return {
        "threshold": float(threshold),
        "precision": precision,
        "recall": recall,
        "f1": f1,
        "tp": int(tp),
        "fp": int(fp),
        "fn": int(fn),
        "positive_rate": float(np.mean(pred)),
    }


def _best_threshold(y: np.ndarray, p: np.ndarray) -> dict[str, float]:
    best = _metrics(y, p, 0.5)
    for threshold in np.linspace(0.05, 0.95, 37):
        row = _metrics(y, p, float(threshold))
        if (row["f1"], row["precision"]) > (best["f1"], best["precision"]):
            best = row
    return best


def _group_metrics(y: np.ndarray, p: np.ndarray, groups: list[str], threshold: float) -> dict[str, float]:
    by_group: dict[str, list[int]] = {}
    for i, g in enumerate(groups):
        by_group.setdefault(g, []).append(i)
    split_groups = 0
    predicted_groups = 0
    hit_groups = 0
    false_groups = 0
    for idxs in by_group.values():
        idx = np.asarray(idxs, dtype=np.int32)
        labels = y[idx] > 0.5
        has_split = bool(np.any(labels))
        if has_split:
            split_groups += 1
        best_local = int(idx[int(np.argmax(p[idx]))])
        if float(p[best_local]) < threshold:
            continue
        predicted_groups += 1
        if has_split and y[best_local] > 0.5:
            hit_groups += 1
        else:
            false_groups += 1
    precision = hit_groups / predicted_groups if predicted_groups else 0.0
    recall = hit_groups / split_groups if split_groups else 0.0
    f1 = 2.0 * precision * recall / (precision + recall) if precision + recall else 0.0
    return {
        "threshold": float(threshold),
        "split_groups": split_groups,
        "predicted_groups": predicted_groups,
        "hit_groups": hit_groups,
        "false_groups": false_groups,
        "precision": precision,
        "recall": recall,
        "f1": f1,
    }


def _best_group_threshold(y: np.ndarray, p: np.ndarray, groups: list[str]) -> dict[str, float]:
    best = _group_metrics(y, p, groups, 0.5)
    for threshold in np.linspace(0.05, 0.95, 37):
        row = _group_metrics(y, p, groups, float(threshold))
        if (row["f1"], row["precision"]) > (best["f1"], best["precision"]):
            best = row
    return best


def main() -> int:
    ap = argparse.ArgumentParser(description="Train split-candidate logistic model.")
    ap.add_argument("--train", type=Path, required=True)
    ap.add_argument("--dev", type=Path, required=True)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--summary-json", type=Path)
    ap.add_argument("--epochs", type=int, default=260)
    ap.add_argument("--lr", type=float, default=0.05)
    ap.add_argument("--l2", type=float, default=0.002)
    args = ap.parse_args()

    train_x, train_y, _train_groups = _read_csv(args.train)
    dev_x, dev_y, dev_groups = _read_csv(args.dev)
    mean = train_x.mean(axis=0).astype(np.float32)
    std = np.maximum(train_x.std(axis=0), 1e-4).astype(np.float32)
    train_z = (train_x - mean) / std
    dev_z = (dev_x - mean) / std
    weights = _fit(train_z, train_y, args.epochs, args.lr, args.l2)
    prob = _predict(dev_z, weights)
    best = _best_threshold(dev_y, prob)
    best_group = _best_group_threshold(dev_y, prob, dev_groups)
    summary = {
        "train": str(args.train),
        "dev": str(args.dev),
        "out": str(args.out),
        "features": FEATURES,
        "train_rows": int(train_y.size),
        "train_positive_rate": float(np.mean(train_y)),
        "dev_rows": int(dev_y.size),
        "dev_positive_rate": float(np.mean(dev_y)),
        "best": best,
        "best_group": best_group,
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    np.savez_compressed(
        args.out,
        feature_names=np.asarray(FEATURES),
        mean=mean,
        std=std,
        weights=weights,
        threshold=np.float32(best_group["threshold"]),
        row_threshold=np.float32(best["threshold"]),
    )
    if args.summary_json is not None:
        args.summary_json.parent.mkdir(parents=True, exist_ok=True)
        args.summary_json.write_text(json.dumps(summary, indent=2), encoding="utf-8")
    print(json.dumps(summary, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
