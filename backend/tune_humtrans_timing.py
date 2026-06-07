"""Grid-search HumTrack timing options on a fixed HumTrans split.

This is intentionally small and deterministic. It tunes on the dev split by
default, then the chosen settings must be confirmed on test before shipping.
"""
from __future__ import annotations

import argparse
import itertools
import json
import statistics
from pathlib import Path
from types import SimpleNamespace
from typing import Any

from eval_humtrans import eval_pair, find_pairs, split_pairs


def _float_list(raw: str) -> list[float]:
    return [float(x.strip()) for x in raw.split(",") if x.strip()]


def _mean(rows: list[dict[str, object]], key: str) -> float:
    vals = [float(row[key]) for row in rows]
    return statistics.fmean(vals) if vals else 0.0


def _base_args(args: argparse.Namespace, **overrides: Any) -> SimpleNamespace:
    data = {
        "pitch_model": args.pitch_model,
        "no_auto_key": args.no_auto_key,
        "no_pitch_assistant": args.no_pitch_assistant,
        "assist_aggressive": not args.no_assist_aggressive,
        "no_timing_refine": args.no_timing_refine,
        "backend_quantize_strength": args.backend_quantize_strength,
        "tempo_bpm": args.tempo_bpm,
        "normalize_key": args.normalize_key,
        "align_time": args.align_time,
        "onset_tol": args.onset_tol,
        "offset_tol": args.offset_tol,
        "pitch_tol": args.pitch_tol,
        "frame_hop": args.frame_hop,
        "frame_pitch_tol": args.frame_pitch_tol,
        "min_ref_dur": args.min_ref_dur,
        "details_dir": None,
        "timing_attack_lookback_sec": 0.24,
        "timing_max_advance_sec": 0.28,
        "timing_max_delay_sec": 0.06,
        "no_timing_fill_gaps": False,
        "timing_fill_max_gap_sec": 0.50,
    }
    data.update(overrides)
    return SimpleNamespace(**data)


def main() -> int:
    ap = argparse.ArgumentParser(description="Tune timing options on HumTrans.")
    ap.add_argument("--root", type=Path, required=True)
    ap.add_argument("--split", choices=["train", "dev", "test"], default="dev")
    ap.add_argument("--train-ratio", type=float, default=0.80)
    ap.add_argument("--dev-ratio", type=float, default=0.10)
    ap.add_argument("--seed", type=int, default=20260605)
    ap.add_argument("--limit", type=int, default=30)
    ap.add_argument("--offset", type=int, default=0)
    ap.add_argument("--out", type=Path, default=Path("humtrans_timing_tune.json"))
    ap.add_argument("--pitch-model", choices=["pyin", "crepe"], default="pyin")
    ap.add_argument("--tempo-bpm", type=int, default=90)
    ap.add_argument("--backend-quantize-strength", type=float, default=0.45)
    ap.add_argument("--no-auto-key", action="store_true")
    ap.add_argument("--no-pitch-assistant", action="store_true")
    ap.add_argument("--no-assist-aggressive", action="store_true")
    ap.add_argument("--no-timing-refine", action="store_true")
    ap.add_argument("--normalize-key", action="store_true")
    ap.add_argument("--align-time", action="store_true")
    ap.add_argument("--onset-tol", type=float, default=0.12)
    ap.add_argument("--offset-tol", type=float, default=0.18)
    ap.add_argument("--pitch-tol", type=int, default=0)
    ap.add_argument("--frame-hop", type=float, default=0.02)
    ap.add_argument("--frame-pitch-tol", type=float, default=0.5)
    ap.add_argument("--min-ref-dur", type=float, default=0.03)
    ap.add_argument("--lookbacks", default="0.18,0.24,0.30,0.36")
    ap.add_argument("--advances", default="0.12,0.18,0.24,0.30")
    ap.add_argument("--delays", default="0.04,0.06")
    ap.add_argument("--fill-gaps", default="true,false")
    ap.add_argument("--fill-max-gaps", default="0.10,0.14,0.18,0.24")
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

    fill_choices = [
        item.strip().lower() in {"1", "true", "yes", "on"}
        for item in args.fill_gaps.split(",")
        if item.strip()
    ]
    combos = list(
        itertools.product(
            _float_list(args.lookbacks),
            _float_list(args.advances),
            _float_list(args.delays),
            fill_choices,
            _float_list(args.fill_max_gaps),
        )
    )
    results: list[dict[str, object]] = []
    best: dict[str, object] | None = None
    for i, (lookback, advance, delay, fill_gaps, fill_max_gap) in enumerate(combos, 1):
        if fill_gaps is False and fill_max_gap != _float_list(args.fill_max_gaps)[0]:
            continue
        eval_args = _base_args(
            args,
            timing_attack_lookback_sec=lookback,
            timing_max_advance_sec=advance,
            timing_max_delay_sec=delay,
            no_timing_fill_gaps=not fill_gaps,
            timing_fill_max_gap_sec=fill_max_gap,
        )
        rows: list[dict[str, object]] = []
        for pair in pairs:
            try:
                rows.append(eval_pair(pair, eval_args))
            except Exception as exc:
                print(f"{pair.key} failed: {exc}")
        row = {
            "timing_attack_lookback_sec": lookback,
            "timing_max_advance_sec": advance,
            "timing_max_delay_sec": delay,
            "timing_fill_gaps": fill_gaps,
            "timing_fill_max_gap_sec": fill_max_gap,
            "pairs": len(rows),
            "note_precision": _mean(rows, "precision"),
            "note_recall": _mean(rows, "recall"),
            "note_f1": _mean(rows, "f1"),
            "onset_mae_ms": _mean(rows, "onset_mae_ms"),
            "duration_mae_ms": _mean(rows, "duration_mae_ms"),
            "frame_pitch_accuracy": _mean(rows, "frame_pitch_acc"),
            "frame_voice_recall": _mean(rows, "frame_voice_recall"),
            "frame_false_alarm": _mean(rows, "frame_false_alarm"),
        }
        results.append(row)
        if best is None or (
            float(row["note_f1"]),
            -float(row["onset_mae_ms"]),
            -float(row["duration_mae_ms"]),
        ) > (
            float(best["note_f1"]),
            -float(best["onset_mae_ms"]),
            -float(best["duration_mae_ms"]),
        ):
            best = row
        print(
            f"[{i:03d}/{len(combos):03d}] "
            f"F1={float(row['note_f1']):.3f} "
            f"P={float(row['note_precision']):.3f} R={float(row['note_recall']):.3f} "
            f"onset={float(row['onset_mae_ms']):.1f}ms "
            f"lookback={lookback:.2f} advance={advance:.2f} fill={fill_gaps}/{fill_max_gap:.2f}"
        )

    payload = {
        "split": args.split,
        "seed": args.seed,
        "limit": args.limit,
        "pairs": [p.key for p in pairs],
        "best": best,
        "results": sorted(results, key=lambda r: float(r["note_f1"]), reverse=True),
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(payload, indent=2), encoding="utf-8")
    print("=" * 78)
    print(f"best: {json.dumps(best, indent=2)}")
    print(f"out : {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
