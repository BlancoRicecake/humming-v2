"""Phase A3 offset/duration bias diagnosis (read-only, throwaway analysis).

Reads an eval --details-dir produced by eval_humtrans.py and characterizes the
offset error distribution among onset-matched notes that already have correct
pitch -- i.e. exactly the notes that would become full matches if their offset
were within tolerance. This is the population behind `bad_offset` and the gap
between note_f1 and upper_if_offsets_fixed_f1.

Decision support:
  * signed mean/median of offset_delta_ms -> systematic bias? (negative = pred
    note ends too early; positive = fill_gaps over-extends)
  * histogram around the +/-offset_tol boundary -> are bad offsets clustered
    just past the boundary (calibratable) or a fat tail (structural)?
  * fraction with |offset_delta| > offset_tol -> the bad_offset share.

Usage:
  python diag_offset_bias.py --details-dir runs/dev_baseline_details \
      --offset-tol-ms 180
"""
from __future__ import annotations

import argparse
import json
import math
import statistics
from pathlib import Path


def _percentile(sorted_vals: list[float], q: float) -> float:
    if not sorted_vals:
        return 0.0
    if len(sorted_vals) == 1:
        return sorted_vals[0]
    pos = q / 100.0 * (len(sorted_vals) - 1)
    lo = int(math.floor(pos))
    hi = int(math.ceil(pos))
    if lo == hi:
        return sorted_vals[lo]
    frac = pos - lo
    return sorted_vals[lo] * (1 - frac) + sorted_vals[hi] * frac


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--details-dir", type=Path, required=True)
    ap.add_argument("--offset-tol-ms", type=float, default=180.0)
    ap.add_argument("--pitch-tol-st", type=int, default=0)
    args = ap.parse_args()

    files = sorted(args.details_dir.glob("*.json"))
    if not files:
        raise SystemExit(f"no detail json under {args.details_dir}")

    # offset deltas over onset-matched notes WITH correct pitch (the upper-bound population)
    deltas: list[float] = []
    # offset deltas over the strict full-match population (already within offset tol)
    full_deltas: list[float] = []
    dur_pred: list[float] = []
    dur_ref: list[float] = []
    n_onset_matched = 0
    n_pitch_ok = 0

    for f in files:
        d = json.loads(f.read_text(encoding="utf-8"))
        for m in d.get("onset_matches", []):
            n_onset_matched += 1
            if abs(int(m["pitch_delta_st"])) <= args.pitch_tol_st:
                n_pitch_ok += 1
                deltas.append(float(m["offset_delta_ms"]))
                r = m["ref"]
                p = m["pred"]
                dur_ref.append(float(r["end"]) - float(r["start"]))
                dur_pred.append(float(p["end"]) - float(p["start"]))
        for m in d.get("matches", []):
            full_deltas.append(float(m["offset_delta_ms"]))

    if not deltas:
        raise SystemExit("no onset-matched, pitch-correct notes found")

    tol = args.offset_tol_ms
    sd = sorted(deltas)
    n = len(sd)
    over = [x for x in sd if abs(x) > tol]
    over_pos = sum(1 for x in over if x > 0)
    over_neg = sum(1 for x in over if x < 0)

    print(f"=== Phase A3 offset/duration bias ({args.details_dir}) ===")
    print(f"files={len(files)}  onset_matched={n_onset_matched}  "
          f"pitch_ok(onset+pitch)={n_pitch_ok}")
    print(f"full_matches(in strict set)={len(full_deltas)}")
    print()
    print("--- offset_delta_ms over onset+pitch-correct notes ---")
    print(f"  mean   = {statistics.fmean(sd):+8.1f} ms")
    print(f"  median = {statistics.median(sd):+8.1f} ms")
    print(f"  stdev  = {statistics.pstdev(sd):8.1f} ms")
    for q in (5, 10, 25, 50, 75, 90, 95):
        print(f"  p{q:<2} = {_percentile(sd, q):+8.1f} ms")
    print()
    print(f"--- bad-offset population (|delta| > {tol:.0f} ms) ---")
    print(f"  count = {len(over)} / {n}  ({100.0*len(over)/n:.1f}% of onset+pitch-correct)")
    print(f"  of those: end-too-late (+) = {over_pos}   end-too-early (-) = {over_neg}")
    if over:
        print(f"  worst (most extreme delta) = {max(over, key=abs):+.0f} ms")
    print()

    # histogram buckets around the tolerance boundary
    edges = [-1e9, -3 * tol, -2 * tol, -tol, -tol / 2, 0,
             tol / 2, tol, 2 * tol, 3 * tol, 1e9]
    labels = [
        f"< -{3*tol:.0f}", f"-{3*tol:.0f}..-{2*tol:.0f}", f"-{2*tol:.0f}..-{tol:.0f}",
        f"-{tol:.0f}..-{tol/2:.0f}", f"-{tol/2:.0f}..0", f"0..{tol/2:.0f}",
        f"{tol/2:.0f}..{tol:.0f}", f"{tol:.0f}..{2*tol:.0f}", f"{2*tol:.0f}..{3*tol:.0f}",
        f"> {3*tol:.0f}",
    ]
    counts = [0] * (len(edges) - 1)
    for x in sd:
        for i in range(len(edges) - 1):
            if edges[i] <= x < edges[i + 1]:
                counts[i] += 1
                break
    print(f"--- histogram (ms buckets; |.|<={tol:.0f} is within-tol) ---")
    peak = max(counts) or 1
    for lab, c in zip(labels, counts):
        bar = "#" * int(40 * c / peak)
        print(f"  {lab:>14} | {c:5d} {bar}")
    print()

    # duration ratio: are pred notes systematically shorter/longer?
    ratios = [p / r for p, r in zip(dur_pred, dur_ref) if r > 1e-6]
    if ratios:
        print("--- duration ratio pred/ref (onset+pitch-correct) ---")
        print(f"  median ratio = {statistics.median(ratios):.3f}  "
              f"(<1 pred shorter, >1 pred longer)")
        print(f"  mean pred dur = {1000*statistics.fmean(dur_pred):.0f} ms   "
              f"mean ref dur = {1000*statistics.fmean(dur_ref):.0f} ms")
    print()

    # verdict hint
    med = statistics.median(sd)
    iqr = _percentile(sd, 75) - _percentile(sd, 25)
    print("--- verdict hint ---")
    print(f"  |median| = {abs(med):.0f} ms,  IQR = {iqr:.0f} ms,  "
          f"bad-offset share = {100.0*len(over)/n:.1f}%")
    if abs(med) > 0.4 * tol and iqr < 2.0 * tol:
        print("  => systematic bias + bounded spread: GLOBAL/MEDIAN CALIBRATION JUSTIFIED (B1a).")
    elif abs(med) <= 0.4 * tol and len(over) / n > 0.15:
        print("  => near-zero mean, fat tail: structural mis-segmentation, "
              "global calibration unlikely to help (lean Phase C).")
    else:
        print("  => mixed signal: try B1 calibration but expect modest gain; "
              "Phase C likely still needed.")


if __name__ == "__main__":
    main()
