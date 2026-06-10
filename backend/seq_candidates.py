"""Enriched note-candidate generation for the sequence selector.

Self-contained (imports only small helpers from the existing extractor). The
candidate set here uses the boundary evidence the feasibility study found rich
enough (both-present ceiling ~0.95):
  * onset_proxy peaks at a LOW threshold (0.12, vs the old 0.25)
  * pitch-change points (>=0.5 st)
  * RMS dips (<=0.92*median)
  * energy-decay note-ends (RMS falls below decay_ratio*local-peak)
  * pred-note starts/ends, t=0, tmax

Boundaries are quantized to 20 ms and de-duplicated (20 ms << onset/offset tol so
reachability is preserved while candidate count drops). Candidates = all
(start,end) boundary pairs with duration in [min_dur, max_dur]. Each candidate
gets a median pitch and a feature vector; for training it also gets a label
(1 if it matches a ref note within tol).

Used by:
  * train data export (this file's main): --out CSV with labels (+ negative subsample)
  * inference (app.sequence_select): gen_candidates() then score+DP-select
"""
from __future__ import annotations

import argparse
import csv
import math
from pathlib import Path

import numpy as np

from eval_humtrans import note_from_dict, read_cache_file
from extract_humtrans_sequence_candidates import _arr, _win, _interp, _key_classes


FEATURES = [
    "duration",
    "onset_strength",
    "end_onset_strength",
    "rms_mean",
    "rms_peak_ratio",
    "rms_min_ratio",
    "rms_end_drop",
    "pitch_stability",
    "voiced_ratio",
    "finite_ratio",
    "pitch_delta_prev",
    "pitch_delta_next",
    "in_key",
    "attack_sharpness",
    "decay_evidence",
]


def _median_pitch_f(values: np.ndarray) -> tuple[float, float]:
    """Return (median_midi_float, finite_ratio)."""
    if values.size == 0:
        return float("nan"), 0.0
    finite = values[np.isfinite(values)]
    if finite.size == 0:
        return float("nan"), 0.0
    return float(np.median(finite)), finite.size / values.size


def enriched_boundaries(meta: dict, pred_notes: list, *, onset_thresh: float = 0.12,
                        pitch_change_st: float = 0.5, rms_dip_ratio: float = 0.92,
                        decay_ratio: float = 0.5, quant_ms: float = 20.0) -> list[float]:
    env_t = _arr(meta, "envelope_times")
    rms = _arr(meta, "envelope_rms")
    onset = _arr(meta, "onset_proxy")
    pitch_t = _arr(meta, "pitch_times")
    pitch = _arr(meta, "pitch_midi")
    b: set[float] = {0.0}
    if env_t.size:
        b.add(float(env_t[-1]))
    for n in pred_notes:
        b.add(float(n.start))
        b.add(float(n.end))
    if env_t.size and onset.size:
        for t in env_t[onset >= onset_thresh]:
            b.add(float(t))
    if pitch_t.size and pitch.size >= 3:
        for i in range(1, len(pitch)):
            a, c = pitch[i - 1], pitch[i]
            if np.isfinite(a) and np.isfinite(c) and abs(float(c - a)) >= pitch_change_st:
                b.add(float(pitch_t[i]))
    if env_t.size and rms.size >= 3:
        med = float(np.median(rms))
        for i in range(1, len(rms) - 1):
            if rms[i] <= rms[i - 1] and rms[i] <= rms[i + 1] and rms[i] <= med * rms_dip_ratio:
                b.add(float(env_t[i]))
    if decay_ratio > 0 and env_t.size and rms.size >= 3:
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
            if above and peak > 0 and v <= decay_ratio * peak:
                b.add(float(env_t[i]))
                above = False
                peak = v
    q = quant_ms / 1000.0
    quantized = sorted({round(round(x / q) * q, 4) for x in b if x >= 0.0})
    return quantized


def gen_candidates(meta: dict, pred_notes: list, *, min_dur: float = 0.05,
                   max_dur: float = 1.30, **bargs) -> list[dict]:
    env_t = _arr(meta, "envelope_times")
    rms = _arr(meta, "envelope_rms")
    onset = _arr(meta, "onset_proxy")
    pitch_t = _arr(meta, "pitch_times")
    pitch_midi = _arr(meta, "pitch_midi")
    voiced = _arr(meta, "voiced_prob")
    key_classes = _key_classes(meta)
    bounds = enriched_boundaries(meta, pred_notes, **bargs)
    rms_global_peak = float(np.max(rms)) if rms.size else 1.0
    # precompute for fast windowed features (searchsorted on monotonic time axes)
    env_clean = np.nan_to_num(onset, nan=0.0, posinf=0.0, neginf=0.0) if onset.size else onset
    voiced_bin = (voiced >= 0.45).astype(np.float32) if voiced.size else voiced
    out: list[dict] = []
    for i in range(len(bounds) - 1):
        s = bounds[i]
        for j in range(i + 1, len(bounds)):
            e = bounds[j]
            d = e - s
            if d < min_dur:
                continue
            if d > max_dur:
                break
            # pitch window via searchsorted (pitch_t monotonic)
            if pitch_t.size:
                a = int(np.searchsorted(pitch_t, s, "left"))
                b = int(np.searchsorted(pitch_t, e, "right"))
                pv = pitch_midi[a:b]
                vv = voiced_bin[a:b] if voiced_bin.size else np.zeros(0)
            else:
                pv = np.zeros(0); vv = np.zeros(0)
            med_pitch, finite_ratio = _median_pitch_f(pv)
            if not math.isfinite(med_pitch):
                continue
            pitch = int(math.floor(med_pitch + 0.5))
            finite = pv[np.isfinite(pv)]
            stability = float(np.std(finite)) if finite.size else 9.0
            # rms window via searchsorted (env_t monotonic)
            if env_t.size:
                ea = int(np.searchsorted(env_t, s, "left"))
                eb = int(np.searchsorted(env_t, e, "right"))
                rv = rms[ea:eb]
            else:
                rv = np.zeros(0)
            rms_mean = float(np.mean(rv)) if rv.size else 0.0
            rms_min = float(np.min(rv)) if rv.size else 0.0
            rms_end = float(rv[-1]) if rv.size else 0.0
            rms_start = float(rv[0]) if rv.size else 0.0
            if env_t.size and env_clean.size:
                onset_s, onset_e, pre = np.interp(
                    [s, e, s - 0.04], env_t, env_clean, left=0.0, right=0.0)
                onset_s = float(onset_s); onset_e = float(onset_e); pre = float(pre)
            else:
                onset_s = onset_e = pre = 0.0
            out.append({
                "start": s, "end": e, "pitch": pitch,
                "duration": d,
                "onset_strength": onset_s,
                "end_onset_strength": onset_e,
                "rms_mean": rms_mean,
                "rms_peak_ratio": rms_mean / max(rms_global_peak, 1e-7),
                "rms_min_ratio": rms_min / max(rms_mean, 1e-7),
                "rms_end_drop": (rms_start - rms_end) / max(rms_start, 1e-7),
                "pitch_stability": stability,
                "voiced_ratio": float(np.mean(vv)) if vv.size else 0.0,
                "finite_ratio": finite_ratio,
                "in_key": int(key_classes is None or pitch % 12 in key_classes),
                "attack_sharpness": onset_s - pre,
                "decay_evidence": (rms_start - rms_end) / max(rms_mean, 1e-7),
                "pitch_delta_prev": 0.0,
                "pitch_delta_next": 0.0,
            })
    # neighbor pitch deltas (sequential context, by start time)
    out.sort(key=lambda c: (c["start"], c["end"]))
    for k, c in enumerate(out):
        if k > 0:
            c["pitch_delta_prev"] = float(c["pitch"] - out[k - 1]["pitch"])
        if k + 1 < len(out):
            c["pitch_delta_next"] = float(out[k + 1]["pitch"] - c["pitch"])
    return out


def label_candidate(c: dict, ref_notes: list, onset_tol: float, offset_tol: float,
                    shift: int = 0) -> int:
    for r in ref_notes:
        if (abs(float(r.start) - c["start"]) <= onset_tol
                and abs(float(r.end) - c["end"]) <= offset_tol
                and int(r.pitch) == int(c["pitch"]) + shift):
            return 1
    return 0


def _best_shift(cands: list[dict], ref_notes: list, onset_tol: float, offset_tol: float) -> int:
    """Per-file global pitch shift that maximizes positive labels (mirrors normalize-key)."""
    from collections import Counter
    votes: Counter = Counter()
    for r in ref_notes:
        for c in cands:
            if (abs(float(r.start) - c["start"]) <= onset_tol
                    and abs(float(r.end) - c["end"]) <= offset_tol):
                votes[int(r.pitch) - int(c["pitch"])] += 1
    return votes.most_common(1)[0][0] if votes else 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--cache-dir", type=Path, required=True)
    ap.add_argument("--split", default="train")
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--offset", type=int, default=0)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--onset-tol", type=float, default=0.12)
    ap.add_argument("--offset-tol", type=float, default=0.18)
    ap.add_argument("--neg-per-pos", type=int, default=8, help="negative subsample ratio")
    ap.add_argument("--max-dur", type=float, default=1.80)
    args = ap.parse_args()

    files = sorted((args.cache_dir / args.split).glob("*.json.gz"))
    if args.offset:
        files = files[args.offset:]
    if args.limit:
        files = files[: args.limit]

    rng = np.random.default_rng(0)
    rows: list[dict] = []
    n_pos = n_neg = n_files = 0
    cov_pos = 0
    tot_ref = 0
    for f in files:
        data = read_cache_file(f)
        ref = [note_from_dict(x) for x in data.get("ref_notes", [])]
        pred = [note_from_dict(x) for x in data.get("pred_notes", [])]
        meta = dict(data.get("analysis_meta", {}))
        if not ref:
            continue
        n_files += 1
        tot_ref += len(ref)
        cands = gen_candidates(meta, pred, max_dur=args.max_dur)
        if not cands:
            continue
        shift = _best_shift(cands, ref, args.onset_tol, args.offset_tol)
        pos_idx, neg_idx = [], []
        covered = set()
        for ci, c in enumerate(cands):
            lab = label_candidate(c, ref, args.onset_tol, args.offset_tol, shift)
            c["label"] = lab
            if lab:
                pos_idx.append(ci)
            else:
                neg_idx.append(ci)
        # count ref coverage (unique ref notes hit by a positive)
        for r in ref:
            for c in cands:
                if c["label"] and abs(float(r.start) - c["start"]) <= args.onset_tol \
                        and abs(float(r.end) - c["end"]) <= args.offset_tol \
                        and int(r.pitch) == int(c["pitch"]) + shift:
                    covered.add(id(r))
                    break
        cov_pos += len(covered)
        keep_neg = min(len(neg_idx), max(1, len(pos_idx) * args.neg_per_pos))
        sel_neg = rng.choice(neg_idx, size=keep_neg, replace=False) if neg_idx else []
        key = str(data.get("key") or f.stem)
        for ci in list(pos_idx) + list(sel_neg):
            c = cands[ci]
            row = {"key": key, "label": c["label"]}
            for fld in FEATURES:
                row[fld] = c[fld]
            rows.append(row)
            if c["label"]:
                n_pos += 1
            else:
                n_neg += 1

    args.out.parent.mkdir(parents=True, exist_ok=True)
    with args.out.open("w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=["key", "label"] + FEATURES)
        w.writeheader()
        w.writerows(rows)
    print(f"files={n_files} ref={tot_ref} ref-covered-by-positive={cov_pos} "
          f"({cov_pos/max(tot_ref,1):.3f})")
    print(f"rows={len(rows)} pos={n_pos} neg={n_neg} out={args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
