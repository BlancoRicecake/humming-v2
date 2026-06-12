"""Diagnose the residual Layer-2 pitch errors in the LoopTap app path.

For each dev sample (same context derivation as eval_looptap.py) it matches
predicted app notes to the oracle at ±1 step (the real-app metric) and then:
  1. taxonomizes every pitch mismatch (octave vs rung-neighbor, assistant
     provenance, raw-pitch distance to the oracle rung), and
  2. scores COUNTERFACTUAL snap variants on the full set — what would
     app pitch accuracy be if the ladder snap consumed a different input?

Variants (phrase octave shift held fixed = current int-pitch shift):
  current   snap(int(pitch) + shift)            — what the app does today
  raw_cont  snap_cont(pitch_raw + shift)        — continuous raw, skips the
                                                  chromatic round + assistant
  orig_int  snap(pitch_original + shift)        — pre-assistant integer
  raw_close snap_cont(raw if |pitch-raw|<=0.75 else pitch)  — hybrid

Run:
  .\.venv\Scripts\python diag_looptap_pitch.py --root <HumTrans> --split dev \
      --limit 30 --csv diag_looptap_pitch_dev.csv
"""
from __future__ import annotations

import argparse
import csv
import json
from collections import Counter
from pathlib import Path

import eval_humtrans as eh
import eval_looptap as el
from app import looptap_map as lm
from app.analyze import analyze_audio
from app.schemas import AnalyzeOptions


def snap_to_ladder_cont(m: float, ladder: list[lm.Rung]) -> lm.Rung:
    """snap_to_ladder on a CONTINUOUS midi value (same fold + nearest rung)."""
    lo, hi = ladder[0].midi, ladder[-1].midi
    while m < lo - 6:
        m += 12
    while m > hi + 6:
        m -= 12
    best = ladder[0]
    best_d = float("inf")
    for r in ladder:
        d = abs(r.midi - m)
        if d < best_d:
            best_d = d
            best = r
    return best


def map_with_sources(notes, ladder, steps: int):
    """map_engine_notes_to_app (pitched path) but keeping the engine note."""
    pitched = [n for n in notes if getattr(n, "kind", "pitched") != "percussive"]
    shift = lm.phrase_octave_shift([n.pitch for n in pitched], ladder)
    out = []
    for n in pitched:
        step = n.step
        if step is None or step < 0 or step >= steps:
            continue
        raw_dur = n.dur_steps if n.dur_steps is not None else 1
        dur = max(1, min(int(raw_dur), steps - int(step)))
        rung = lm.snap_to_ladder(int(n.pitch) + shift, ladder)
        out.append(({"step": int(step), "midi": rung.midi, "dur": dur}, n))
    return out, shift


def variant_midi(n, shift: int, ladder, variant: str) -> int:
    pitch = int(getattr(n, "pitch", 0))
    raw = float(getattr(n, "pitch_raw", pitch) or pitch)
    orig = int(getattr(n, "pitch_original", pitch) or pitch)
    if variant == "current":
        return lm.snap_to_ladder(pitch + shift, ladder).midi
    if variant == "raw_cont":
        return snap_to_ladder_cont(raw + shift, ladder).midi
    if variant == "orig_int":
        return lm.snap_to_ladder(orig + shift, ladder).midi
    if variant == "raw_close":
        m = raw if abs(pitch - raw) <= 0.75 else float(pitch)
        return snap_to_ladder_cont(m + shift, ladder).midi
    raise ValueError(variant)


VARIANTS = ["current", "raw_cont", "orig_int", "raw_close"]


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--root", type=Path, required=True)
    ap.add_argument("--split", default="dev", choices=["train", "dev", "test", "all"])
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--limit", type=int, default=30)
    ap.add_argument("--offset", type=int, default=0)
    ap.add_argument("--min-notes", type=int, default=3)
    ap.add_argument("--pitch-model", default="pyin", choices=["pyin", "crepe"])
    ap.add_argument("--csv", type=Path)
    args = ap.parse_args()

    pairs = eh.find_pairs(args.root, None, None, None, None)
    pairs, _ = eh.split_pairs(pairs, args.split, 0.8, 0.1, args.seed)
    pairs.sort(key=lambda p: p.key)
    if args.offset:
        pairs = pairs[args.offset:]
    if args.limit:
        pairs = pairs[: args.limit]

    err_rows: list[dict] = []
    taxonomy: Counter = Counter()
    # variant accumulators over t1-matched pairs: midi-correct count
    var_ok = Counter()
    var_pc_ok = Counter()
    n_matched = 0
    n_samples = 0
    shift_mismatch_samples = 0

    for i, pair in enumerate(pairs):
        try:
            ref = eh.read_midi_notes(pair.midi)
            ref = [n for n in ref if n.end > n.start]
            if len(ref) < args.min_notes:
                continue
            bpm = el.derive_bpm(ref, None)
            tonic, mode = el.derive_key(ref)
            cell = el.cell_seconds(bpm)
            wav_bytes = pair.wav.read_bytes()
            common = dict(
                steps_per_bar=el.STEPS_PER_BAR, quantize_grid=el.GRID,
                tempo_bpm=bpm, swing=0.0,
                auto_key=False, key_tonic=tonic, scale=mode,
                pitch_assistant=True, assist_aggressive=True,
                pitch_model=args.pitch_model,
            )
            res = analyze_audio(
                wav_bytes, AnalyzeOptions(loop_quantize=True, loop_bars=None, **common))
            total_steps = el.total_steps_for(float(res.waveform.duration), cell)
            ladder = lm.build_ladder(tonic, mode, 4, 8)
            pred_src, pred_shift = map_with_sources(res.notes, ladder, total_steps)
            pred_app = [p for p, _ in pred_src]
            note_by_id = {id(p): n for p, n in pred_src}
            oracle_app = el.build_oracle_app(ref, ladder, cell, total_steps)
            oracle_shift = lm.phrase_octave_shift([n.pitch for n in ref], ladder)
            step_shift = el.best_global_step_shift(oracle_app, pred_app)
            m1, _, _ = el.match_steps(oracle_app, pred_app, step_shift, tol=1)
        except Exception as exc:
            print(f"[{i + 1}/{len(pairs)}] {pair.key}  ERROR: {exc}")
            continue

        n_samples += 1
        if pred_shift != oracle_shift:
            shift_mismatch_samples += 1
        sample_ok = 0
        for o, p in m1:
            n = note_by_id[id(p)]
            n_matched += 1
            for v in VARIANTS:
                vm = variant_midi(n, pred_shift, ladder, v)
                if vm == o["midi"]:
                    var_ok[v] += 1
                if vm % 12 == o["midi"] % 12:
                    var_pc_ok[v] += 1
            if p["midi"] == o["midi"]:
                sample_ok += 1
                continue
            # ---- mismatch taxonomy ----
            pitch = int(n.pitch)
            raw = float(n.pitch_raw or pitch)
            o_idx = next(r.index for r in ladder if r.midi == o["midi"])
            p_idx = next(r.index for r in ladder if r.midi == p["midi"])
            octave_err = (p["midi"] - o["midi"]) % 12 == 0
            raw_folded = raw + pred_shift
            lo, hi = ladder[0].midi, ladder[-1].midi
            while raw_folded < lo - 6:
                raw_folded += 12
            while raw_folded > hi + 6:
                raw_folded -= 12
            raw_dist_to_oracle = abs(raw_folded - o["midi"])
            raw_dist_to_pred = abs(raw_folded - p["midi"])
            cf_raw = variant_midi(n, pred_shift, ladder, "raw_cont")
            if octave_err:
                cat = "octave"
            elif cf_raw == o["midi"]:
                cat = "raw_would_fix"
            elif raw_dist_to_oracle <= 1.0:
                cat = "raw_within_1st"
            else:
                cat = "raw_far"
            taxonomy[cat] += 1
            err_rows.append({
                "key": pair.key, "step": p["step"],
                "oracle_midi": o["midi"], "pred_midi": p["midi"],
                "rung_delta": p_idx - o_idx, "octave_err": int(octave_err),
                "pitch": pitch, "pitch_raw": round(raw, 3),
                "pitch_original": int(n.pitch_original or pitch),
                "assisted": int(bool(n.assisted)), "source": n.source,
                "confidence": round(float(n.confidence or 0), 3),
                "voiced_ratio": round(float(n.voiced_ratio or 0), 3),
                "duration": round(float(n.duration), 3),
                "raw_dist_to_oracle": round(raw_dist_to_oracle, 3),
                "raw_dist_to_pred": round(raw_dist_to_pred, 3),
                "cf_raw_midi": cf_raw, "category": cat,
                "pred_shift": pred_shift, "oracle_shift": oracle_shift,
            })
        print(f"[{i + 1}/{len(pairs)}] {pair.key}  matched={len(m1)} "
              f"pitch_ok={sample_ok} shift(pred/oracle)={pred_shift}/{oracle_shift}")

    print("\n=== t1-matched pitch accuracy by snap variant ===")
    for v in VARIANTS:
        print(f"  {v:10s} acc={var_ok[v] / max(1, n_matched):.4f} "
              f"pc_acc={var_pc_ok[v] / max(1, n_matched):.4f}")
    print(f"\nmatched={n_matched} samples={n_samples} "
          f"octave_shift_mismatch_samples={shift_mismatch_samples}")
    print("\n=== mismatch taxonomy (current variant) ===")
    total_err = sum(taxonomy.values())
    for cat, cnt in taxonomy.most_common():
        print(f"  {cat:15s} {cnt:4d}  ({cnt / max(1, total_err):.1%})")
    print(json.dumps({
        "matched": n_matched,
        "errors": total_err,
        "variant_acc": {v: round(var_ok[v] / max(1, n_matched), 4) for v in VARIANTS},
    }))

    if args.csv and err_rows:
        with args.csv.open("w", newline="", encoding="utf-8") as fh:
            w = csv.DictWriter(fh, fieldnames=list(err_rows[0].keys()))
            w.writeheader()
            w.writerows(err_rows)
        print(f"wrote {args.csv} ({len(err_rows)} error rows)")


if __name__ == "__main__":
    main()
