"""Test whether voice-drum classification accuracy can actually go higher.

Three regimes on AVP detected-onset features (matched to labels), all measured on
IMPROVISATION onsets (the serve target):

  A) cross-speaker LINEAR     — current approach (logistic, speaker-held-out)
  B) cross-speaker NONLINEAR  — gradient-boosted trees (does nonlinearity help?)
  C) within-speaker (per-user)— enroll on each speaker's OWN isolated takes,
                                test on their OWN improv (the per-user adaptation
                                the AVP dataset is designed for)

sklearn is used here for the EXPERIMENT only (dev dep). It does not touch the
serve path, which stays pure-numpy.
"""
from __future__ import annotations

import csv
import glob
import os
import re
import warnings
from collections import defaultdict

warnings.filterwarnings("ignore")

import numpy as np
import librosa
from sklearn.linear_model import LogisticRegression
from sklearn.ensemble import HistGradientBoostingClassifier

from app.drum_features import extract
from app.drum_onset import detect_onsets

CODE = {"kd": 0, "sd": 1, "hhc": 2, "hho": 2}
TOL = 0.05
GATE = 0.12
NAMES = ["kick", "snare", "hihat"]
DEFAULT_AVP_ROOT = "../../datasets/AVP_Dataset/AVP_Dataset"


def is_dataset_file(path):
    name = os.path.basename(path)
    return "__MACOSX" not in path and not name.startswith("._") and name != ".DS_Store"


def participant(p):
    m = re.search(r"Participant_(\d+)", p)
    return int(m.group(1)) if m else -1


def harvest(cpath):
    wav = cpath[:-4] + ".wav"
    if not os.path.exists(wav):
        return []
    labs = []
    for row in csv.reader(open(cpath, encoding="utf-8", errors="ignore")):
        if len(row) >= 2:
            try:
                c = CODE.get(row[1].strip().lower())
                if c is not None:
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
            out.append((extract(seg, y[a:a + winl], sr), lc[j]))
    return out


def acc(model, Xtr, ytr, Xte, yte):
    if len(set(ytr)) < 2 or len(Xte) == 0:
        return None
    model.fit(np.array(Xtr), np.array(ytr))
    return float(np.mean(model.predict(np.array(Xte)) == np.array(yte)))


def main(root):
    iso = defaultdict(list)   # pid -> [(feat,label)] from isolated files
    imp = defaultdict(list)   # pid -> [(feat,label)] from improv files
    for cpath in sorted(glob.glob(os.path.join(root, "**", "*.csv"), recursive=True)):
        if not is_dataset_file(cpath):
            continue
        pid = participant(cpath)
        rows = harvest(cpath)
        (imp if "Improvisation" in os.path.basename(cpath) else iso)[pid].extend(rows)

    pids = sorted(set(list(iso) + list(imp)))
    # ---- A & B: cross-speaker, leave-one-participant-out on improv ----
    a_scores, b_scores = [], []
    for held in pids:
        Xtr = [f for p in pids if p != held for f, _ in (iso[p] + imp[p])]
        ytr = [l for p in pids if p != held for _, l in (iso[p] + imp[p])]
        Xte = [f for f, _ in imp[held]]; yte = [l for _, l in imp[held]]
        a = acc(LogisticRegression(max_iter=2000, C=1.0), Xtr, ytr, Xte, yte)
        b = acc(HistGradientBoostingClassifier(max_depth=4, max_iter=300), Xtr, ytr, Xte, yte)
        if a is not None: a_scores.append(a)
        if b is not None: b_scores.append(b)
    # ---- C: within-speaker, enroll on own isolated, test on own improv ----
    c_scores = []
    for p in pids:
        Xtr = [f for f, _ in iso[p]]; ytr = [l for _, l in iso[p]]
        Xte = [f for f, _ in imp[p]]; yte = [l for _, l in imp[p]]
        c = acc(HistGradientBoostingClassifier(max_depth=4, max_iter=300), Xtr, ytr, Xte, yte)
        if c is not None: c_scores.append(c)

    print(f"improv onsets total: {sum(len(v) for v in imp.values())}, participants: {len(pids)}\n")
    print(f"A) cross-speaker  LINEAR   (logistic) improv acc: {np.mean(a_scores):.3f}  (n={len(a_scores)})")
    print(f"B) cross-speaker  NONLINEAR(GBT)      improv acc: {np.mean(b_scores):.3f}  (n={len(b_scores)})")
    print(f"C) within-speaker (enroll own sounds) improv acc: {np.mean(c_scores):.3f}  (n={len(c_scores)})")
    print(f"   within-speaker median: {np.median(c_scores):.3f}  min: {np.min(c_scores):.3f}  max: {np.max(c_scores):.3f}")


if __name__ == "__main__":
    import sys
    main(sys.argv[1] if len(sys.argv) > 1 else DEFAULT_AVP_ROOT)
