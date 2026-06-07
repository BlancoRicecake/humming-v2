"""Dump per-class spectral feature distributions from AVP isolated files.

For every ground-truth onset in the isolated AVP files (Kick / Snare / HHclosed /
HHopened), extract the same features ``drums.classify_features`` uses and report
per-class percentiles. This is the calibration table for re-setting the phone /
voice-beatbox thresholds in drums.py (the current ones were tuned on a single
Galaxy S10 take and badly confuse voiced snare with hi-hat).

Onset times come from the labels (not our detector), so the feature clusters are
clean and independent of onset-detection error.

Usage:
  python diag_avp_features.py ../../datasets/AVP_Dataset/AVP_Dataset
"""
from __future__ import annotations

import csv
import glob
import os
import sys
import warnings
from collections import defaultdict

warnings.filterwarnings("ignore")

import numpy as np
import librosa

from app.drums import classify_features

WIN_SEC = 0.045
CLASS_FROM_CODE = {"kd": "kick", "sd": "snare", "hhc": "hihat", "hho": "hihat"}
FEATURES = ("centroid", "rolloff", "zcr", "flatness", "high_ratio")
DEFAULT_AVP_ROOT = "../../datasets/AVP_Dataset/AVP_Dataset"


def is_dataset_file(path: str) -> bool:
    name = os.path.basename(path)
    return "__MACOSX" not in path and not name.startswith("._") and name != ".DS_Store"


def pct(vals: list[float], p: float) -> float:
    return float(np.percentile(vals, p)) if vals else 0.0


def main(root: str) -> None:
    csvs = [p for p in glob.glob(os.path.join(root, "**", "*.csv"), recursive=True)
            if is_dataset_file(p) and "Improvisation" not in os.path.basename(p)]
    by_true: dict[str, dict[str, list[float]]] = defaultdict(lambda: defaultdict(list))
    # also track predicted label to measure isolated-file class accuracy
    confusion: dict[str, dict[str, int]] = defaultdict(lambda: defaultdict(int))

    for cpath in csvs:
        wav = cpath[:-4] + ".wav"
        if not os.path.exists(wav):
            continue
        y, sr = librosa.load(wav, sr=None, mono=True)
        win = int(WIN_SEC * sr)
        with open(cpath, encoding="utf-8", errors="ignore") as f:
            for row in csv.reader(f):
                if len(row) < 2:
                    continue
                try:
                    t = float(row[0])
                except ValueError:
                    continue
                cls = CLASS_FROM_CODE.get(row[1].strip().lower())
                if cls is None:
                    continue
                a = int(round(t * sr))
                seg = y[a:a + win]
                if seg.size < 64:
                    continue
                h = classify_features(seg, sr)
                by_true[cls]["centroid"].append(h.centroid)
                by_true[cls]["rolloff"].append(h.rolloff)
                by_true[cls]["zcr"].append(h.zcr)
                by_true[cls]["flatness"].append(h.flatness)
                by_true[cls]["high_ratio"].append(h.high_ratio)
                confusion[cls][h.name.lower()] += 1

    print(f"files={len(csvs)}  (isolated only)\n")
    print("per-true-class feature percentiles [p10 / p50 / p90]:")
    for cls in ("kick", "snare", "hihat"):
        d = by_true[cls]
        n = len(d["centroid"])
        print(f"\n  {cls.upper()}  (n={n})")
        for feat in FEATURES:
            v = d[feat]
            fmt = (lambda x: f"{x:8.0f}") if feat in ("centroid", "rolloff") else (lambda x: f"{x:.3f}")
            print(f"    {feat:10s}  {fmt(pct(v,10))} / {fmt(pct(v,50))} / {fmt(pct(v,90))}")

    print("\nisolated-file classification confusion (true -> pred), current thresholds:")
    cls_order = ("kick", "snare", "hihat")
    print("           pred:   kick   snare   hihat  | recall")
    for tru in cls_order:
        tot = sum(confusion[tru].values())
        cells = "  ".join(f"{confusion[tru][p]:5d}" for p in cls_order)
        rec = confusion[tru][tru] / tot if tot else 0.0
        print(f"    true {tru:5s}:  {cells}  | {rec:.2f} (n={tot})")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else DEFAULT_AVP_ROOT)
