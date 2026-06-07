"""Extract note-sequence candidate rows from HumTrans cache.

This is the training-data bridge for the next model direction: generate whole
note candidates from cached envelope/pitch evidence, then learn which candidates
belong in the final non-overlapping MIDI sequence.
"""
from __future__ import annotations

import argparse
import csv
import math
from pathlib import Path

import numpy as np

from app.scales import scale_pitch_classes
from eval_humtrans import (
    cache_file_path,
    note_from_dict,
    read_cache_file,
)


FIELDS = [
    "key",
    "candidate_index",
    "start",
    "end",
    "duration",
    "pitch",
    "label",
    "onset_strength",
    "end_onset_strength",
    "rms_mean",
    "rms_min_ratio",
    "pitch_stability",
    "voiced_ratio",
    "pitch_delta_prev",
    "pitch_delta_next",
    "in_key",
    "same_pitch_repeat_evidence",
]


def _arr(meta: dict[str, object], name: str) -> np.ndarray:
    return np.asarray(meta.get(name, []) or [], dtype=np.float32)


def _win(t: np.ndarray, v: np.ndarray, start: float, end: float) -> np.ndarray:
    if t.size == 0 or v.size == 0:
        return np.zeros(0, dtype=np.float32)
    idx = np.where((t >= start) & (t <= end))[0]
    return v[idx] if idx.size else np.zeros(0, dtype=np.float32)


def _interp(t: np.ndarray, v: np.ndarray, x: float, default: float = 0.0) -> float:
    if t.size == 0 or v.size == 0:
        return default
    vals = np.nan_to_num(v, nan=default, posinf=default, neginf=default)
    return float(np.interp(x, t, vals, left=default, right=default))


def _median_pitch(values: np.ndarray, default: int) -> int:
    values = values[np.isfinite(values)]
    if values.size == 0:
        return int(default)
    return int(math.floor(float(np.median(values)) + 0.5))


def _key_classes(meta: dict[str, object]) -> set[int] | None:
    detected = meta.get("detected_key") or {}
    if not isinstance(detected, dict):
        return None
    tonic = str(detected.get("tonic") or "")
    scale = str(detected.get("scale") or "")
    if not tonic or not scale or scale == "chromatic":
        return None
    try:
        return set(scale_pitch_classes(tonic, scale))
    except Exception:
        return None


def _boundary_candidates(meta: dict[str, object], pred_notes: list[object]) -> list[float]:
    env_t = _arr(meta, "envelope_times")
    onset = _arr(meta, "onset_proxy")
    pitch_t = _arr(meta, "pitch_times")
    pitch = _arr(meta, "pitch_midi")
    rms = _arr(meta, "envelope_rms")
    boundaries = {0.0}
    for n in pred_notes:
        boundaries.add(float(n.start))
        boundaries.add(float(n.end))
    if env_t.size and onset.size:
        for t in env_t[onset >= 0.25]:
            boundaries.add(float(t))
    if pitch_t.size and pitch.size >= 3:
        clean = np.nan_to_num(pitch, nan=np.nan)
        for i in range(1, len(clean)):
            a = clean[i - 1]
            b = clean[i]
            if np.isfinite(a) and np.isfinite(b) and abs(float(b - a)) >= 0.70:
                boundaries.add(float(pitch_t[i]))
    if env_t.size and rms.size >= 3:
        med = float(np.median(rms))
        for i in range(1, len(rms) - 1):
            if rms[i] <= rms[i - 1] and rms[i] <= rms[i + 1] and rms[i] <= med * 0.82:
                boundaries.add(float(env_t[i]))
    return sorted(t for t in boundaries if t >= 0.0)


def _label(start: float, end: float, pitch: int, ref_notes: list[object], onset_tol: float, offset_tol: float) -> int:
    for r in ref_notes:
        if (
            abs(float(r.start) - start) <= onset_tol
            and abs(float(r.end) - end) <= offset_tol
            and int(r.pitch) == int(pitch)
        ):
            return 1
    return 0


def _rows_for_cache(path: Path, args: argparse.Namespace) -> list[dict[str, object]]:
    data = read_cache_file(path)
    key = str(data.get("key") or path.stem)
    ref_notes = [note_from_dict(x) for x in data.get("ref_notes", [])]
    pred_notes = [note_from_dict(x) for x in data.get("pred_notes", [])]
    meta = dict(data.get("analysis_meta", {}))
    env_t = _arr(meta, "envelope_times")
    rms = _arr(meta, "envelope_rms")
    onset = _arr(meta, "onset_proxy")
    pitch_t = _arr(meta, "pitch_times")
    pitch_midi = _arr(meta, "pitch_midi")
    voiced = _arr(meta, "voiced_prob")
    key_classes = _key_classes(meta)
    boundaries = _boundary_candidates(meta, pred_notes)
    rows: list[dict[str, object]] = []
    for i in range(len(boundaries) - 1):
        for j in range(i + 1, min(len(boundaries), i + 1 + args.max_boundary_span)):
            start = float(boundaries[i])
            end = float(boundaries[j])
            duration = end - start
            if duration < args.min_duration or duration > args.max_duration:
                continue
            pitch_values = _win(pitch_t, pitch_midi, start, end)
            default_pitch = pred_notes[0].pitch if pred_notes else 60
            pitch = _median_pitch(pitch_values, int(default_pitch))
            rms_values = _win(env_t, rms, start, end)
            voiced_values = _win(pitch_t, voiced, start, end)
            finite_pitch = pitch_values[np.isfinite(pitch_values)]
            pitch_stability = float(np.std(finite_pitch)) if finite_pitch.size else 99.0
            rms_mean = float(np.mean(rms_values)) if rms_values.size else 0.0
            rms_min = float(np.min(rms_values)) if rms_values.size else 0.0
            prev_pitch = pitch
            next_pitch = pitch
            if rows:
                prev_pitch = int(rows[-1]["pitch"])
            if j + 1 < len(boundaries):
                next_pitch = _median_pitch(_win(pitch_t, pitch_midi, end, boundaries[j + 1]), pitch)
            rows.append(
                {
                    "key": key,
                    "candidate_index": len(rows),
                    "start": start,
                    "end": end,
                    "duration": duration,
                    "pitch": pitch,
                    "label": _label(start, end, pitch, ref_notes, args.onset_tol, args.offset_tol),
                    "onset_strength": _interp(env_t, onset, start),
                    "end_onset_strength": _interp(env_t, onset, end),
                    "rms_mean": rms_mean,
                    "rms_min_ratio": rms_min / max(rms_mean, 1e-7),
                    "pitch_stability": pitch_stability,
                    "voiced_ratio": float(np.mean(voiced_values >= 0.45)) if voiced_values.size else 0.0,
                    "pitch_delta_prev": float(pitch - prev_pitch),
                    "pitch_delta_next": float(next_pitch - pitch),
                    "in_key": int(key_classes is None or pitch % 12 in key_classes),
                    "same_pitch_repeat_evidence": int(abs(pitch - prev_pitch) == 0 and _interp(env_t, onset, start) >= 0.20),
                }
            )
    return rows


def main() -> int:
    ap = argparse.ArgumentParser(description="Extract sequence-selector candidate rows from HumTrans cache.")
    ap.add_argument("--cache-dir", type=Path, required=True)
    ap.add_argument("--split", choices=["train", "dev", "test"], default="dev")
    ap.add_argument("--keys", nargs="*")
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--offset", type=int, default=0)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--min-duration", type=float, default=0.04)
    ap.add_argument("--max-duration", type=float, default=2.50)
    ap.add_argument("--max-boundary-span", type=int, default=8)
    ap.add_argument("--onset-tol", type=float, default=0.12)
    ap.add_argument("--offset-tol", type=float, default=0.18)
    args = ap.parse_args()

    if args.keys:
        paths = [cache_file_path(args.cache_dir, args.split, key) for key in args.keys]
    else:
        paths = sorted((args.cache_dir / args.split).glob("*.json.gz"))
    if args.offset:
        paths = paths[args.offset:]
    if args.limit > 0:
        paths = paths[: args.limit]
    if not paths:
        raise SystemExit("No cache files selected.")
    rows: list[dict[str, object]] = []
    for path in paths:
        rows.extend(_rows_for_cache(path, args))
        print(f"{path.stem}: rows={len(rows)}")
    args.out.parent.mkdir(parents=True, exist_ok=True)
    with args.out.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=FIELDS)
        writer.writeheader()
        writer.writerows(rows)
    print(f"rows={len(rows)} positives={sum(int(r['label']) for r in rows)} out={args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
