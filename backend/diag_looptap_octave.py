"""A/B phrase-octave-shift rules for the LoopTap app mapping.

The diag_looptap_pitch.py taxonomy showed the single biggest Layer-2 pitch
error source is a phrase octave-shift DISAGREEMENT between the predicted notes
and the oracle: the current rule rounds (center - median)/12, and when the
phrase median sits at the rounding boundary a 1-semitone difference between the
engine's median and the ground truth's median flips the WHOLE phrase by an
octave (e.g. dev F01_0032_0001_1: GT boundary exactly 0.5 → 27/27 notes wrong).

This script replays the SAME engine analysis once per sample and scores shift
rules applied symmetrically to both sides (pred from engine notes, oracle from
GT notes):
  median   current Dart rule: round((center - median_int)/12)*12
  mean     same but arithmetic mean of int pitches
  wmedian  duration-weighted median of int pitches
  cost     argmin over k*12 of Σ |fold(p+shift) - snap(p+shift)|  (unweighted)
  cost_w   same, duration-weighted

Reported per rule: pred/oracle shift agreement, t1 pitch accuracy on matched
steps, and app_note_f1 / app_note_f1_t1 (the eval_looptap headline metrics).

Run:
  .\.venv\Scripts\python diag_looptap_octave.py --root <HumTrans> --split dev --limit 30
"""
from __future__ import annotations

import argparse
import json
import statistics
from pathlib import Path

import eval_humtrans as eh
import eval_looptap as el
from app import looptap_map as lm
from app.analyze import analyze_audio
from app.schemas import AnalyzeOptions

RULES = ["median", "mean", "wmedian", "cost", "cost_w"]


def _fold_dist(midi: float, ladder: list[lm.Rung]) -> float:
    lo, hi = ladder[0].midi, ladder[-1].midi
    m = midi
    while m < lo - 6:
        m += 12
    while m > hi + 6:
        m -= 12
    return min(abs(r.midi - m) for r in ladder)


def shift_for(rule: str, pitches: list[int], durs: list[float],
              ladder: list[lm.Rung]) -> int:
    if not pitches:
        return 0
    center = (ladder[0].midi + ladder[-1].midi) // 2
    if rule == "median":
        # inlined pre-2026-06-11 phrase_octave_shift (lm now uses the mean) so
        # this A/B arm keeps measuring the original median rule
        med = sorted(pitches)[len(pitches) // 2]      # Dart list[length ~/ 2]
        return lm._round_dart((center - med) / 12) * 12
    if rule == "mean":
        return lm._round_dart((center - statistics.fmean(pitches)) / 12) * 12
    if rule == "wmedian":
        order = sorted(range(len(pitches)), key=lambda i: pitches[i])
        total = sum(durs)
        acc = 0.0
        med = pitches[order[-1]]
        for i in order:
            acc += durs[i]
            if acc >= total / 2:
                med = pitches[i]
                break
        return lm._round_dart((center - med) / 12) * 12
    if rule in ("cost", "cost_w"):
        base = lm.phrase_octave_shift(pitches, ladder)
        best_shift, best_cost = base, float("inf")
        for k in (-2, -1, 0, 1, 2):
            shift = base + 12 * k
            cost = 0.0
            for p, d in zip(pitches, durs):
                w = d if rule == "cost_w" else 1.0
                cost += w * _fold_dist(p + shift, ladder)
            # strict < keeps ties on the smaller |k| (k iterates outward-in? no:
            # order is -2..2, so prefer the first minimum; bias to base via tiny
            # penalty on |k| instead)
            cost += abs(k) * 1e-6
            if cost < best_cost:
                best_cost, best_shift = cost, shift
        return best_shift
    raise ValueError(rule)


def map_app(notes, ladder, steps: int, shift: int):
    pitched = [n for n in notes if getattr(n, "kind", "pitched") != "percussive"]
    out = []
    for n in pitched:
        step = n.step
        if step is None or step < 0 or step >= steps:
            continue
        raw_dur = n.dur_steps if n.dur_steps is not None else 1
        dur = max(1, min(int(raw_dur), steps - int(step)))
        rung = lm.snap_to_ladder(int(n.pitch) + shift, ladder)
        out.append({"step": int(step), "midi": rung.midi, "dur": dur})
    return out


def oracle_app(ref, ladder, cell: float, total_steps: int, shift: int):
    best_by_step: dict[int, tuple[float, dict]] = {}
    for n in ref:
        step = round(n.start / cell)
        if step < 0 or step >= total_steps:
            continue
        dur = max(1, min(round(n.duration / cell), total_steps - step))
        rung = lm.snap_to_ladder(int(n.pitch) + shift, ladder)
        prev = best_by_step.get(step)
        if prev is None or n.duration > prev[0]:
            best_by_step[step] = (n.duration, {"step": step, "midi": rung.midi, "dur": dur})
    return [v[1] for v in sorted(best_by_step.values(), key=lambda kv: kv[1]["step"])]


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--root", type=Path, required=True)
    ap.add_argument("--split", default="dev", choices=["train", "dev", "test", "all"])
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--limit", type=int, default=30)
    ap.add_argument("--offset", type=int, default=0)
    ap.add_argument("--min-notes", type=int, default=3)
    ap.add_argument("--pitch-model", default="pyin", choices=["pyin", "crepe"])
    args = ap.parse_args()

    pairs = eh.find_pairs(args.root, None, None, None, None)
    pairs, _ = eh.split_pairs(pairs, args.split, 0.8, 0.1, args.seed)
    pairs.sort(key=lambda p: p.key)
    if args.offset:
        pairs = pairs[args.offset:]
    if args.limit:
        pairs = pairs[: args.limit]

    acc = {r: {"agree": 0, "samples": 0, "m1": 0, "ok1": 0,
               "m0": 0, "ok0": 0, "oracle": 0, "pred": 0} for r in RULES}

    for i, pair in enumerate(pairs):
        try:
            ref = [n for n in eh.read_midi_notes(pair.midi) if n.end > n.start]
            if len(ref) < args.min_notes:
                continue
            bpm = el.derive_bpm(ref, None)
            tonic, mode = el.derive_key(ref)
            cell = el.cell_seconds(bpm)
            res = analyze_audio(pair.wav.read_bytes(), AnalyzeOptions(
                loop_quantize=True, loop_bars=None,
                steps_per_bar=el.STEPS_PER_BAR, quantize_grid=el.GRID,
                tempo_bpm=bpm, swing=0.0,
                auto_key=False, key_tonic=tonic, scale=mode,
                pitch_assistant=True, assist_aggressive=True,
                pitch_model=args.pitch_model))
            total_steps = el.total_steps_for(float(res.waveform.duration), cell)
            ladder = lm.build_ladder(tonic, mode, 4, 8)
            pitched = [n for n in res.notes
                       if getattr(n, "kind", "pitched") != "percussive"
                       and n.step is not None and 0 <= n.step < total_steps]
            ep = [int(n.pitch) for n in pitched]
            ed = [float(n.duration) for n in pitched]
            gp = [int(n.pitch) for n in ref]
            gd = [float(n.duration) for n in ref]
        except Exception as exc:
            print(f"[{i + 1}/{len(pairs)}] {pair.key}  ERROR: {exc}")
            continue

        line = [f"[{i + 1}/{len(pairs)}] {pair.key} "]
        for rule in RULES:
            sp = shift_for(rule, ep, ed, ladder)
            so = shift_for(rule, gp, gd, ladder)
            a = acc[rule]
            a["samples"] += 1
            a["agree"] += int(sp == so)
            pred = map_app(res.notes, ladder, total_steps, sp)
            orc = oracle_app(ref, ladder, cell, total_steps, so)
            step_shift = el.best_global_step_shift(orc, pred)
            m0, _, _ = el.match_steps(orc, pred, step_shift, tol=0)
            m1, _, _ = el.match_steps(orc, pred, step_shift, tol=1)
            a["m0"] += len(m0)
            a["ok0"] += sum(1 for o, p in m0 if o["midi"] == p["midi"])
            a["m1"] += len(m1)
            a["ok1"] += sum(1 for o, p in m1 if o["midi"] == p["midi"])
            a["oracle"] += len(orc)
            a["pred"] += len(pred)
            line.append(f"{rule}:{'=' if sp == so else f'{sp}/{so}'}")
        print("  ".join(line))

    print("\n=== shift-rule comparison (symmetric pred/oracle) ===")
    out = {}
    for rule in RULES:
        a = acc[rule]
        _, _, f1_0 = el.prf(a["ok0"], a["oracle"], a["pred"])
        _, _, f1_1 = el.prf(a["ok1"], a["oracle"], a["pred"])
        row = {
            "agree": round(a["agree"] / max(1, a["samples"]), 4),
            "pitch_acc_t1": round(a["ok1"] / max(1, a["m1"]), 4),
            "app_note_f1": round(f1_0, 4),
            "app_note_f1_t1": round(f1_1, 4),
        }
        out[rule] = row
        print(f"  {rule:8s} agree={row['agree']:.3f}  acc_t1={row['pitch_acc_t1']:.4f}  "
              f"note_f1={row['app_note_f1']:.4f}  note_f1_t1={row['app_note_f1_t1']:.4f}")
    print(json.dumps(out))


if __name__ == "__main__":
    main()
