"""Train the note-sequence selector: a per-candidate keep-score logistic model.

Mirrors train_split_candidate_model.py conventions (standardize -> weighted
logistic -> npz with feature_names/mean/std/weights/threshold). The score feeds
a non-overlap DP at inference (app/sequence_select via eval_sequence_selector).
"""
from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path

import numpy as np

from seq_candidates import FEATURES


def _sigmoid(z: np.ndarray) -> np.ndarray:
    return 1.0 / (1.0 + np.exp(-np.clip(z, -40.0, 40.0)))


def _read(path: Path) -> tuple[np.ndarray, np.ndarray]:
    rows: list[list[float]] = []
    y: list[int] = []
    with path.open(newline="", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            rows.append([float(row[name]) for name in FEATURES])
            y.append(int(row["label"]))
    if not rows:
        raise SystemExit(f"No rows in {path}")
    return np.asarray(rows, dtype=np.float32), np.asarray(y, dtype=np.float32)


def _fit(x: np.ndarray, y: np.ndarray, epochs: int, lr: float, l2: float) -> np.ndarray:
    xb = np.concatenate([x, np.ones((x.shape[0], 1), dtype=np.float32)], axis=1)
    w = np.zeros(xb.shape[1], dtype=np.float32)
    pos = float(np.sum(y))
    neg = float(y.size - pos)
    pos_weight = min(40.0, neg / max(pos, 1.0))
    step = lr
    for epoch in range(epochs):
        pred = _sigmoid(xb @ w)
        sw = np.where(y > 0.5, pos_weight, 1.0).astype(np.float32)
        grad = (xb.T @ ((pred - y) * sw)) / max(1, y.size)
        grad[:-1] += l2 * w[:-1]
        w -= step * grad.astype(np.float32)
        if epoch and epoch % 80 == 0:
            step *= 0.75
    return w


def _predict(x: np.ndarray, w: np.ndarray) -> np.ndarray:
    xb = np.concatenate([x, np.ones((x.shape[0], 1), dtype=np.float32)], axis=1)
    return _sigmoid(xb @ w)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--train", type=Path, required=True)
    ap.add_argument("--dev", type=Path)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--summary-json", type=Path)
    ap.add_argument("--epochs", type=int, default=300)
    ap.add_argument("--lr", type=float, default=0.08)
    ap.add_argument("--l2", type=float, default=0.002)
    args = ap.parse_args()

    tx, ty = _read(args.train)
    mean = tx.mean(axis=0).astype(np.float32)
    std = np.maximum(tx.std(axis=0), 1e-4).astype(np.float32)
    w = _fit((tx - mean) / std, ty, args.epochs, args.lr, args.l2)

    summary = {"features": FEATURES, "train_rows": int(ty.size),
               "train_pos_rate": float(ty.mean())}
    if args.dev and args.dev.exists():
        dx, dy = _read(args.dev)
        p = _predict((dx - mean) / std, w)
        # row-level AUC-ish + best-F1 threshold
        best = {"f1": 0.0, "threshold": 0.5}
        for t in np.linspace(0.1, 0.9, 33):
            pred = p >= t
            tp = float(np.sum(pred & (dy > 0.5)))
            fp = float(np.sum(pred & (dy <= 0.5)))
            fn = float(np.sum(~pred & (dy > 0.5)))
            prec = tp / (tp + fp) if tp + fp else 0.0
            rec = tp / (tp + fn) if tp + fn else 0.0
            f1 = 2 * prec * rec / (prec + rec) if prec + rec else 0.0
            if f1 > best["f1"]:
                best = {"f1": float(f1), "threshold": float(t),
                        "precision": float(prec), "recall": float(rec)}
        summary["dev_rows"] = int(dy.size)
        summary["dev_pos_rate"] = float(dy.mean())
        summary["dev_best_row"] = best

    args.out.parent.mkdir(parents=True, exist_ok=True)
    np.savez_compressed(
        args.out,
        feature_names=np.asarray(FEATURES),
        mean=mean, std=std, weights=w,
        threshold=np.float32(summary.get("dev_best_row", {}).get("threshold", 0.5)),
    )
    if args.summary_json:
        args.summary_json.write_text(json.dumps(summary, indent=2), encoding="utf-8")
    print(json.dumps(summary, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
