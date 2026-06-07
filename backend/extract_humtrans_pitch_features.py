"""Extract onset-matched pitch-correction rows from HumTrans.

Each row is one predicted note that matched a reference note by onset. This
turns the current analyzer's pitch errors into a supervised table for tuning
and future model training.
"""
from __future__ import annotations

import argparse
import csv
import statistics
from pathlib import Path

from app.schemas import AnalyzeOptions
from app.scales import scale_pitch_classes
from eval_humtrans import (
    best_global_pitch_shift,
    estimate_time_shift,
    find_pairs,
    match_onsets,
    predicted_notes,
    read_midi_notes,
    shift_notes,
    split_pairs,
)


def _note_name(pitch: int) -> str:
    names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    return f"{names[pitch % 12]}{pitch // 12 - 1}"


def _in_key(pitch: int, tonic: str | None, scale: str | None) -> bool | None:
    if not tonic or not scale or scale == "chromatic":
        return None
    return pitch % 12 in set(scale_pitch_classes(tonic, scale))


def extract_pair(pair, args: argparse.Namespace) -> list[dict[str, object]]:
    opts = AnalyzeOptions(
        pitch_model=args.pitch_model,
        auto_key=not args.no_auto_key,
        pitch_assistant=not args.no_pitch_assistant,
        assist_aggressive=not args.no_assist_aggressive,
        timing_refine=not args.no_timing_refine,
        timing_attack_lookback_sec=args.timing_attack_lookback_sec,
        timing_max_advance_sec=args.timing_max_advance_sec,
        timing_max_delay_sec=args.timing_max_delay_sec,
        timing_fill_gaps=not args.no_timing_fill_gaps,
        timing_fill_max_gap_sec=args.timing_fill_max_gap_sec,
    )
    ref = read_midi_notes(pair.midi, min_dur=args.min_ref_dur)
    pred, meta = predicted_notes(pair.wav, opts)
    pitch_shift = best_global_pitch_shift(ref, pred) if args.normalize_key else 0
    time_shift = estimate_time_shift(ref, pred, pitch_shift) if args.align_time else 0.0
    pred = shift_notes(pred, time_shift)
    onset_matches, _, _ = match_onsets(ref, pred, args.onset_tol, pitch_shift)

    key = meta.get("detected_key") or {}
    tonic = key.get("tonic")
    scale = key.get("scale")
    out: list[dict[str, object]] = []
    for idx, (r, p) in enumerate(onset_matches):
        raw = float(p.pitch_raw) if p.pitch_raw is not None else float(p.pitch)
        original = int(p.pitch_original) if p.pitch_original is not None else int(round(raw))
        final = int(p.pitch)
        target = int(r.pitch)
        out.append(
            {
                "key": pair.key,
                "match_index": idx,
                "ref_pitch": target,
                "ref_name": _note_name(target),
                "pred_pitch": final,
                "pred_name": _note_name(final),
                "pitch_delta": final - target,
                "target_shift_from_pred": target - final,
                "raw_pitch": round(raw, 5),
                "raw_frac": round(raw - int(raw), 5),
                "pitch_original": original,
                "target_shift_from_original": target - original,
                "confidence": p.confidence if p.confidence is not None else "",
                "voiced_ratio": p.voiced_ratio if p.voiced_ratio is not None else "",
                "duration": p.duration,
                "onset_delta_ms": (p.start - r.start) * 1000.0,
                "offset_delta_ms": (p.end - r.end) * 1000.0,
                "assisted": p.assisted if p.assisted is not None else "",
                "source": p.source or "",
                "in_detected_key": p.in_key if p.in_key is not None else "",
                "detected_tonic": tonic or "",
                "detected_scale": scale or "",
                "detected_key_confidence": key.get("confidence", ""),
                "detected_key_tier": key.get("tier", ""),
                "final_in_key": _in_key(final, tonic, scale),
                "original_in_key": _in_key(original, tonic, scale),
                "target_in_key": _in_key(target, tonic, scale),
            }
        )
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description="Extract HumTrans pitch-correction rows.")
    ap.add_argument("--root", type=Path, required=True)
    ap.add_argument("--split", choices=["all", "train", "dev", "test"], default="all")
    ap.add_argument("--train-ratio", type=float, default=0.80)
    ap.add_argument("--dev-ratio", type=float, default=0.10)
    ap.add_argument("--seed", type=int, default=20260605)
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--offset", type=int, default=0)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--pitch-model", choices=["pyin", "crepe"], default="pyin")
    ap.add_argument("--tempo-bpm", type=int, default=90)
    ap.add_argument("--backend-quantize-strength", type=float, default=0.45)
    ap.add_argument("--no-auto-key", action="store_true")
    ap.add_argument("--no-pitch-assistant", action="store_true")
    ap.add_argument("--no-assist-aggressive", action="store_true")
    ap.add_argument("--no-timing-refine", action="store_true")
    ap.add_argument("--timing-attack-lookback-sec", type=float, default=0.24)
    ap.add_argument("--timing-max-advance-sec", type=float, default=0.28)
    ap.add_argument("--timing-max-delay-sec", type=float, default=0.06)
    ap.add_argument("--no-timing-fill-gaps", action="store_true")
    ap.add_argument("--timing-fill-max-gap-sec", type=float, default=0.50)
    ap.add_argument("--normalize-key", action="store_true")
    ap.add_argument("--align-time", action="store_true", default=True)
    ap.add_argument("--onset-tol", type=float, default=0.12)
    ap.add_argument("--offset-tol", type=float, default=0.18)
    ap.add_argument("--pitch-tol", type=int, default=0)
    ap.add_argument("--frame-hop", type=float, default=0.02)
    ap.add_argument("--frame-pitch-tol", type=float, default=0.5)
    ap.add_argument("--min-ref-dur", type=float, default=0.03)
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

    rows: list[dict[str, object]] = []
    for i, pair in enumerate(pairs, 1):
        try:
            item = extract_pair(pair, args)
            rows.extend(item)
            acc = statistics.fmean(1.0 if int(r["pitch_delta"]) == 0 else 0.0 for r in item) if item else 0.0
            print(f"[{i:04d}/{len(pairs):04d}] {pair.key} rows={len(item)} pitch_acc={acc:.3f}")
        except Exception as exc:
            print(f"[{i:04d}/{len(pairs):04d}] {pair.key} failed: {exc}")

    if not rows:
        raise SystemExit("No rows extracted.")
    args.out.parent.mkdir(parents=True, exist_ok=True)
    with args.out.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)
    acc = statistics.fmean(1.0 if int(r["pitch_delta"]) == 0 else 0.0 for r in rows)
    print("=" * 78)
    print(f"rows      : {len(rows)}")
    print(f"pitch acc : {acc:.3f}")
    print(f"out       : {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
