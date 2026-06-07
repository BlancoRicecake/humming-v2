"""Segmentation R&D step: TYPED candidate enumeration.

The feasibility probe showed boundary EVIDENCE is rich (both-present ceiling
~0.95) but the all-pairs span-8 enumeration could not FORM the right (start,end)
candidates without exploding count. Fix: type the boundaries and only pair an
ONSET-type start with the next K OFFSET-type ends.

  start boundaries : onset_proxy peaks (>= onset_thresh), pitch-change points,
                     pred-note starts, t=0
  end boundaries   : energy-decay points, RMS dips, pred-note ends, AND onset
                     points (a note often ends exactly at the next onset), tmax

Goal: high segment-reachable (ref note has a candidate matching onset within
onset_tol AND end within offset_tol) at LOW candidates/file, so the selector
has a tractable, high-ceiling candidate set.

Usage:
  python diag_typed_candidates.py --cache-dir <cache>/v1 --split dev --limit 300 \
      --onset-thresh 0.12 --decay-ratio 0.5 --rms-dip-ratio 0.92 \
      --pitch-change-st 0.5 --k-ends 4
"""
from __future__ import annotations

import argparse
import statistics
from pathlib import Path

import numpy as np

from eval_humtrans import note_from_dict, read_cache_file
from extract_humtrans_sequence_candidates import _arr


def typed_boundaries(meta: dict, pred_notes: list, args) -> tuple[list[float], list[float]]:
    env_t = _arr(meta, "envelope_times")
    rms = _arr(meta, "envelope_rms")
    onset = _arr(meta, "onset_proxy")
    pitch_t = _arr(meta, "pitch_times")
    pitch = _arr(meta, "pitch_midi")

    starts = {0.0}
    ends = set()
    if env_t.size:
        ends.add(float(env_t[-1]))

    # onset-type points
    onset_pts: set[float] = set()
    if env_t.size and onset.size:
        for t in env_t[onset >= args.onset_thresh]:
            onset_pts.add(float(t))
    if pitch_t.size and pitch.size >= 3:
        for i in range(1, len(pitch)):
            a, c = pitch[i - 1], pitch[i]
            if np.isfinite(a) and np.isfinite(c) and abs(float(c - a)) >= args.pitch_change_st:
                onset_pts.add(float(pitch_t[i]))
    for n in pred_notes:
        onset_pts.add(float(n.start))
    starts |= onset_pts
    # a note can end at the next note's onset
    ends |= onset_pts

    # offset-type: pred ends
    for n in pred_notes:
        ends.add(float(n.end))
    # RMS dips
    if env_t.size and rms.size >= 3:
        med = float(np.median(rms))
        for i in range(1, len(rms) - 1):
            if rms[i] <= rms[i - 1] and rms[i] <= rms[i + 1] and rms[i] <= med * args.rms_dip_ratio:
                ends.add(float(env_t[i]))
    # energy-decay points
    if args.decay_ratio > 0 and env_t.size and rms.size >= 3:
        med = float(np.median(rms))
        floor = med * 0.5
        peak = 0.0
        above = False
        for i in range(len(rms)):
            v = float(rms[i])
            if v > peak:
                peak = v
            if v >= floor:
                above = True
            if above and peak > 0 and v <= args.decay_ratio * peak:
                ends.add(float(env_t[i]))
                above = False
                peak = v
    return sorted(starts), sorted(ends)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--cache-dir", type=Path, required=True)
    ap.add_argument("--split", default="dev")
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--offset", type=int, default=0)
    ap.add_argument("--onset-thresh", type=float, default=0.12)
    ap.add_argument("--pitch-change-st", type=float, default=0.5)
    ap.add_argument("--rms-dip-ratio", type=float, default=0.92)
    ap.add_argument("--decay-ratio", type=float, default=0.5)
    ap.add_argument("--k-ends", type=int, default=4, help="pair each start with next K end boundaries")
    ap.add_argument("--min-duration", type=float, default=0.04)
    ap.add_argument("--max-duration", type=float, default=2.50)
    ap.add_argument("--onset-tol", type=float, default=0.12)
    ap.add_argument("--offset-tol", type=float, default=0.18)
    args = ap.parse_args()

    files = sorted((args.cache_dir / args.split).glob("*.json.gz"))
    if args.offset:
        files = files[args.offset:]
    if args.limit:
        files = files[: args.limit]

    tot_ref = cov_seg = n_cands = 0
    cands_per_file: list[int] = []

    for f in files:
        data = read_cache_file(f)
        ref = [note_from_dict(x) for x in data.get("ref_notes", [])]
        pred = [note_from_dict(x) for x in data.get("pred_notes", [])]
        meta = dict(data.get("analysis_meta", {}))
        if not ref:
            continue
        starts, ends = typed_boundaries(meta, pred, args)
        ends_arr = np.array(ends)
        cands: list[tuple[float, float]] = []
        for s in starts:
            after = ends_arr[ends_arr > s + args.min_duration]
            picked = 0
            for e in after:
                d = e - s
                if d > args.max_duration:
                    break
                cands.append((s, float(e)))
                picked += 1
                if picked >= args.k_ends:
                    break
        cands_per_file.append(len(cands))
        n_cands += len(cands)
        tot_ref += len(ref)
        cs = np.array([c[0] for c in cands]) if cands else np.zeros(0)
        ce = np.array([c[1] for c in cands]) if cands else np.zeros(0)
        for r in ref:
            if cs.size == 0:
                continue
            hit = (np.abs(cs - r.start) <= args.onset_tol) & (np.abs(ce - r.end) <= args.offset_tol)
            if hit.any():
                cov_seg += 1

    print(f"=== typed candidates | onset>={args.onset_thresh} decay={args.decay_ratio} "
          f"dip<={args.rms_dip_ratio} pitchΔ>={args.pitch_change_st} K={args.k_ends} ===")
    print(f"files={len(files)} ref={tot_ref} "
          f"candidates/file~{n_cands/max(len(files),1):.0f}")
    print(f"  segment-reachable = {cov_seg/tot_ref:.3f}  ({cov_seg}/{tot_ref})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
