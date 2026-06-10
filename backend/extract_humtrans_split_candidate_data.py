"""Extract note-internal split-candidate rows from HumTrans.

This targets the next structural bottleneck: predicted notes that contain one
or more hidden reference note boundaries. Rows are candidate times inside
predicted notes; the label is 1 when the candidate is close to a MIDI onset
inside that predicted note.
"""
from __future__ import annotations

import argparse
import csv
from pathlib import Path

import numpy as np

from app.analyze import analyze_audio
from app.schemas import AnalyzeOptions
from eval_humtrans import (
    Pair,
    estimate_time_shift,
    find_pairs,
    read_midi_notes,
    shift_notes,
    split_pairs,
)


def _safe_arr(values: list[float]) -> np.ndarray:
    return np.asarray([float(v) for v in values], dtype=np.float32)


def _interp(times: np.ndarray, values: np.ndarray, t: float, fill: float = 0.0) -> float:
    if times.size == 0 or values.size == 0:
        return fill
    vals = np.nan_to_num(values, nan=fill, posinf=fill, neginf=fill)
    return float(np.interp(t, times, vals, left=fill, right=fill))


def _window(values_t: np.ndarray, values: np.ndarray, start: float, end: float) -> np.ndarray:
    if values_t.size == 0:
        return np.zeros(0, dtype=np.float32)
    idx = np.where((values_t >= start) & (values_t <= end))[0]
    if idx.size == 0:
        return np.zeros(0, dtype=np.float32)
    return values[idx]


def _median_finite(a: np.ndarray, default: float = 0.0) -> float:
    a = a[np.isfinite(a)]
    return float(np.median(a)) if a.size else default


def _std_finite(a: np.ndarray, default: float = 0.0) -> float:
    a = a[np.isfinite(a)]
    return float(np.std(a)) if a.size else default


def _extract_pair(pair: Pair, args: argparse.Namespace, opts: AnalyzeOptions) -> list[dict[str, object]]:
    ref = read_midi_notes(pair.midi)
    res = analyze_audio(pair.wav.read_bytes(), opts)
    pred = [
        n
        for n in res.notes
        if n.kind == "pitched" and float(n.end) > float(n.start)
    ]
    # Use the same global time alignment as current benchmark. Candidate labels
    # are about internal boundaries, not leading silence.
    pred_notes_for_shift = [
        type("N", (), {"start": float(n.start), "end": float(n.end), "pitch": int(n.pitch)})()
        for n in pred
    ]
    time_shift = estimate_time_shift(ref, pred_notes_for_shift, 0)

    env_t = _safe_arr(res.envelope.times) + float(time_shift)
    rms = _safe_arr(res.envelope.rms)
    pitch_t = _safe_arr(res.pitch_track.times) + float(time_shift)
    pitch_midi = _safe_arr(res.pitch_track.midi)
    voiced = _safe_arr(res.pitch_track.voiced_prob)
    onset = np.zeros_like(rms)
    if rms.size >= 2:
        onset = np.maximum(0.0, np.diff(rms, prepend=rms[0])).astype(np.float32)
        hi = float(np.percentile(onset, 95)) if onset.size else 0.0
        if hi > 1e-9:
            onset = np.clip(onset / hi, 0.0, 1.0)

    ref_onsets = np.asarray([float(n.start) for n in ref], dtype=np.float32)
    rows: list[dict[str, object]] = []
    for note_i, n in enumerate(pred):
        n_start = float(n.start) + float(time_shift)
        n_end = float(n.end) + float(time_shift)
        dur = n_end - n_start
        if dur < args.min_note_dur:
            continue
        cand_start = n_start + args.edge_margin
        cand_end = n_end - args.edge_margin
        if cand_end <= cand_start:
            continue
        candidates = pitch_t[(pitch_t >= cand_start) & (pitch_t <= cand_end)]
        if candidates.size == 0:
            step = args.candidate_hop
            candidates = np.arange(cand_start, cand_end + step * 0.5, step, dtype=np.float32)
        internal_ref = ref_onsets[(ref_onsets >= cand_start) & (ref_onsets <= cand_end)]
        for t in candidates:
            t = float(t)
            label = int(np.any(np.abs(internal_ref - t) <= args.label_radius))
            left_m = _window(pitch_t, pitch_midi, t - args.context_sec, t - 0.015)
            right_m = _window(pitch_t, pitch_midi, t + 0.015, t + args.context_sec)
            left_v = _window(pitch_t, voiced, t - args.context_sec, t - 0.015)
            right_v = _window(pitch_t, voiced, t + 0.015, t + args.context_sec)
            local_rms = _window(env_t, rms, t - args.context_sec, t + args.context_sec)
            left_rms = _window(env_t, rms, t - args.context_sec, t - 0.015)
            right_rms = _window(env_t, rms, t + 0.015, t + args.context_sec)
            lm = _median_finite(left_m, float(n.pitch))
            rm = _median_finite(right_m, float(n.pitch))
            lv = _median_finite(left_v, 0.0)
            rv = _median_finite(right_v, 0.0)
            rms_here = _interp(env_t, rms, t)
            rms_med = float(np.median(local_rms)) if local_rms.size else rms_here
            rms_min = float(np.min(local_rms)) if local_rms.size else rms_here
            onset_here = _interp(env_t, onset, t)
            rms_min_ratio = rms_min / max(rms_med, 1e-7)
            pitch_abs_delta = abs(rm - lm)
            voiced_delta = rv - lv
            salient = (
                onset_here >= args.min_onset
                or rms_min_ratio <= args.max_rms_min_ratio
                or pitch_abs_delta >= args.min_pitch_delta
                or abs(voiced_delta) >= args.min_voiced_delta
            )
            if args.salient_only and not label and not salient:
                continue
            rows.append(
                {
                    "key": pair.key,
                    "note_index": note_i,
                    "candidate_time": t,
                    "label": label,
                    "salient": int(salient),
                    "note_start": n_start,
                    "note_end": n_end,
                    "note_duration": dur,
                    "pos_ratio": (t - n_start) / max(dur, 1e-6),
                    "time_from_start": t - n_start,
                    "time_to_end": n_end - t,
                    "note_pitch": int(n.pitch),
                    "note_confidence": float(n.confidence),
                    "note_voiced_ratio": float(n.voiced_ratio),
                    "rms_here": rms_here,
                    "rms_min_ratio": rms_min_ratio,
                    "rms_left": float(np.median(left_rms)) if left_rms.size else rms_here,
                    "rms_right": float(np.median(right_rms)) if right_rms.size else rms_here,
                    "onset_here": onset_here,
                    "pitch_left": lm,
                    "pitch_right": rm,
                    "pitch_delta_lr": rm - lm,
                    "pitch_abs_delta_lr": pitch_abs_delta,
                    "pitch_std_left": _std_finite(left_m),
                    "pitch_std_right": _std_finite(right_m),
                    "voiced_left": lv,
                    "voiced_right": rv,
                    "voiced_delta": voiced_delta,
                    "same_rounded_pitch": int(round(lm) == round(rm)),
                }
            )
    return rows


def main() -> int:
    ap = argparse.ArgumentParser(description="Extract split-candidate training rows.")
    ap.add_argument("--root", type=Path, required=True)
    ap.add_argument("--split", choices=["train", "dev", "test"], default="train")
    ap.add_argument("--train-ratio", type=float, default=0.80)
    ap.add_argument("--dev-ratio", type=float, default=0.10)
    ap.add_argument("--seed", type=int, default=20260605)
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--offset", type=int, default=0)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--pitch-model", choices=["pyin", "crepe"], default="pyin")
    ap.add_argument("--candidate-hop", type=float, default=0.02)
    ap.add_argument("--label-radius", type=float, default=0.04)
    ap.add_argument("--context-sec", type=float, default=0.08)
    ap.add_argument("--edge-margin", type=float, default=0.055)
    ap.add_argument("--min-note-dur", type=float, default=0.16)
    ap.add_argument("--salient-only", action="store_true", default=True)
    ap.add_argument("--all-candidates", dest="salient_only", action="store_false")
    ap.add_argument("--min-onset", type=float, default=0.08)
    ap.add_argument("--max-rms-min-ratio", type=float, default=0.82)
    ap.add_argument("--min-pitch-delta", type=float, default=0.45)
    ap.add_argument("--min-voiced-delta", type=float, default=0.25)
    args = ap.parse_args()

    pairs, _ = split_pairs(
        find_pairs(args.root, None, None, None, None),
        args.split,
        args.train_ratio,
        args.dev_ratio,
        args.seed,
    )
    if args.offset:
        pairs = pairs[args.offset:]
    if args.limit > 0:
        pairs = pairs[: args.limit]
    if not pairs:
        raise SystemExit("No pairs selected.")

    opts = AnalyzeOptions(
        pitch_model=args.pitch_model,
        timing_refine=True,
        timing_grid_quantize=False,
        learned_pitch_correction=True,
    )
    rows: list[dict[str, object]] = []
    for pair in pairs:
        try:
            item = _extract_pair(pair, args, opts)
        except Exception as exc:
            print(f"{pair.key} failed: {exc}")
            continue
        rows.extend(item)
        positives = sum(int(r["label"]) for r in item)
        print(f"{pair.key}: candidates={len(item)} positives={positives}")

    if not rows:
        raise SystemExit("No rows extracted.")
    args.out.parent.mkdir(parents=True, exist_ok=True)
    with args.out.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)
    print(f"rows={len(rows)} positives={sum(int(r['label']) for r in rows)} out={args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
