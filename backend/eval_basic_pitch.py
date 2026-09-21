"""Compare Basic Pitch with HumTrack metrics on paired HumTrans WAV/MIDI data.

This script is deliberately research-only. It never changes app configuration.
Example:
  python eval_basic_pitch.py --root D:/datasets/HumTrans --limit 30
"""
from __future__ import annotations

import argparse
import csv
import json
import tempfile
import time
from pathlib import Path

from basic_pitch.inference import predict

from eval_humtrans import (
    MidiNote,
    best_global_pitch_shift,
    find_pairs,
    match_notes,
    read_midi_notes,
)


def _f1(matches: int, reference: int, predicted: int) -> tuple[float, float, float]:
    precision = matches / predicted if predicted else 0.0
    recall = matches / reference if reference else 0.0
    f1 = 2 * precision * recall / (precision + recall) if precision + recall else 0.0
    return precision, recall, f1


def _basic_pitch_notes(wav_bytes: bytes) -> list[MidiNote]:
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as handle:
        handle.write(wav_bytes)
        path = Path(handle.name)
    try:
        _, _, events = predict(str(path))
    finally:
        path.unlink(missing_ok=True)
    return [
        MidiNote(
            start=float(event[0]),
            end=float(event[1]),
            pitch=int(event[2]),
            velocity=max(1, min(127, int(round(float(event[3]) * 127)))),
        )
        for event in events
        if len(event) >= 4 and float(event[1]) > float(event[0])
    ]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path)
    parser.add_argument("--wav-dir", type=Path)
    parser.add_argument("--midi-dir", type=Path)
    parser.add_argument("--limit", type=int, default=30)
    parser.add_argument("--normalize-key", action="store_true")
    parser.add_argument("--onset-tol", type=float, default=0.12)
    parser.add_argument("--offset-tol", type=float, default=0.18)
    parser.add_argument("--pitch-tol", type=int, default=0)
    parser.add_argument("--csv", type=Path, default=Path("basic_pitch_eval.csv"))
    parser.add_argument("--summary-json", type=Path, default=Path("basic_pitch_summary.json"))
    args = parser.parse_args()

    pairs = find_pairs(args.root, args.wav_dir, args.midi_dir, None, None)
    if args.limit > 0:
        pairs = pairs[: args.limit]
    if not pairs:
        parser.error("no paired WAV/MIDI files found")

    rows: list[dict] = []
    for pair in pairs:
        started = time.perf_counter()
        reference = read_midi_notes(pair.midi)
        predicted = _basic_pitch_notes(pair.wav.read_bytes())
        shift = best_global_pitch_shift(reference, predicted) if args.normalize_key else 0
        matches, _, _ = match_notes(
            reference,
            predicted,
            args.onset_tol,
            args.offset_tol,
            args.pitch_tol,
            shift,
        )
        precision, recall, f1 = _f1(len(matches), len(reference), len(predicted))
        rows.append(
            {
                "key": pair.key,
                "reference_notes": len(reference),
                "predicted_notes": len(predicted),
                "precision": precision,
                "recall": recall,
                "note_f1": f1,
                "pitch_shift": shift,
                "elapsed_sec": time.perf_counter() - started,
            }
        )
        print(f"{pair.key}: F1={f1:.4f} notes={len(predicted)}")

    args.csv.parent.mkdir(parents=True, exist_ok=True)
    with args.csv.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=rows[0].keys())
        writer.writeheader()
        writer.writerows(rows)
    summary = {
        "engine": "basic-pitch",
        "files": len(rows),
        "macro_note_f1": sum(row["note_f1"] for row in rows) / len(rows),
        "mean_elapsed_sec": sum(row["elapsed_sec"] for row in rows) / len(rows),
        "decision_rule": (
            "Promote only if held-out note F1 improves materially without "
            "regressing onset quality or interactive latency."
        ),
    }
    args.summary_json.write_text(
        json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
