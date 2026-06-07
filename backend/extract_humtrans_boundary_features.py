"""Extract frame-level boundary features from HumTrans WAV/MIDI pairs.

The output is an NPZ file with:
  x              float32 [frames, features]
  onset_y        int8    [frames]
  offset_y       int8    [frames]
  file_id        int32   [frames]
  time           float32 [frames]
  feature_names  str     [features]

This prepares the next step: a learned onset/offset boundary model. It does not
change the live app by itself.
"""
from __future__ import annotations

import argparse
import io
import json
from pathlib import Path

import librosa
import numpy as np
import soundfile as sf

from app.pitch import extract_pitch_pyin, hz_to_midi_float
from eval_humtrans import Pair, find_pairs, read_midi_notes, split_pairs


TARGET_SR = 22050
HOP = 256
FRAME = 1024
FEATURE_NAMES = [
    "rms",
    "rms_delta",
    "rms_accel",
    "onset_strength",
    "onset_delta",
    "voiced_prob",
    "voiced_prob_delta",
    "midi_pitch",
    "midi_delta_abs",
    "midi_stability",
    "cent_error_to_round",
]


def _load_wav(pair: Pair) -> tuple[np.ndarray, int]:
    y, sr = sf.read(io.BytesIO(pair.wav.read_bytes()), always_2d=False)
    if y.ndim > 1:
        y = np.mean(y, axis=1)
    y = y.astype(np.float32)
    if sr != TARGET_SR:
        y = librosa.resample(y, orig_sr=sr, target_sr=TARGET_SR).astype(np.float32)
        sr = TARGET_SR
    peak = float(np.max(np.abs(y))) if y.size else 0.0
    if peak > 1.0:
        y = y / peak
    return y, sr


def _robust_norm(a: np.ndarray) -> np.ndarray:
    if a.size == 0:
        return a.astype(np.float32)
    lo = float(np.nanpercentile(a, 10))
    hi = float(np.nanpercentile(a, 95))
    if not np.isfinite(lo) or not np.isfinite(hi) or hi <= lo + 1e-9:
        return np.zeros_like(a, dtype=np.float32)
    return np.clip((a - lo) / (hi - lo), 0.0, 1.0).astype(np.float32)


def _fit_len(a: np.ndarray, n: int, fill: float = 0.0) -> np.ndarray:
    out = np.full(n, fill, dtype=np.float32)
    if a.size:
        out[: min(n, a.size)] = a[: min(n, a.size)]
    return out


def _labels(times: np.ndarray, event_times: list[float], radius_sec: float) -> np.ndarray:
    y = np.zeros(times.shape[0], dtype=np.int8)
    if not event_times:
        return y
    events = np.asarray(event_times, dtype=np.float32)
    for t in events:
        y[np.abs(times - t) <= radius_sec] = 1
    return y


def extract_pair(pair: Pair, label_radius_sec: float) -> dict[str, np.ndarray]:
    audio, sr = _load_wav(pair)
    if audio.size == 0:
        raise ValueError("empty audio")

    rms = librosa.feature.rms(y=audio, frame_length=FRAME, hop_length=HOP, center=True)[0]
    onset = librosa.onset.onset_strength(y=audio, sr=sr, hop_length=HOP)
    times = librosa.frames_to_time(np.arange(max(len(rms), len(onset))), sr=sr, hop_length=HOP)
    n = len(times)

    rms_n = _robust_norm(_fit_len(rms, n))
    onset_n = _robust_norm(_fit_len(onset, n))
    rms_delta = np.diff(rms_n, prepend=rms_n[0])
    rms_accel = np.diff(rms_delta, prepend=rms_delta[0])
    onset_delta = np.diff(onset_n, prepend=onset_n[0])

    pitch_times, hz, _voiced_flag, voiced_prob = extract_pitch_pyin(
        audio, sr, 65.0, 1000.0, hop_length=HOP
    )
    pitch_midi_src = hz_to_midi_float(hz)
    pitch_midi = np.interp(
        times,
        pitch_times,
        np.nan_to_num(pitch_midi_src, nan=0.0),
        left=0.0,
        right=0.0,
    ).astype(np.float32)
    voiced = np.interp(
        times,
        pitch_times,
        np.nan_to_num(voiced_prob, nan=0.0),
        left=0.0,
        right=0.0,
    ).astype(np.float32)
    voiced_n = _robust_norm(voiced)
    pitch_delta = np.abs(np.diff(pitch_midi, prepend=pitch_midi[0])).astype(np.float32)
    pitch_delta[pitch_midi <= 0] = 0.0
    stability = np.zeros(n, dtype=np.float32)
    for i in range(n):
        lo = max(0, i - 2)
        hi = min(n, i + 3)
        window = pitch_midi[lo:hi]
        window = window[window > 0]
        stability[i] = 1.0 / (1.0 + float(np.std(window))) if window.size >= 2 else 0.0
    cent_error = np.zeros(n, dtype=np.float32)
    active = pitch_midi > 0
    cent_error[active] = np.abs(pitch_midi[active] - np.round(pitch_midi[active])).astype(np.float32)

    x = np.stack(
        [
            rms_n,
            rms_delta,
            rms_accel,
            onset_n,
            onset_delta,
            voiced_n,
            np.diff(voiced_n, prepend=voiced_n[0]),
            np.where(active, (pitch_midi - 60.0) / 24.0, 0.0),
            np.clip(pitch_delta / 3.0, 0.0, 1.0),
            stability,
            np.clip(cent_error, 0.0, 0.5) * 2.0,
        ],
        axis=1,
    ).astype(np.float32)

    notes = read_midi_notes(pair.midi)
    onset_y = _labels(times, [n.start for n in notes], label_radius_sec)
    offset_y = _labels(times, [n.end for n in notes], label_radius_sec)
    return {
        "x": x,
        "onset_y": onset_y,
        "offset_y": offset_y,
        "time": times.astype(np.float32),
    }


def main() -> int:
    ap = argparse.ArgumentParser(description="Extract HumTrans boundary training features.")
    ap.add_argument("--root", type=Path, required=True)
    ap.add_argument("--split", choices=["train", "dev", "test"], default="train")
    ap.add_argument("--train-ratio", type=float, default=0.80)
    ap.add_argument("--dev-ratio", type=float, default=0.10)
    ap.add_argument("--seed", type=int, default=20260605)
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--offset", type=int, default=0)
    ap.add_argument("--label-radius-ms", type=float, default=35.0)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--meta-json", type=Path)
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

    xs: list[np.ndarray] = []
    onset_ys: list[np.ndarray] = []
    offset_ys: list[np.ndarray] = []
    file_ids: list[np.ndarray] = []
    times: list[np.ndarray] = []
    kept: list[str] = []
    for file_id, pair in enumerate(pairs):
        try:
            item = extract_pair(pair, args.label_radius_ms / 1000.0)
        except Exception as exc:
            print(f"{pair.key} failed: {exc}")
            continue
        frames = item["x"].shape[0]
        xs.append(item["x"])
        onset_ys.append(item["onset_y"])
        offset_ys.append(item["offset_y"])
        file_ids.append(np.full(frames, file_id, dtype=np.int32))
        times.append(item["time"])
        kept.append(pair.key)
        print(
            f"[{len(kept):04d}] {pair.key} frames={frames} "
            f"onsets={int(np.sum(item['onset_y']))} offsets={int(np.sum(item['offset_y']))}"
        )

    if not xs:
        raise SystemExit("No feature rows extracted.")

    x = np.concatenate(xs, axis=0)
    onset_y = np.concatenate(onset_ys, axis=0)
    offset_y = np.concatenate(offset_ys, axis=0)
    file_id_arr = np.concatenate(file_ids, axis=0)
    time_arr = np.concatenate(times, axis=0)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    np.savez_compressed(
        args.out,
        x=x,
        onset_y=onset_y,
        offset_y=offset_y,
        file_id=file_id_arr,
        time=time_arr,
        feature_names=np.asarray(FEATURE_NAMES),
        keys=np.asarray(kept),
    )
    meta = {
        "split": args.split,
        "seed": args.seed,
        "pairs": len(kept),
        "frames": int(x.shape[0]),
        "features": FEATURE_NAMES,
        "onset_positive_rate": float(np.mean(onset_y)),
        "offset_positive_rate": float(np.mean(offset_y)),
        "out": str(args.out),
    }
    if args.meta_json is not None:
        args.meta_json.parent.mkdir(parents=True, exist_ok=True)
        args.meta_json.write_text(json.dumps(meta, indent=2), encoding="utf-8")
    print("=" * 78)
    print(json.dumps(meta, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
