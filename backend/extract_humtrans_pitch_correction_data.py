"""Extract note-level pitch-correction rows from HumTrans.

This targets the current 90% blocker: many notes have a good onset but the
chosen MIDI pitch is off by a semitone. Rows are one onset-matched predicted
note with the reference pitch delta as the label.
"""
from __future__ import annotations

import argparse
import csv
from pathlib import Path

from app.schemas import AnalyzeOptions
from app.scales import scale_pitch_classes
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
    return 0


def _candidate_key_features(pitch: int, tonic: str, scale: str) -> dict[str, int]:
    if not tonic or not scale or scale == "chromatic":
        return {
            "pitch_in_detected_key": 1,
            "plus1_in_detected_key": 1,
            "minus1_in_detected_key": 1,
        }
    try:
        pcs = set(scale_pitch_classes(tonic, scale))
    except Exception:
        return {
            "pitch_in_detected_key": 0,
            "plus1_in_detected_key": 0,
            "minus1_in_detected_key": 0,
        }
    return {
        "pitch_in_detected_key": int(pitch % 12 in pcs),
        "plus1_in_detected_key": int((pitch + 1) % 12 in pcs),
        "minus1_in_detected_key": int((pitch - 1) % 12 in pcs),
    }


def main() -> int:
    ap = argparse.ArgumentParser(description="Extract HumTrans pitch-correction CSV.")
    ap.add_argument("--root", type=Path, required=True)
    ap.add_argument("--split", choices=["train", "dev", "test"], default="train")
    ap.add_argument("--train-ratio", type=float, default=0.80)
    ap.add_argument("--dev-ratio", type=float, default=0.10)
    ap.add_argument("--seed", type=int, default=20260605)
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--offset", type=int, default=0)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--onset-tol", type=float, default=0.12)
    ap.add_argument("--pitch-model", choices=["pyin", "crepe"], default="pyin")
    ap.add_argument("--no-auto-key", action="store_true")
    ap.add_argument("--no-pitch-assistant", action="store_true")
    ap.add_argument("--assist-aggressive", dest="assist_aggressive", action="store_true", default=True)
    ap.add_argument("--no-assist-aggressive", dest="assist_aggressive", action="store_false")
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
        timing_refine=True,
        timing_grid_quantize=False,
        learned_pitch_correction=False,
        learned_offset_correction=False,
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
            pred, meta = predicted_notes(pair.wav, opts)
            pred = shift_notes(pred, estimate_time_shift(ref, pred, 0))
            matches, _, _ = match_onsets(ref, pred, args.onset_tol, 0)
        except Exception as exc:
            print(f"{pair.key} failed: {exc}")
            continue
        for i, (r, p) in enumerate(matches):
            prev_pitch = matches[i - 1][1].pitch if i > 0 else p.pitch
            next_pitch = matches[i + 1][1].pitch if i + 1 < len(matches) else p.pitch
            pitch_raw = float(p.pitch_raw if p.pitch_raw is not None else p.pitch)
            detected = meta.get("detected_key") or {}
            tonic = str(detected.get("tonic") or "")
            scale = str(detected.get("scale") or "")
            key_features = _candidate_key_features(int(p.pitch), tonic, scale)
            raw_delta_from_pitch = pitch_raw - float(p.pitch)
            rows.append(
                {
                    "key": pair.key,
                    "ref_pitch": int(r.pitch),
                    "pred_pitch": int(p.pitch),
                    "pitch_delta": int(r.pitch - p.pitch),
                    "pitch_raw": round(pitch_raw, 5),
                    "pitch_raw_frac": round(pitch_raw - int(pitch_raw), 5),
                    "raw_delta_from_pitch": round(raw_delta_from_pitch, 5),
                    "raw_abs_delta_from_pitch": round(abs(raw_delta_from_pitch), 5),
                    "pitch_original": int(p.pitch_original if p.pitch_original is not None else p.pitch),
                    "confidence": float(p.confidence or 0.0),
                    "voiced_ratio": float(p.voiced_ratio or 0.0),
                    "duration": float(p.duration),
                    "pitch_class": int(p.pitch % 12),
                    "prev_interval": int(p.pitch - prev_pitch),
                    "next_interval": int(next_pitch - p.pitch),
                    "assisted": int(bool(p.assisted)),
                    "source": _source_id(p.source),
                    "in_key": int(bool(p.in_key)),
                    **key_features,
                    "detected_tonic": tonic,
                    "detected_scale": scale,
                }
            )
        print(f"{pair.key}: onset_matches={len(matches)}")

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
