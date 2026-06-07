"""Per-user enrollment experiment — does 'record your own kick/snare/hat' work,
how many examples are needed, and is a shippable pure-numpy method competitive?

For each AVP participant we simulate enrollment: take the FIRST k labelled hits of
each class from their ISOLATED files, then classify their IMPROVISATION onsets
(detected + matched). Strategies:

  proto   — per-user nearest-prototype in the user's own z-scored feature space
            (pure numpy, trivially shippable, no per-user training)
  gbt     — per-user GBT trained on the k enrolled examples (sklearn; upper bound)
  hybrid  — GBT pre-trained on ALL OTHER participants, with the user's k examples
            ADDED (transfer + personalization)

Features are harvested once via the real onset detector and cached to npz.
"""
from __future__ import annotations

import csv
import glob
import os
import re
import sys
import warnings
from collections import defaultdict

warnings.filterwarnings("ignore")

import numpy as np
import librosa
from sklearn.ensemble import HistGradientBoostingClassifier

from app.drum_features import extract, FEATURE_NAMES
from app.drum_onset import detect_onsets

CODE = {"kd": 0, "sd": 1, "hhc": 2, "hho": 2}
TOL = 0.05
GATE = 0.12
CACHE = "../docs/experiments/_enroll_cache.npz"
DEFAULT_AVP_ROOT = "../../datasets/AVP_Dataset/AVP_Dataset"


def is_dataset_file(path):
    name = os.path.basename(path)
    return "__MACOSX" not in path and not name.startswith("._") and name != ".DS_Store"


def participant(p):
    m = re.search(r"Participant_(\d+)", p)
    return int(m.group(1)) if m else -1


def harvest_file(cpath):
    wav = cpath[:-4] + ".wav"
    if not os.path.exists(wav):
        return []
    labs = []
    for row in csv.reader(open(cpath, encoding="utf-8", errors="ignore")):
        if len(row) >= 2:
            c = CODE.get(row[1].strip().lower())
            if c is not None:
                try:
                    labs.append((float(row[0]), c))
                except ValueError:
                    pass
    if not labs:
        return []
    y, sr = librosa.load(wav, sr=None, mono=True)
    times, _ = detect_onsets(y, sr)
    win = int(0.045 * sr); winl = int(0.120 * sr)
    gate = GATE * (float(np.max(np.abs(y))) if y.size else 1.0)
    lt = np.array([t for t, _ in labs]); lc = [c for _, c in labs]; used = set()
    out = []
    for dt in times:
        a = int(round(float(dt) * sr)); seg = y[a:a + win]
        if seg.size == 0 or float(np.max(np.abs(seg))) < gate:
            continue
        j = int(np.argmin(np.abs(lt - dt)))
        if abs(lt[j] - dt) <= TOL and j not in used:
            used.add(j)
            out.append((extract(seg, y[a:a + winl], sr), lc[j], int("Improvisation" in os.path.basename(cpath))))
    return out


def load(root):
    root_id = os.path.abspath(root)
    if os.path.exists(CACHE):
        with np.load(CACHE) as d:
            if "root" in d and str(d["root"]) == root_id:
                return d["X"], d["y"], d["pid"], d["imp"]
    X, y, pid, imp = [], [], [], []
    for cpath in sorted(glob.glob(os.path.join(root, "**", "*.csv"), recursive=True)):
        if not is_dataset_file(cpath):
            continue
        p = participant(cpath)
        for f, l, im in harvest_file(cpath):
            X.append(f); y.append(l); pid.append(p); imp.append(im)
    X = np.array(X, dtype=np.float32); y = np.array(y); pid = np.array(pid); imp = np.array(imp)
    np.savez(CACHE, X=X, y=y, pid=pid, imp=imp, root=np.array(root_id))
    return X, y, pid, imp


def enroll_idx(yi, k, rng_seed):
    """First k indices of each class (deterministic — simulates an enrollment UI)."""
    idx = []
    for c in (0, 1, 2):
        ci = np.where(yi == c)[0]
        idx.extend(ci[:k].tolist())
    return np.array(idx, dtype=int)


def proto_predict(Xtr, ytr, Xte):
    mu = Xtr.mean(0); sd = np.maximum(Xtr.std(0), 1e-4)
    ztr = (Xtr - mu) / sd; zte = (Xte - mu) / sd
    cents = {c: ztr[ytr == c].mean(0) for c in (0, 1, 2) if (ytr == c).any()}
    cl = list(cents); C = np.stack([cents[c] for c in cl])
    d = ((zte[:, None, :] - C[None]) ** 2).sum(-1)
    return np.array([cl[i] for i in d.argmin(1)])


def main(root, ks):
    X, y, pid, imp = load(root)
    pids = sorted(set(pid.tolist()))
    print(f"harvested {len(X)} onsets, {len(pids)} participants "
          f"(improv={int(imp.sum())}, isolated={int((imp == 0).sum())})\n")
    print(f"{'k/class':>8} {'proto':>8} {'gbt':>8} {'hybrid':>8}")
    for k in ks:
        ps, gs, hs = [], [], []
        for p in pids:
            iso = (pid == p) & (imp == 0)
            tst = (pid == p) & (imp == 1)
            if not tst.any() or not iso.any():
                continue
            Xi, yi = X[iso], y[iso]
            ei = enroll_idx(yi, k, p)
            if len(set(yi[ei].tolist())) < 2:
                continue
            Xe, ye = Xi[ei], yi[ei]
            Xt, yt = X[tst], y[tst]
            # proto
            ps.append(np.mean(proto_predict(Xe, ye, Xt) == yt))
            # gbt within
            if min(np.bincount(ye, minlength=3)[:3]) >= 1 and len(ye) >= 6:
                g = HistGradientBoostingClassifier(max_depth=3, max_iter=200).fit(Xe, ye)
                gs.append(np.mean(g.predict(Xt) == yt))
            # hybrid: others' data + this user's enrollment, UPWEIGHTED so a few
            # personal examples aren't drowned by ~8500 other-speaker samples.
            oth = (pid != p)
            Xh = np.concatenate([X[oth], Xe]); yh = np.concatenate([y[oth], ye])
            w = np.concatenate([np.ones(int(oth.sum())), np.full(len(ye), 40.0)])
            h = HistGradientBoostingClassifier(max_depth=4, max_iter=300).fit(Xh, yh, sample_weight=w)
            hs.append(np.mean(h.predict(Xt) == yt))
        print(f"{k:>8} {np.mean(ps):>8.3f} {np.mean(gs) if gs else 0:>8.3f} {np.mean(hs):>8.3f}")


if __name__ == "__main__":
    ks = [int(x) for x in sys.argv[2:]] if len(sys.argv) > 2 else [3, 5, 8, 15]
    main(sys.argv[1] if len(sys.argv) > 1 else DEFAULT_AVP_ROOT, ks)
