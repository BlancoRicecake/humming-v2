"""Extract note-level offset correction rows from HumTrans.

Rows are onset+pitch matched predicted notes. The label is the target end-time
delta (reference end - predicted end), which lets us train a conservative
offset/duration correction model without changing note count.
"""
from __future__ import annotations

import argparse
import csv
from pathlib import Path

from app.schemas import AnalyzeOptions
from eval_humtrans import (
    estimate_time_shift,
    find_pairs,
    match_onsets,
    predicted_notes,
    read_midi_notes,
    shift_notes,
    split_pairs,
)


def _source_id(value: str | None) -> int:
    if value == "assistant":
        return 1
    if value == "user":
        return 2
    if value == "model":
        return 3
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="Extract HumTrans offset-correction CSV.")
    ap.add_argument("--root", type=Path, required=True)
    ap.add_argument("--split", choices=["train", "dev", "test"], default="train")
    ap.add_argument("--train-ratio", type=float, default=0.80)
    ap.add_argument("--dev-ratio", type=float, default=0.10)
    ap.add_argument("--seed", type=int, default=20260605)
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--offset", type=int, default=0)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--onset-tol", type=float, default=0.12)
    ap.add_argument("--pitch-tol", type=int, default=0)
    ap.add_argument("--pitch-model", choices=["pyin", "crepe"], default="pyin")
    ap.add_argument("--no-auto-key", action="store_true")
    ap.add_argument("--no-pitch-assistant", action="store_true")
    ap.add_argument("--assist-aggressive", dest="assist_aggressive", action="store_true", default=True)
    ap.add_argument("--no-assist-aggressive", dest="assist_aggressive", action="store_false")
    ap.add_argument("--no-learned-pitch-correction", action="store_true")
    ap.add_argument("--backend-quantize-strength", type=float, default=0.45)
    ap.add_argument("--tempo-bpm", type=float, default=90.0)
    ap.add_argument("--timing-attack-lookback-sec", type=float, default=0.24)
    ap.add_argument("--no-timing-fill-gaps", action="store_true")
    ap.add_argument("--timing-fill-max-gap-sec", type=float, default=0.50)
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
        auto_key=not args.no_auto_key,
        pitch_assistant=not args.no_pitch_assistant,
        assist_aggressive=args.assist_aggressive,
        learned_pitch_correction=not args.no_learned_pitch_correction,
        learned_offset_correction=False,
        timing_refine=True,
        timing_grid_quantize=False,
        quantize_strength=args.backend_quantize_strength,
        tempo_bpm=args.tempo_bpm,
        timing_attack_lookback_sec=args.timing_attack_lookback_sec,
        timing_fill_gaps=not args.no_timing_fill_gaps,
        timing_fill_max_gap_sec=args.timing_fill_max_gap_sec,
    )
    rows: list[dict[str, object]] = []
    for pair in pairs:
        try:
            ref = read_midi_notes(pair.midi)
            pred, _meta = predicted_notes(pair.wav, opts)
            pred = shift_notes(pred, estimate_time_shift(ref, pred, 0))
            onset_matches, _, _ = match_onsets(ref, pred, args.onset_tol, 0)
        except Exception as exc:
            print(f"{pair.key} failed: {exc}")
            continue
        kept = 0
        for i, (r, p) in enumerate(onset_matches):
            if abs(int(r.pitch) - int(p.pitch)) > args.pitch_tol:
                continue
            prev_p = onset_matches[i - 1][1] if i > 0 else p
            next_p = onset_matches[i + 1][1] if i + 1 < len(onset_matches) else p
            next_gap = float(next_p.start - p.end) if i + 1 < len(onset_matches) else 999.0
            prev_gap = float(p.start - prev_p.end) if i > 0 else 999.0
            target_delta = float(r.end - p.end)
            pitch_raw = float(p.pitch_raw if p.pitch_raw is not None else p.pitch)
            rows.append(
                {
                    "key": pair.key,
                    "ref_start": float(r.start),
                    "ref_end": float(r.end),
                    "pred_start": float(p.start),
                    "pred_end": float(p.end),
                    "target_delta": target_delta,
                    "target_delta_ms": target_delta * 1000.0,
                    "offset_ok": int(abs(target_delta) <= 0.18),
                    "pred_duration": float(p.duration),
                    "ref_duration": float(r.duration),
                    "start_delta": float(r.start - p.start),
                    "pitch": int(p.pitch),
                    "pitch_class": int(p.pitch % 12),
                    "pitch_raw_delta": pitch_raw - float(p.pitch),
                    "confidence": float(p.confidence or 0.0),
                    "voiced_ratio": float(p.voiced_ratio or 0.0),
                    "prev_gap": prev_gap,
                    "next_gap": next_gap,
                    "prev_interval": int(p.pitch - prev_p.pitch),
                    "next_interval": int(next_p.pitch - p.pitch),
                    "is_first": int(i == 0),
                    "is_last": int(i + 1 == len(onset_matches)),
                    "assisted": int(bool(p.assisted)),
                    "source": _source_id(p.source),
                    "in_key": int(bool(p.in_key)),
                }
            )
            kept += 1
        print(f"{pair.key}: offset_rows={kept}")

    if not rows:
        raise SystemExit("No rows extracted.")
    args.out.parent.mkdir(parents=True, exist_ok=True)
    with args.out.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)
    print(f"rows={len(rows)} out={args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
