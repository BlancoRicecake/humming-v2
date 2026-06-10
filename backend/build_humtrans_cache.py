"""Build per-file HumTrans analyzer caches.

The cache lets later model experiments reuse analyzer output without decoding
and pitch-tracking every WAV again.
"""
from __future__ import annotations

import argparse
import json
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

import numpy as np

from app.schemas import AnalyzeOptions
from eval_humtrans import (
    Pair,
    best_global_pitch_shift,
    cache_file_path,
    choose_pairs,
    estimate_time_shift,
    find_pairs,
    note_to_dict,
    predicted_notes,
    read_midi_notes,
    write_cache_file,
)


def _onset_proxy(rms: list[float]) -> list[float]:
    values = np.asarray(rms, dtype=np.float32)
    if values.size < 2:
        return [0.0 for _ in rms]
    onset = np.maximum(0.0, np.diff(values, prepend=values[0])).astype(np.float32)
    hi = float(np.percentile(onset, 95)) if onset.size else 0.0
    if hi > 1e-9:
        onset = np.clip(onset / hi, 0.0, 1.0)
    return [float(x) for x in onset.tolist()]


def _options(args: argparse.Namespace) -> AnalyzeOptions:
    return AnalyzeOptions(
        pitch_model=args.pitch_model,
        auto_key=not args.no_auto_key,
        pitch_assistant=not args.no_pitch_assistant,
        assist_aggressive=args.assist_aggressive,
        learned_pitch_correction=not args.no_learned_pitch_correction,
        learned_offset_correction=bool(args.enable_learned_offset_correction),
        timing_refine=not args.no_timing_refine,
        timing_grid_quantize=False,
        quantize_strength=args.backend_quantize_strength,
        tempo_bpm=args.tempo_bpm,
        timing_attack_lookback_sec=args.timing_attack_lookback_sec,
        timing_max_advance_sec=args.timing_max_advance_sec,
        timing_max_delay_sec=args.timing_max_delay_sec,
        timing_fill_gaps=not args.no_timing_fill_gaps,
        timing_fill_max_gap_sec=args.timing_fill_max_gap_sec,
    )


def _model_dict(opts: AnalyzeOptions) -> dict[str, object]:
    if hasattr(opts, "model_dump"):
        return opts.model_dump()
    return opts.dict()


def _build_one(pair: Pair, split: str, args: argparse.Namespace) -> tuple[str, str]:
    out_path = cache_file_path(args.cache_dir, split, pair.key)
    if out_path.is_file() and not args.rebuild:
        return pair.key, "skip"

    opts = _options(args)
    ref = read_midi_notes(pair.midi, min_dur=args.min_ref_dur)
    pred, meta = predicted_notes(pair.wav, opts)
    rms = list(meta.get("envelope_rms", []) or [])
    meta["onset_proxy"] = _onset_proxy(rms)
    pitch_shift = best_global_pitch_shift(ref, pred) if args.normalize_key else 0
    time_shift = estimate_time_shift(ref, pred, pitch_shift) if args.align_time else 0.0
    payload = {
        "cache_version": 1,
        "key": pair.key,
        "split": split,
        "wav": pair.wav.label(),
        "midi": pair.midi.label(),
        "analyzer_options": _model_dict(opts),
        "alignment": {
            "pitch_shift_st": int(pitch_shift),
            "time_shift_sec": float(time_shift),
        },
        "ref_notes": [note_to_dict(n) for n in ref],
        "pred_notes": [note_to_dict(n) for n in pred],
        "analysis_meta": meta,
    }
    write_cache_file(out_path, payload)
    return pair.key, "write"


def main() -> int:
    ap = argparse.ArgumentParser(description="Build HumTrans analyzer cache files.")
    ap.add_argument("--root", type=Path, required=True)
    ap.add_argument("--cache-dir", type=Path)
    ap.add_argument("--split", choices=["all", "train", "dev", "test"], default="dev")
    ap.add_argument("--split-manifest-csv", type=Path)
    ap.add_argument("--train-ratio", type=float, default=0.80)
    ap.add_argument("--dev-ratio", type=float, default=0.10)
    ap.add_argument("--seed", type=int, default=20260605)
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--offset", type=int, default=0)
    ap.add_argument("--workers", type=int, default=1)
    ap.add_argument("--rebuild", action="store_true")
    ap.add_argument("--pitch-model", choices=["pyin", "crepe"], default="pyin")
    ap.add_argument("--tempo-bpm", type=float, default=90.0)
    ap.add_argument("--backend-quantize-strength", type=float, default=0.45)
    ap.add_argument("--no-auto-key", action="store_true")
    ap.add_argument("--no-pitch-assistant", action="store_true")
    ap.add_argument("--assist-aggressive", dest="assist_aggressive", action="store_true", default=True)
    ap.add_argument("--no-assist-aggressive", dest="assist_aggressive", action="store_false")
    ap.add_argument("--no-learned-pitch-correction", action="store_true")
    ap.add_argument("--enable-learned-offset-correction", action="store_true")
    ap.add_argument("--no-timing-refine", action="store_true")
    ap.add_argument("--timing-attack-lookback-sec", type=float, default=0.24)
    ap.add_argument("--timing-max-advance-sec", type=float, default=0.28)
    ap.add_argument("--timing-max-delay-sec", type=float, default=0.06)
    ap.add_argument("--no-timing-fill-gaps", action="store_true")
    ap.add_argument("--timing-fill-max-gap-sec", type=float, default=0.50)
    ap.add_argument("--normalize-key", action="store_true")
    ap.add_argument("--align-time", action="store_true")
    ap.add_argument("--min-ref-dur", type=float, default=0.03)
    args = ap.parse_args()

    if args.cache_dir is None:
        args.cache_dir = args.root / "cache" / "v1"

    all_pairs = find_pairs(args.root, None, None, None, None)
    pairs, split_by_key, active_manifest = choose_pairs(all_pairs, args)
    if args.offset:
        pairs = pairs[args.offset:]
    if args.limit > 0:
        pairs = pairs[: args.limit]
    if not pairs:
        raise SystemExit("No pairs selected.")

    print(
        json.dumps(
            {
                "cache_dir": str(args.cache_dir),
                "split": args.split,
                "pairs": len(pairs),
                "manifest": active_manifest,
                "workers": args.workers,
            },
            ensure_ascii=False,
        )
    )
    counts = {"write": 0, "skip": 0, "fail": 0}
    with ThreadPoolExecutor(max_workers=max(1, int(args.workers))) as pool:
        futures = {
            pool.submit(_build_one, pair, split_by_key.get(pair.key, args.split), args): pair
            for pair in pairs
        }
        for i, fut in enumerate(as_completed(futures), 1):
            pair = futures[fut]
            try:
                key, status = fut.result()
            except Exception as exc:
                counts["fail"] += 1
                print(f"[{i:04d}/{len(futures):04d}] {pair.key} fail {exc}")
                continue
            counts[status] += 1
            print(f"[{i:04d}/{len(futures):04d}] {key} {status}")
    print(json.dumps(counts, ensure_ascii=False))
    return 0 if counts["fail"] == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
