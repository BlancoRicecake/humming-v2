"""Segmentation-evidence R&D: find a boundary generator that lifts ref-note
reachability toward 0.90, measured cheaply on the cache (no WAV, no rebuild).

We replace the fixed _boundary_candidates with a CONFIGURABLE generator so we
can probe the two ceilings found in the feasibility study:
  * onset floor   (~0.85-0.90): some true onsets have no boundary near them.
  * offset gap    (~0.66-0.74 segment-reachable): true note ENDS are missing.

New evidence sources (all from cached envelope/pitch/onset arrays):
  * onset_proxy peaks at a TUNABLE threshold (default 0.25 was the old value).
  * pitch-change points at a tunable semitone threshold.
  * RMS local minima (note-to-note dips) at a tunable ratio.
  * ENERGY-DECAY note-end boundaries: after a local RMS peak, the frame where
    RMS first falls below decay_ratio * that peak -> a note offset candidate.
  * optional uniform time grid (sanity upper bound; explodes candidate count).

Reports onset-reachable, segment-reachable, and candidates/file so we seek HIGH
reachability at LOW candidate count (a dense grid cheats reachability but makes
the selector's job impossible).

Usage:
  python diag_boundary_rnd.py --cache-dir <cache>/v1 --split dev --limit 300 \
      --onset-thresh 0.15 --rms-dip-ratio 0.90 --decay-ratio 0.5 \
      --pitch-change-st 0.50 [--grid-ms 0]
"""
from __future__ import annotations

import argparse
import statistics
from pathlib import Path

import numpy as np

from eval_humtrans import note_from_dict, read_cache_file
from extract_humtrans_sequence_candidates import _arr, _win, _median_pitch


def gen_boundaries(meta: dict, pred_notes: list, args) -> list[float]:
    env_t = _arr(meta, "envelope_times")
    rms = _arr(meta, "envelope_rms")
    onset = _arr(meta, "onset_proxy")
    pitch_t = _arr(meta, "pitch_times")
    pitch = _arr(meta, "pitch_midi")
    b = {0.0}

    if not args.no_pred_boundaries:
        for n in pred_notes:
            b.add(float(n.start))
            b.add(float(n.end))

    # onset_proxy peaks above a tunable threshold
    if env_t.size and onset.size:
        for t in env_t[onset >= args.onset_thresh]:
            b.add(float(t))

    # pitch-change points
    if pitch_t.size and pitch.size >= 3:
        for i in range(1, len(pitch)):
            a, c = pitch[i - 1], pitch[i]
            if np.isfinite(a) and np.isfinite(c) and abs(float(c - a)) >= args.pitch_change_st:
                b.add(float(pitch_t[i]))

    # RMS local minima (note-to-note dips) at a tunable ratio of median
    if env_t.size and rms.size >= 3:
        med = float(np.median(rms))
        for i in range(1, len(rms) - 1):
            if rms[i] <= rms[i - 1] and rms[i] <= rms[i + 1] and rms[i] <= med * args.rms_dip_ratio:
                b.add(float(env_t[i]))

    # ENERGY-DECAY note-end boundaries
    if args.decay_ratio > 0 and env_t.size and rms.size >= 3:
        peak = 0.0
        above = False
        med = float(np.median(rms))
        onset_floor = med * 0.5  # only track decays from meaningful energy
        for i in range(len(rms)):
            v = float(rms[i])
            if v > peak:
                peak = v
            if v >= onset_floor:
                above = True
            if above and peak > 0 and v <= args.decay_ratio * peak:
                b.add(float(env_t[i]))
                above = False
                peak = v  # reset to start tracking the next note body

    # optional uniform grid (sanity upper bound)
    if args.grid_ms > 0 and env_t.size:
        t = 0.0
        tmax = float(env_t[-1])
        step = args.grid_ms / 1000.0
        while t <= tmax:
            b.add(round(t, 4))
            t += step

    return sorted(x for x in b if x >= 0.0)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--cache-dir", type=Path, required=True)
    ap.add_argument("--split", default="dev")
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--onset-thresh", type=float, default=0.25)
    ap.add_argument("--pitch-change-st", type=float, default=0.70)
    ap.add_argument("--rms-dip-ratio", type=float, default=0.82)
    ap.add_argument("--decay-ratio", type=float, default=0.0, help="0 disables energy-decay offsets")
    ap.add_argument("--grid-ms", type=float, default=0.0)
    ap.add_argument("--no-pred-boundaries", action="store_true")
    ap.add_argument("--min-duration", type=float, default=0.04)
    ap.add_argument("--max-duration", type=float, default=2.50)
    ap.add_argument("--max-boundary-span", type=int, default=8)
    ap.add_argument("--onset-tol", type=float, default=0.12)
    ap.add_argument("--offset-tol", type=float, default=0.18)
    args = ap.parse_args()

    files = sorted((args.cache_dir / args.split).glob("*.json.gz"))
    if args.limit:
        files = files[: args.limit]

    tot_ref = cov_onset = cov_seg = n_cands = 0
    # span-independent evidence presence
    pres_onset = pres_offset = pres_both = 0
    bnds_per_file: list[int] = []

    for f in files:
        data = read_cache_file(f)
        ref = [note_from_dict(x) for x in data.get("ref_notes", [])]
        pred = [note_from_dict(x) for x in data.get("pred_notes", [])]
        meta = dict(data.get("analysis_meta", {}))
        if not ref:
            continue
        boundaries = gen_boundaries(meta, pred, args)
        bnds_per_file.append(len(boundaries))
        barr = np.array(boundaries) if boundaries else np.zeros(0)
        # enumerate candidate spans
        cands: list[tuple[float, float]] = []
        for i in range(len(boundaries) - 1):
            for j in range(i + 1, min(len(boundaries), i + 1 + args.max_boundary_span)):
                s, e = boundaries[i], boundaries[j]
                d = e - s
                if d < args.min_duration or d > args.max_duration:
                    continue
                cands.append((s, e))
        n_cands += len(cands)
        tot_ref += len(ref)
        starts = np.array([c[0] for c in cands]) if cands else np.zeros(0)
        ends = np.array([c[1] for c in cands]) if cands else np.zeros(0)
        for r in ref:
            # span-independent: does ANY boundary land near the ref start / end?
            o_pres = barr.size and bool((np.abs(barr - r.start) <= args.onset_tol).any())
            f_pres = barr.size and bool((np.abs(barr - r.end) <= args.offset_tol).any())
            if o_pres:
                pres_onset += 1
            if f_pres:
                pres_offset += 1
            if o_pres and f_pres:
                pres_both += 1
            # span-coupled (what the current extractor enumeration can actually form)
            if starts.size == 0:
                continue
            onset_hit = np.abs(starts - r.start) <= args.onset_tol
            if onset_hit.any():
                cov_onset += 1
                if (onset_hit & (np.abs(ends - r.end) <= args.offset_tol)).any():
                    cov_seg += 1

    cfg = (f"onset>={args.onset_thresh} pitchΔ>={args.pitch_change_st} "
           f"rmsdip<={args.rms_dip_ratio} decay={args.decay_ratio} "
           f"grid={args.grid_ms}ms span={args.max_boundary_span}")
    print(f"=== boundary R&D | {cfg} ===")
    print(f"files={len(files)} ref={tot_ref} "
          f"boundaries/file~{statistics.fmean(bnds_per_file):.0f} "
          f"candidates/file~{n_cands/max(len(files),1):.0f}")
    print(f"  [span-independent evidence presence]")
    print(f"  onset-boundary-present  = {pres_onset/tot_ref:.3f}")
    print(f"  offset-boundary-present = {pres_offset/tot_ref:.3f}")
    print(f"  both-present (ceiling)  = {pres_both/tot_ref:.3f}")
    print(f"  [span-{args.max_boundary_span} enumerated candidates]")
    print(f"  onset-reachable   = {cov_onset/tot_ref:.3f}")
    print(f"  segment-reachable = {cov_seg/tot_ref:.3f}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
