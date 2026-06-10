"""Train a simple onset/offset boundary model from HumTrans NPZ features.

This is a deliberately dependency-light baseline: two weighted logistic
regression heads trained with NumPy. It gives us a reproducible learned
boundary baseline before wiring a larger model into the live analyzer.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np


def _sigmoid(z: np.ndarray) -> np.ndarray:
    return 1.0 / (1.0 + np.exp(-np.clip(z, -40.0, 40.0)))


def _load(path: Path) -> tuple[np.ndarray, np.ndarray, np.ndarray, list[str]]:
    data = np.load(path, allow_pickle=True)
    x = data["x"].astype(np.float32)
    onset_y = data["onset_y"].astype(np.float32)
    offset_y = data["offset_y"].astype(np.float32)
    names = [str(v) for v in data["feature_names"]]
    return x, onset_y, offset_y, names


def _fit_head(
    x: np.ndarray,
    y: np.ndarray,
    *,
    epochs: int,
    batch_size: int,
    lr: float,
    l2: float,
    seed: int,
) -> np.ndarray:
    rng = np.random.default_rng(seed)
    xb = np.concatenate([x, np.ones((x.shape[0], 1), dtype=np.float32)], axis=1)
    w = np.zeros(xb.shape[1], dtype=np.float32)
    pos = float(np.sum(y))
    neg = float(y.size - pos)
    pos_weight = min(50.0, neg / max(pos, 1.0))

    for epoch in range(epochs):
        order = rng.permutation(xb.shape[0])
        for start in range(0, xb.shape[0], batch_size):
            idx = order[start : start + batch_size]
            bx = xb[idx]
            by = y[idx]
            pred = _sigmoid(bx @ w)
            weight = np.where(by > 0.5, pos_weight, 1.0).astype(np.float32)
            grad = (bx.T @ ((pred - by) * weight)) / max(1, idx.size)
            grad[:-1] += l2 * w[:-1]
            w -= lr * grad.astype(np.float32)
        if epoch and epoch % 20 == 0:
            lr *= 0.75
    return w


def _predict(x: np.ndarray, w: np.ndarray) -> np.ndarray:
    xb = np.concatenate([x, np.ones((x.shape[0], 1), dtype=np.float32)], axis=1)
    return _sigmoid(xb @ w)


def _metrics(y: np.ndarray, prob: np.ndarray, threshold: float) -> dict[str, float]:
    pred = prob >= threshold
    truth = y > 0.5
    tp = float(np.sum(pred & truth))
    fp = float(np.sum(pred & ~truth))
    fn = float(np.sum(~pred & truth))
    precision = tp / (tp + fp) if tp + fp else 0.0
    recall = tp / (tp + fn) if tp + fn else 0.0
    f1 = 2.0 * precision * recall / (precision + recall) if precision + recall else 0.0
    return {"precision": precision, "recall": recall, "f1": f1, "threshold": threshold}


def _best_threshold(y: np.ndarray, prob: np.ndarray) -> dict[str, float]:
    best = {"precision": 0.0, "recall": 0.0, "f1": 0.0, "threshold": 0.5}
    for threshold in np.linspace(0.05, 0.95, 37):
        row = _metrics(y, prob, float(threshold))
        if row["f1"] > best["f1"]:
            best = row
    return best


def main() -> int:
    ap = argparse.ArgumentParser(description="Train HumTrans boundary logistic baseline.")
    ap.add_argument("--train", type=Path, required=True)
    ap.add_argument("--dev", type=Path, required=True)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--summary-json", type=Path)
    ap.add_argument("--epochs", type=int, default=120)
    ap.add_argument("--batch-size", type=int, default=4096)
    ap.add_argument("--lr", type=float, default=0.08)
    ap.add_argument("--l2", type=float, default=0.001)
    ap.add_argument("--seed", type=int, default=20260605)
    args = ap.parse_args()

    train_x, train_onset, train_offset, names = _load(args.train)
    dev_x, dev_onset, dev_offset, dev_names = _load(args.dev)
    if dev_names != names:
        raise SystemExit("Train/dev feature names differ.")

    mean = train_x.mean(axis=0).astype(np.float32)
    std = np.maximum(train_x.std(axis=0), 1e-4).astype(np.float32)
    train_z = (train_x - mean) / std
    dev_z = (dev_x - mean) / std

    onset_w = _fit_head(
        train_z,
        train_onset,
        epochs=args.epochs,
        batch_size=args.batch_size,
        lr=args.lr,
        l2=args.l2,
        seed=args.seed,
    )
    offset_w = _fit_head(
        train_z,
        train_offset,
        epochs=args.epochs,
        batch_size=args.batch_size,
        lr=args.lr,
        l2=args.l2,
        seed=args.seed + 17,
    )

    onset_prob = _predict(dev_z, onset_w)
    offset_prob = _predict(dev_z, offset_w)
    onset_best = _best_threshold(dev_onset, onset_prob)
    offset_best = _best_threshold(dev_offset, offset_prob)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    np.savez_compressed(
        args.out,
        feature_names=np.asarray(names),
        mean=mean,
        std=std,
        onset_w=onset_w,
        offset_w=offset_w,
        onset_threshold=np.float32(onset_best["threshold"]),
        offset_threshold=np.float32(offset_best["threshold"]),
    )
    summary = {
        "train": str(args.train),
        "dev": str(args.dev),
        "out": str(args.out),
        "features": names,
        "train_frames": int(train_x.shape[0]),
        "dev_frames": int(dev_x.shape[0]),
        "onset": onset_best,
        "offset": offset_best,
    }
    if args.summary_json is not None:
        args.summary_json.parent.mkdir(parents=True, exist_ok=True)
        args.summary_json.write_text(json.dumps(summary, indent=2), encoding="utf-8")
    print(json.dumps(summary, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
