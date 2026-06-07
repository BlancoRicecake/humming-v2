"""Onset-only recall/precision sweep over AVP improvisation files.

Classification-independent: runs detect_onsets at several `delta` sensitivities,
matches detections to label times within tolerance, and reports onset
precision/recall/F1. This isolates the onset bottleneck (improv onset_f1 ~0.83)
from the classifier.
"""
from __future__ import annotations

import csv
import glob
import os
import sys
import warnings

warnings.filterwarnings("ignore")

import numpy as np
import librosa

from app.drum_onset import detect_onsets

TOL = 0.05
MIN_PEAK_RATIO = 0.12
DEFAULT_AVP_ROOT = "../../datasets/AVP_Dataset/AVP_Dataset"


def is_dataset_file(path: str) -> bool:
    name = os.path.basename(path)
    return "__MACOSX" not in path and not name.startswith("._") and name != ".DS_Store"


def labels(cpath):
    out = []
    with open(cpath, encoding="utf-8", errors="ignore") as f:
        for row in csv.reader(f):
            if len(row) < 2:
                continue
            try:
                out.append(float(row[0]))
            except ValueError:
                pass
    return sorted(out)


def match(ref, pred, tol):
    used = set(); m = 0
    for r in ref:
        best = -1; bd = tol + 1e-9
        for i, p in enumerate(pred):
            if i in used:
                continue
            d = abs(p - r)
            if d <= tol and d < bd:
                best, bd = i, d
        if best >= 0:
            used.add(best); m += 1
    return m


def main(root, configs):
    files = [p for p in glob.glob(os.path.join(root, "**", "*.csv"), recursive=True)
             if is_dataset_file(p) and "Improvisation" in os.path.basename(p)
             and os.path.exists(p[:-4] + ".wav")]
    print(f"{len(files)} improv files\n")
    print(f"{'delta':>6} {'minInt':>7} {'gate':>6} {'precision':>10} {'recall':>8} {'onsetF1':>8}  pred/ref")
    # cache audio once
    cache = {}
    for cpath in files:
        y, sr = librosa.load(cpath[:-4] + ".wav", sr=None, mono=True)
        cache[cpath] = (labels(cpath), y, sr)
    for delta, min_int, gate_ratio in configs:
        tref = tpred = tm = 0
        for cpath in files:
            ref, y, sr = cache[cpath]
            times, _ = detect_onsets(y, sr, delta=delta, min_interval_sec=min_int)
            gate = gate_ratio * (float(np.max(np.abs(y))) if y.size else 1.0)
            win = int(0.045 * sr)
            kept = [float(t) for t in times
                    if y[int(round(t * sr)):int(round(t * sr)) + win].size
                    and float(np.max(np.abs(y[int(round(t * sr)):int(round(t * sr)) + win]))) >= gate]
            tref += len(ref); tpred += len(kept); tm += match(ref, kept, TOL)
        p = tm / tpred if tpred else 0; r = tm / tref if tref else 0
        f1 = 2 * p * r / (p + r) if p + r else 0
        print(f"{delta:6.3f} {min_int:7.3f} {gate_ratio:6.3f} {p:10.3f} {r:8.3f} {f1:8.3f}  {tpred}/{tref}")


if __name__ == "__main__":
    # (delta, min_interval_sec, min_peak_ratio) grid. 0.12 is the current serve
    # gate; lower gates test how much hidden recall exists before false hits win.
    configs = [
        (0.060, 0.080, 0.120),  # current defaults
        (0.045, 0.080, 0.120),
        (0.030, 0.080, 0.120),
        (0.030, 0.050, 0.120),
        (0.030, 0.040, 0.120),
        (0.030, 0.050, 0.100),
        (0.030, 0.050, 0.080),
        (0.020, 0.040, 0.100),
        (0.020, 0.040, 0.080),
        (0.020, 0.030, 0.080),
    ]
    main(sys.argv[1] if len(sys.argv) > 1 else DEFAULT_AVP_ROOT, configs)
