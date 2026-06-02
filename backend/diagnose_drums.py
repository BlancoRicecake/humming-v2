"""Drum-mode calibration harness.

Runs analyze_audio(as_drums=True) over labeled recordings and dumps per-onset
spectral features so the drums.py thresholds (centroid / rolloff / flatness /
zcr) can be set at the cluster boundaries between kick / snare / hi-hat.

Usage:
  # dump features for specific files
  python diagnose_drums.py _debug_uploads/upload_071.wav samples/"5. 비트.wav"

  # with labels (filename substring -> expected class) to score accuracy and
  # print per-class feature ranges; edit LABELS below or pass none for raw dump.
"""
from __future__ import annotations

import sys
import glob
import os
import warnings
from collections import defaultdict

warnings.filterwarnings("ignore")

from app.analyze import analyze_audio
from app.schemas import AnalyzeOptions

# Optional ground-truth: map a filename substring -> expected GM name.
# Fill in after recording labeled kick/snare/hi-hat takes on-device.
LABELS: dict[str, str] = {
    "upload_083": "Kick",
    "upload_084": "Snare",
    "upload_085": "HiHat",
    # upload_086 = mixed (no single label)
}


def _expected(path: str) -> str | None:
    base = os.path.basename(path)
    for key, label in LABELS.items():
        if key in base:
            return label
    return None


def main(paths: list[str]) -> None:
    if not paths:
        paths = sorted(glob.glob("_debug_uploads/*.wav")) + sorted(glob.glob("samples/*.wav"))

    # accumulate features per predicted class to print boundary-setting ranges
    by_pred: dict[str, list[dict]] = defaultdict(list)
    total = correct = 0

    for p in paths:
        if not os.path.exists(p):
            print(f"!! missing {p}")
            continue
        data = open(p, "rb").read()
        r = analyze_audio(data, AnalyzeOptions(as_drums=True))
        exp = _expected(p)
        print(f"\n=== {os.path.basename(p)}  onsets={len(r.notes)}  expected={exp or '-'} ===")
        print("  idx  time   pred   centroid rolloff  flat   zcr   onset")
        for i, n in enumerate(r.notes):
            mark = ""
            if exp:
                total += 1
                if n.drum_name == exp:
                    correct += 1
                else:
                    mark = f"  <-- expected {exp}"
            by_pred[n.drum_name].append({
                "centroid": n.drum_centroid, "rolloff": n.drum_rolloff,
                "flatness": n.drum_flatness, "zcr": n.drum_zcr,
            })
            print(f"  {i:3d} {n.start:6.2f}  {n.drum_name:5s}  "
                  f"{n.drum_centroid:7.0f} {n.drum_rolloff:7.0f} "
                  f"{n.drum_flatness:.3f} {n.drum_zcr:.3f} {n.onset_strength:5.2f}{mark}")

    # per-class feature ranges (min..max) — set thresholds between these
    print("\n=== per-(predicted)class feature ranges - set thresholds at the gaps ===")
    for cls in ("Kick", "Snare", "HiHat"):
        rows = by_pred.get(cls, [])
        if not rows:
            print(f"  {cls:5s}: (none)")
            continue
        def rng(k):
            vs = [x[k] for x in rows]
            return f"{min(vs):.3f}..{max(vs):.3f}" if k == "flatness" else f"{min(vs):.0f}..{max(vs):.0f}"
        print(f"  {cls:5s} n={len(rows):3d}  centroid[{rng('centroid')}] "
              f"rolloff[{rng('rolloff')}] flat[{rng('flatness')}] zcr[{rng('zcr')}]")

    if total:
        print(f"\nAccuracy vs labels: {correct}/{total} = {100*correct/total:.1f}%")


if __name__ == "__main__":
    main(sys.argv[1:])
