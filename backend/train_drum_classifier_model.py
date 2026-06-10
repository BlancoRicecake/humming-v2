"""Train a small local drum-voice classifier (kick / snare / hihat) from AVP.

Supports a tiny one-vs-rest logistic model and a random-forest model exported to
pure numpy arrays for runtime serving. The goal is to break the voiced
snare/hi-hat overlap that hand-tuned spectral thresholds cap at ~0.70 (see
docs/experiments/drum_pipeline_90_plan.md).

Features come from app.drum_features.extract (shared with inference so train and
serve never drift). Onsets are the AVP ground-truth labels, so the feature
clusters are clean. Split is BY PARTICIPANT so the reported accuracy is
speaker-held-out (honest generalization, not memorized voices).

Usage:
  python train_drum_classifier_model.py --root ../../datasets/AVP_Dataset/AVP_Dataset \
      --out models/drum_classifier_v2.npz --model rf --feature-set v2 --holdout-mod 4
"""
from __future__ import annotations

import argparse
import csv
import json
import os
import re
import warnings
from pathlib import Path

warnings.filterwarnings("ignore")

import numpy as np
import librosa

from app.drum_features import extract, extract_v2, feature_names
from app.drum_onset import detect_onsets

CLASS_FROM_CODE = {"kd": 0, "sd": 1, "hhc": 2, "hho": 2}  # kick / snare / hihat
CLASSES = [36, 38, 42]  # GM notes, index-aligned to the 0/1/2 labels above
WIN_SEC = 0.045
LONG_SEC = 0.120
MATCH_TOL = 0.05   # match a detected onset to a label within ±50 ms
MIN_PEAK_RATIO = 0.12  # same amplitude gate as build_drum_notes
DEFAULT_AVP_ROOT = "../../datasets/AVP_Dataset/AVP_Dataset"


def _participant(path: str) -> int:
    m = re.search(r"Participant_(\d+)", path)
    return int(m.group(1)) if m else -1


def _sigmoid(z: np.ndarray) -> np.ndarray:
    return 1.0 / (1.0 + np.exp(-np.clip(z, -40.0, 40.0)))


def _read_labels(cpath: str) -> list[tuple[float, int]]:
    out: list[tuple[float, int]] = []
    with open(cpath, encoding="utf-8", errors="ignore") as f:
        for row in csv.reader(f):
            if len(row) < 2:
                continue
            try:
                t = float(row[0])
            except ValueError:
                continue
            lab = CLASS_FROM_CODE.get(row[1].strip().lower())
            if lab is not None:
                out.append((t, lab))
    out.sort()
    return out


def _is_ignored_dataset_path(path: Path) -> bool:
    return (
        any(part == "__MACOSX" for part in path.parts)
        or path.name.startswith("._")
        or path.name == ".DS_Store"
    )


def _csv_files(root: str) -> list[str]:
    return [
        str(p)
        for p in sorted(Path(root).rglob("*.csv"))
        if not _is_ignored_dataset_path(p)
    ]


def _collect(root: str, use_detected: bool, include_improv: bool, feature_set: str
             ) -> tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray]:
    """Return (X, y 0/1/2, participant ids, is_improv).

    ``use_detected`` harvests windows at the ONSET-DETECTOR's onsets (matched to
    the nearest label within ``MATCH_TOL``) so the training distribution equals
    the serve distribution — this is the fix for the v1 train/serve shift. With
    ``use_detected=False`` it falls back to ground-truth onsets (the v1 recipe).
    """
    csvs = _csv_files(root)
    X: list[list[float]] = []
    y: list[int] = []
    pid: list[int] = []
    imp: list[int] = []
    extract_fn = extract_v2 if feature_set == "v2" else extract
    for cpath in csvs:
        is_improv = "Improvisation" in os.path.basename(cpath)
        if is_improv and not include_improv:
            continue
        wav = cpath[:-4] + ".wav"
        if not os.path.exists(wav):
            continue
        labels = _read_labels(cpath)
        if not labels:
            continue
        part = _participant(cpath)
        sig, sr = librosa.load(wav, sr=None, mono=True)
        win = int(WIN_SEC * sr)
        winl = int(LONG_SEC * sr)

        if use_detected:
            det_times, _ = detect_onsets(sig, sr)
            gate = MIN_PEAK_RATIO * (float(np.max(np.abs(sig))) if sig.size else 1.0)
            lab_t = np.array([t for t, _ in labels])
            lab_c = [c for _, c in labels]
            used = set()
            pairs: list[tuple[float, int]] = []
            for dt in det_times:
                a = int(round(float(dt) * sr))
                seg_peak = sig[a:a + win]
                if seg_peak.size == 0 or float(np.max(np.abs(seg_peak))) < gate:
                    continue
                j = int(np.argmin(np.abs(lab_t - dt)))
                if abs(lab_t[j] - dt) <= MATCH_TOL and j not in used:
                    used.add(j)
                    pairs.append((float(dt), lab_c[j]))  # window at DETECTED time, label from GT
            onset_list = pairs
        else:
            onset_list = labels

        for t, lab in onset_list:
            a = int(round(t * sr))
            seg = sig[a:a + win]
            segl = sig[a:a + winl]
            if seg.size < 64:
                continue
            X.append(extract_fn(seg, segl, sr))
            y.append(lab)
            pid.append(part)
            imp.append(int(is_improv))
    return (np.asarray(X, dtype=np.float32),
            np.asarray(y, dtype=np.int32),
            np.asarray(pid, dtype=np.int32),
            np.asarray(imp, dtype=np.int32))


def _fit_ovr(x: np.ndarray, y: np.ndarray, n_cls: int, epochs: int, lr: float, l2: float) -> np.ndarray:
    xb = np.concatenate([x, np.ones((x.shape[0], 1), dtype=np.float32)], axis=1)
    weights = np.zeros((n_cls, xb.shape[1]), dtype=np.float32)
    for ci in range(n_cls):
        target = (y == ci).astype(np.float32)
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


def _predict(x: np.ndarray, mean, std, weights) -> np.ndarray:
    z = (x - mean) / std
    xb = np.concatenate([z, np.ones((z.shape[0], 1), dtype=np.float32)], axis=1)
    scores = _sigmoid(xb @ weights.T)
    return np.argmax(scores, axis=1)


def _fit_rf(x: np.ndarray, y: np.ndarray, n: int, depth: int, leaf: int):
    """Train a RandomForest (sklearn, dev-only). Exported to pure numpy for serve."""
    from sklearn.ensemble import RandomForestClassifier
    rf = RandomForestClassifier(
        n_estimators=n, max_depth=depth, min_samples_leaf=leaf,
        class_weight="balanced", n_jobs=-1, random_state=0,
    )
    rf.fit(x, y)
    return rf


def _export_rf(rf) -> dict:
    """Serialize each tree's arrays + leaf class-probabilities (label order 0/1/2)."""
    order = list(rf.classes_)  # maps tree value columns -> our 0/1/2 labels
    perm = [order.index(c) for c in (0, 1, 2)]
    cl, cr, feat, thr, val = [], [], [], [], []
    for est in rf.estimators_:
        t = est.tree_
        cl.append(t.children_left.astype(np.int32))
        cr.append(t.children_right.astype(np.int32))
        feat.append(t.feature.astype(np.int32))
        thr.append(t.threshold.astype(np.float32))
        v = t.value[:, 0, :]                      # (n_nodes, n_classes) counts
        v = v[:, perm]                            # reorder to 0/1/2
        v = v / np.maximum(v.sum(1, keepdims=True), 1e-9)
        val.append(v.astype(np.float32))
    obj = lambda a: np.array(a, dtype=object)
    return {"rf_cl": obj(cl), "rf_cr": obj(cr), "rf_feat": obj(feat),
            "rf_thr": obj(thr), "rf_val": obj(val)}


def _predict_rf(rf, x: np.ndarray) -> np.ndarray:
    return np.array([list(rf.classes_)[i] for i in rf.predict(x).astype(int)]) \
        if False else rf.predict(x).astype(int)


def _confusion(y: np.ndarray, pred: np.ndarray) -> str:
    names = ["kick", "snare", "hihat"]
    lines = ["           pred:   kick   snare   hihat  | recall"]
    for t in range(3):
        row = [int(np.sum((y == t) & (pred == p))) for p in range(3)]
        tot = sum(row)
        rec = row[t] / tot if tot else 0.0
        lines.append(f"    true {names[t]:5s}:  " + "  ".join(f"{c:5d}" for c in row) + f"  | {rec:.2f} (n={tot})")
    return "\n".join(lines)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=DEFAULT_AVP_ROOT)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--summary-json", type=Path)
    ap.add_argument("--holdout-mod", type=int, default=4,
                    help="Hold out participants where (pid %% mod)==0 for the honest score.")
    ap.add_argument("--epochs", type=int, default=400)
    ap.add_argument("--lr", type=float, default=0.1)
    ap.add_argument("--l2", type=float, default=0.001)
    ap.add_argument("--ground-truth-onsets", action="store_true",
                    help="Train on label onsets (v1 recipe) instead of detected onsets.")
    ap.add_argument("--no-improv", action="store_true",
                    help="Exclude Improvisation files from training data.")
    ap.add_argument("--model", choices=("logistic", "rf"), default="logistic",
                    help="logistic (linear, tiny) or rf (RandomForest, +0.04 acc, larger).")
    ap.add_argument("--feature-set", choices=("v1", "v2"), default="v2",
                    help="v1 keeps the shipped 10-feature contract; v2 adds AVP-oriented band/decay features.")
    ap.add_argument("--rf-trees", type=int, default=200)
    ap.add_argument("--rf-depth", type=int, default=12)
    ap.add_argument("--rf-leaf", type=int, default=5)
    args = ap.parse_args()

    use_detected = not args.ground_truth_onsets
    X, y, pid, imp = _collect(args.root, use_detected, include_improv=not args.no_improv,
                              feature_set=args.feature_set)
    print(f"collected {X.shape[0]} onsets ({'DETECTED' if use_detected else 'ground-truth'}), "
          f"{X.shape[1]} features, {len(set(pid.tolist()))} participants, "
          f"improv={int(imp.sum())} isolated={int((1 - imp).sum())}, model={args.model}")

    is_holdout = (pid % args.holdout_mod) == 0
    tr, te = ~is_holdout, is_holdout

    # --- held-out (speaker-disjoint) measurement on the chosen model ---
    if args.model == "rf":
        rf = _fit_rf(X[tr], y[tr], args.rf_trees, args.rf_depth, args.rf_leaf)
        pred_fn = lambda mask: _predict_rf(rf, X[mask])
    else:
        mean = X[tr].mean(axis=0).astype(np.float32)
        std = np.maximum(X[tr].std(axis=0), 1e-4).astype(np.float32)
        weights = _fit_ovr((X[tr] - mean) / std, y[tr], 3, args.epochs, args.lr, args.l2)
        pred_fn = lambda mask: _predict(X[mask], mean, std, weights)

    acc = float(np.mean(pred_fn(te) == y[te])) if te.any() else 0.0
    print(f"\nSPEAKER-HELD-OUT classification accuracy: {acc:.3f}  (n={int(te.sum())})")
    print(_confusion(y[te], pred_fn(te)))
    te_imp = te & (imp == 1)
    if te_imp.any():
        print(f"\n  held-out IMPROV-only accuracy: {float(np.mean(pred_fn(te_imp) == y[te_imp])):.3f}  (n={int(te_imp.sum())})")
        print(_confusion(y[te_imp], pred_fn(te_imp)))

    # --- retrain on ALL data and save the shipped model ---
    args.out.parent.mkdir(parents=True, exist_ok=True)
    names = feature_names(args.feature_set)
    base = dict(feature_names=np.asarray(names),
                classes=np.asarray(CLASSES, dtype=np.int32))
    if args.model == "rf":
        rf_all = _fit_rf(X, y, args.rf_trees, args.rf_depth, args.rf_leaf)
        nodes = sum(e.tree_.node_count for e in rf_all.estimators_)
        print(f"\nRF total nodes: {nodes} ({args.rf_trees} trees)")
        np.savez_compressed(args.out, model_type=np.asarray("rf"), **base, **_export_rf(rf_all))
    else:
        mean_all = X.mean(axis=0).astype(np.float32)
        std_all = np.maximum(X.std(axis=0), 1e-4).astype(np.float32)
        weights_all = _fit_ovr((X - mean_all) / std_all, y, 3, args.epochs, args.lr, args.l2)
        np.savez_compressed(args.out, model_type=np.asarray("logistic"), **base,
                            mean=mean_all, std=std_all, weights=weights_all)
    summary = {
        "model": args.model,
        "feature_set": args.feature_set,
        "held_out_accuracy": acc,
        "held_out_n": int(te.sum()),
        "train_n": int(tr.sum()),
        "features": names,
        "out": str(args.out),
    }
    if args.summary_json:
        args.summary_json.write_text(json.dumps(summary, indent=2), encoding="utf-8")
    print(f"\nsaved {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
