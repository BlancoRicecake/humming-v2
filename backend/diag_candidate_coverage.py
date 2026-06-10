"""Phase-C feasibility probe: how far can a note-sequence selector even reach?

For each cached file we generate the SAME boundary candidates the sequence
extractor uses, then ask what fraction of REFERENCE notes is *reachable* by some
candidate. This is the hard ceiling on note_f1 for any selector built on these
candidates (plan risk R3): a ref note with no matching candidate can never be
recovered, no matter how good the scorer is.

Three decomposed levels:
  1. onset-reachable      : a candidate starts within onset_tol of the ref onset
                            (pitch & offset ignored -> pure boundary reachability)
  2. segment-reachable    : also ends within offset_tol of the ref end
  3. full-reachable       : also exact pitch, under one per-file global pitch
                            shift (mirrors eval --normalize-key)

Reads only the cache (no WAV, no rebuild).

Usage:
  python diag_candidate_coverage.py --cache-dir <cache>/v1 --split dev \
      [--limit N] [--max-boundary-span 8]
"""
from __future__ import annotations

import argparse
import collections
from pathlib import Path

import numpy as np

from eval_humtrans import note_from_dict, read_cache_file
from extract_humtrans_sequence_candidates import (
    _boundary_candidates,
    _median_pitch,
    _win,
    _arr,
)


def _candidates(meta: dict, pred_notes: list, min_dur: float, max_dur: float,
                span: int) -> list[tuple[float, float, int]]:
    pitch_t = _arr(meta, "pitch_times")
    pitch_midi = _arr(meta, "pitch_midi")
    boundaries = _boundary_candidates(meta, pred_notes)
    default_pitch = int(pred_notes[0].pitch) if pred_notes else 60
    out: list[tuple[float, float, int]] = []
    for i in range(len(boundaries) - 1):
        for j in range(i + 1, min(len(boundaries), i + 1 + span)):
            start = float(boundaries[i])
            end = float(boundaries[j])
            dur = end - start
            if dur < min_dur or dur > max_dur:
                continue
            pv = _win(pitch_t, pitch_midi, start, end)
            out.append((start, end, _median_pitch(pv, default_pitch)))
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--cache-dir", type=Path, required=True)
    ap.add_argument("--split", choices=["train", "dev", "test"], default="dev")
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--min-duration", type=float, default=0.04)
    ap.add_argument("--max-duration", type=float, default=2.50)
    ap.add_argument("--max-boundary-span", type=int, default=8)
    ap.add_argument("--onset-tol", type=float, default=0.12)
    ap.add_argument("--offset-tol", type=float, default=0.18)
    args = ap.parse_args()

    files = sorted((args.cache_dir / args.split).glob("*.json.gz"))
    if args.limit:
        files = files[: args.limit]
    if not files:
        raise SystemExit(f"no cache files under {args.cache_dir / args.split}")

    tot_ref = 0
    cov_onset = 0
    cov_seg = 0
    cov_full = 0
    n_pred_notes = 0
    n_cands = 0
    per_file_cov_full: list[float] = []

    for f in files:
        data = read_cache_file(f)
        ref = [note_from_dict(x) for x in data.get("ref_notes", [])]
        pred = [note_from_dict(x) for x in data.get("pred_notes", [])]
        meta = dict(data.get("analysis_meta", {}))
        if not ref:
            continue
        cands = _candidates(meta, pred, args.min_duration, args.max_duration,
                            args.max_boundary_span)
        n_pred_notes += len(pred)
        n_cands += len(cands)
        tot_ref += len(ref)

        # level 1 & 2: pitch-independent reachability
        # level 3: per-file global shift histogram
        shift_hits: dict[int, set[int]] = collections.defaultdict(set)
        file_seg_cov = 0
        for ri, r in enumerate(ref):
            onset_ok = False
            seg_ok = False
            for (cs, ce, cp) in cands:
                if abs(cs - r.start) <= args.onset_tol:
                    onset_ok = True
                    if abs(ce - r.end) <= args.offset_tol:
                        seg_ok = True
                        shift = int(r.pitch) - int(cp)
                        if -24 <= shift <= 24:
                            shift_hits[shift].add(ri)
            if onset_ok:
                cov_onset += 1
            if seg_ok:
                cov_seg += 1
                file_seg_cov += 1
        # best single global shift for this file (mirrors --normalize-key)
        best = max((len(s) for s in shift_hits.values()), default=0)
        cov_full += best
        per_file_cov_full.append(best / len(ref))

    print(f"=== Phase-C candidate coverage ({args.cache_dir / args.split}) ===")
    print(f"files={len(files)}  ref_notes={tot_ref}  "
          f"pred_notes={n_pred_notes}  candidates={n_cands} "
          f"(~{n_cands / max(len(files),1):.0f}/file)")
    print()
    print("REF-note reachability (ceiling on recall for a selector on these candidates):")
    print(f"  1. onset-reachable      = {cov_onset/tot_ref:.3f}  "
          f"({cov_onset}/{tot_ref})")
    print(f"  2. segment-reachable    = {cov_seg/tot_ref:.3f}  "
          f"({cov_seg}/{tot_ref})   [onset+offset]")
    print(f"  3. full-reachable       = {cov_full/tot_ref:.3f}  "
          f"({cov_full}/{tot_ref})   [onset+offset+exact pitch, per-file shift]")
    print()
    if per_file_cov_full:
        import statistics
        print(f"  per-file full-reachable: macro mean "
              f"{statistics.fmean(per_file_cov_full):.3f}, "
              f"median {statistics.median(per_file_cov_full):.3f}")
    print()
    print("Interpretation: level-3 is the MAX note recall any selector on these")
    print("candidates could reach. If it's well above the current note_f1, the")
    print("ceiling is the SELECTOR (worth building). If it's near current, the")
    print("ceiling is CANDIDATE GENERATION (need richer boundaries first).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
