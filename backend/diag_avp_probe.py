"""Probe candidate NEW features for separating voiced snare vs hi-hat.

Current 5 features (centroid/rolloff/zcr/flatness/high_ratio) leave voiced snare
and hi-hat ~70% overlapped. This computes several candidate discriminators at the
ground-truth onsets of AVP isolated files and reports, for each, the per-class
median and a single-threshold separability (max balanced accuracy of snare-vs-hat).
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

WIN_SEC = 0.045
LONG_SEC = 0.120  # longer window to see decay/sustain
CLASS_FROM_CODE = {"kd": "kick", "sd": "snare", "hhc": "hihat", "hho": "hihat"}
DEFAULT_AVP_ROOT = "../../datasets/AVP_Dataset/AVP_Dataset"


def is_dataset_file(path: str) -> bool:
    name = os.path.basename(path)
    return "__MACOSX" not in path and not name.startswith("._") and name != ".DS_Store"


def feats(seg: np.ndarray, seg_long: np.ndarray, sr: int) -> dict[str, float]:
    n = seg.size
    spec = np.abs(np.fft.rfft(seg * np.hanning(n)))
    freqs = np.fft.rfftfreq(n, 1.0 / sr)
    total = float(spec.sum()) + 1e-12

    def band(lo, hi):
        return float(spec[(freqs >= lo) & (freqs < hi)].sum()) / total

    out = {
        "mid_500_3k": band(500, 3000),      # snare body
        "vhigh_8k+": band(8000, sr / 2),    # hi-hat air
        "lowmid_200_2k": band(200, 2000),
        "ratio_mid_vhigh": (band(500, 3000) + 1e-6) / (band(8000, sr / 2) + 1e-6),
    }
    # temporal decay: energy in 2nd half vs 1st half of the LONG window
    half = seg_long.size // 2
    if half > 16:
        e1 = float(np.sqrt(np.mean(seg_long[:half] ** 2))) + 1e-9
        e2 = float(np.sqrt(np.mean(seg_long[half:] ** 2))) + 1e-9
        out["sustain_ratio"] = e2 / e1   # hi-hat sustains (>), snare decays (<)
    else:
        out["sustain_ratio"] = 0.0
    return out


def sep_score(snare: list[float], hat: list[float]) -> tuple[float, float]:
    """Best single-threshold balanced accuracy separating snare from hat."""
    vals = sorted(set(snare + hat))
    best_acc, best_t = 0.0, 0.0
    s = np.array(snare); h = np.array(hat)
    for t in vals:
        # assume snare < t, hat >= t  (and the reverse)
        for sign in (1, -1):
            if sign == 1:
                acc = (np.mean(s < t) + np.mean(h >= t)) / 2
            else:
                acc = (np.mean(s >= t) + np.mean(h < t)) / 2
            if acc > best_acc:
                best_acc, best_t = acc, t
    return best_acc, best_t


def main(root: str) -> None:
    csvs = [p for p in glob.glob(os.path.join(root, "**", "*.csv"), recursive=True)
            if is_dataset_file(p) and "Improvisation" not in os.path.basename(p)]
    by: dict[str, dict[str, list[float]]] = defaultdict(lambda: defaultdict(list))
    for cpath in csvs:
        wav = cpath[:-4] + ".wav"
        if not os.path.exists(wav):
            continue
        y, sr = librosa.load(wav, sr=None, mono=True)
        win = int(WIN_SEC * sr); winL = int(LONG_SEC * sr)
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
                seg = y[a:a + win]; segL = y[a:a + winL]
                if seg.size < 64:
                    continue
                for k, v in feats(seg, segL, sr).items():
                    by[cls][k].append(v)

    names = list(next(iter(by.values())).keys())
    print(f"{'feature':16s} {'kick_med':>9s} {'snare_med':>9s} {'hat_med':>9s}   snare-vs-hat[balAcc@thr]")
    for name in names:
        km = np.median(by["kick"][name]); sm = np.median(by["snare"][name]); hm = np.median(by["hihat"][name])
        acc, thr = sep_score(by["snare"][name], by["hihat"][name])
        print(f"{name:16s} {km:9.3f} {sm:9.3f} {hm:9.3f}   {acc:.3f} @ {thr:.3f}")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else DEFAULT_AVP_ROOT)
