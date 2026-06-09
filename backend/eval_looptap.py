"""Evaluate the LoopTap engine→app note path on HumTrans WAV/MIDI pairs.

Unlike eval_humtrans.py (which scores the raw engine notes), this measures the
FULL path the LoopTap UI uses: the loop-grid engine (`loop_quantize` → integer
step/dur) PLUS the app-side octave-fold + in-key ladder snap (app/looptap_map.py,
a 1:1 mirror of the Dart conversion). It reports two layers plus a representation
ceiling, so we can tell whether a miss is the engine's fault or the app mapping's.

Per sample:
  - derive tempo (from ground-truth inter-onset spacing) and key/scale (from the
    ground-truth pitch histogram) — the app would have these from the song.
  - LAYER 1 (engine): engine pitched notes vs raw ground truth — note/onset F1,
    onset-pitch accuracy, pitch MAE. (the foundation eval_humtrans also reports)
  - LAYER 2 (app mapping): predicted app notes (engine step + ladder snap) vs an
    ORACLE = ground truth quantized to the SAME grid+ladder = the best the app
    could represent. Step F1, in-key pitch accuracy, app-note F1.
  - CEILING: how much the grid+ladder representation itself loses vs the true
    melody (collision survival, in-key fraction) — the cap on Layer 2.

Run:
  .\\.venv\\Scripts\\python eval_looptap.py --root <HumTrans> --split dev --limit 20 \
      --csv looptap_eval.csv --summary-json looptap_summary.json
"""
from __future__ import annotations

import argparse
import csv
import json
import math
import statistics
from pathlib import Path

import numpy as np

import eval_humtrans as eh
from app.analyze import analyze_audio
from app.schemas import AnalyzeOptions
from app.key_detect import build_pc_histogram, detect_key, key_weight
from app.scales import scale_pitch_classes
from app import looptap_map as lm

STEPS_PER_BAR = 16  # LoopTap kBeatsPerBar * kStepsPerBeat
GRID = 16


# ── per-sample context derivation ──────────────────────────────────────────
def derive_bpm(ref: list[eh.MidiNote], override: float | None,
               min_bpm: float = 60.0, max_bpm: float = 180.0) -> float:
    """Estimate the beat (quarter-note) tempo from the ground-truth onsets.

    The app gets tempo from the song + count-in; HumTrans has none, so we fit the
    grid to the performance. An onset-impulse autocorrelation finds the dominant
    periodicity in the quarter-note range (its peak survives at the true beat and
    its multiples), which fits a 16th grid far better than the previous median-IOI
    heuristic — a bad tempo guess was tipping correct onsets across step lines.
    Both prediction and oracle share this grid, so it only sets the grid, not the
    pred/oracle comparison.
    """
    if override:
        return float(override)
    onsets = np.array(sorted(n.start for n in ref), dtype=float)
    if len(onsets) < 3 or onsets[-1] <= onsets[0]:
        return 100.0
    fs = 200  # 5 ms onset grid
    n = int((onsets[-1] - onsets[0]) * fs) + 1
    env = np.zeros(n)
    env[np.clip(((onsets - onsets[0]) * fs).astype(int), 0, n - 1)] = 1.0
    ac = np.correlate(env, env, mode="full")[n - 1:]
    lags = np.arange(len(ac)) / fs
    lo, hi = 60.0 / max_bpm, 60.0 / min_bpm  # quarter-note period window
    mask = (lags >= lo) & (lags <= hi)
    if not mask.any() or ac[mask].max() <= 0:
        iois = [b - a for a, b in zip(onsets, onsets[1:]) if b - a > 0.05]
        return float(min(max_bpm, max(min_bpm, round(30.0 / statistics.median(iois))))) if iois else 100.0
    best_lag = lags[mask][int(np.argmax(ac[mask]))]
    return float(min(max_bpm, max(min_bpm, round(60.0 / best_lag))))


def derive_key(ref: list[eh.MidiNote]) -> tuple[str, str]:
    """Best (tonic, 'major'|'minor') for the ladder, from the GT pitch histogram."""
    midis = [n.pitch for n in ref]
    weights = [key_weight(n.duration, 1.0, 1.0) for n in ref]
    hist = build_pc_histogram(midis, weights)
    total_dur = sum(n.duration for n in ref)
    tonic, mode, _conf = detect_key(hist, n_notes=len(ref), total_dur=total_dur)
    if tonic is None or mode not in ("major", "minor"):
        # fallback: most-weighted pitch class as tonic, major
        pc = max(range(12), key=lambda k: hist[k]) if hist.sum() > 0 else 0
        tonic = lm.NOTE_NAMES[pc]
        mode = "major"
    return tonic, mode


# ── grid / app-note construction ───────────────────────────────────────────
def cell_seconds(bpm: float) -> float:
    return (60.0 / bpm) * 4.0 / GRID


def total_steps_for(duration: float, cell: float) -> int:
    bars = max(1, int(math.ceil(duration / (cell * STEPS_PER_BAR) - 1e-6)))
    return bars * STEPS_PER_BAR


def build_oracle_app(
    ref: list[eh.MidiNote], ladder: list[lm.Rung], cell: float, total_steps: int
) -> list[dict]:
    """Ground truth quantized to the same grid+ladder = best app representation.

    Mirrors the prediction mapping: phrase octave-fold + ladder snap, hard step
    snap, per-step dedup (keep the longest note — the most prominent), drop
    out-of-loop. This is the Layer-2 reference."""
    shift = lm.phrase_octave_shift([n.pitch for n in ref], ladder)
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


# ── step-level matching (Layer 2) ──────────────────────────────────────────
def match_steps(a: list[dict], b: list[dict], shift: int, tol: int):
    """One-to-one match of app notes by step (b shifted by `shift`), greedy by
    |Δstep| then |Δmidi|. Returns (matches[(a,b)], missed_a, extra_b)."""
    cands = []
    for i, x in enumerate(a):
        for j, y in enumerate(b):
            dstep = abs(x["step"] - (y["step"] + shift))
            if dstep <= tol:
                dmidi = abs(x.get("midi", 0) - y.get("midi", 0))
                cands.append((dstep, dmidi, i, j))
    cands.sort()
    ur, up, matches = set(), set(), []
    for _, _, i, j in cands:
        if i in ur or j in up:
            continue
        ur.add(i)
        up.add(j)
        matches.append((a[i], b[j]))
    return (matches,
            [x for i, x in enumerate(a) if i not in ur],
            [y for j, y in enumerate(b) if j not in up])


def best_global_step_shift(oracle: list[dict], pred: list[dict], max_shift: int = 8) -> int:
    """Integer step shift that maximizes step matches — neutralizes grid-phase /
    origin differences between the engine and the oracle (mirrors the pitch-shift
    alignment eval_humtrans uses for key)."""
    if not oracle or not pred:
        return 0
    best = (0, -1)  # (score, -abs(shift)) maximized
    for s in range(-max_shift, max_shift + 1):
        m, _, _ = match_steps(oracle, pred, s, tol=1)
        score = (len(m), -abs(s))
        if score > best:
            best = score
            best_s = s
    return best_s if best != (0, -1) else 0


# ── metric helpers ─────────────────────────────────────────────────────────
def prf(n_match: int, n_ref: int, n_pred: int) -> tuple[float, float, float]:
    p = n_match / n_pred if n_pred else 0.0
    r = n_match / n_ref if n_ref else 0.0
    f = 2 * p * r / (p + r) if (p + r) else 0.0
    return p, r, f


# ── per-sample evaluation ──────────────────────────────────────────────────
def eval_pair(pair: eh.Pair, args) -> dict | None:
    ref = eh.read_midi_notes(pair.midi)
    ref = [n for n in ref if n.end > n.start]
    if len(ref) < args.min_notes:
        return None

    bpm = derive_bpm(ref, args.bpm)
    tonic, mode = derive_key(ref)
    cell = cell_seconds(bpm)
    wav_bytes = pair.wav.read_bytes()

    # Shared engine config (the key/assist LoopTap uses). Layer 1 measures the
    # raw engine (no grid); Layer 2 the same engine + loop grid + ladder, so the
    # delta is purely what the app mapping adds/loses.
    common = dict(
        steps_per_bar=STEPS_PER_BAR, quantize_grid=GRID, tempo_bpm=bpm, swing=0.0,
        auto_key=False, key_tonic=tonic, scale=mode,
        pitch_assistant=True, assist_aggressive=True, pitch_model=args.pitch_model,
    )
    res_loop = analyze_audio(
        wav_bytes, AnalyzeOptions(loop_quantize=True, loop_bars=None, **common))
    audio_dur = float(res_loop.waveform.duration)
    total_steps = total_steps_for(audio_dur, cell)

    # ---- Layer 1: RAW engine pitched notes vs raw ground truth ----
    # Skipped under --layers app (Layer 2 only) to run the pitch A/B ~2x faster.
    if args.layers == "both":
        res_raw = analyze_audio(wav_bytes, AnalyzeOptions(loop_quantize=False, **common))
        pred_mid = [
            eh.MidiNote(float(n.start), float(n.end), int(n.pitch), int(n.velocity))
            for n in res_raw.notes if n.kind == "pitched" and n.end > n.start
        ]
        pitch_shift = eh.best_global_pitch_shift(ref, pred_mid) if args.normalize_key else 0
        note_m, _, _ = eh.match_notes(
            ref, pred_mid, args.onset_tol, args.offset_tol, args.pitch_tol, pitch_shift)
        onset_m, _, _ = eh.match_onsets(ref, pred_mid, args.onset_tol, pitch_shift)
        onset_pitch_ok = sum(1 for r, p in onset_m if abs(p.pitch - r.pitch) <= args.pitch_tol)
        pitch_abs = [abs(p.pitch - r.pitch) for r, p in onset_m]
    else:
        pred_mid, note_m, onset_m, onset_pitch_ok, pitch_abs = [], [], [], 0, []

    # ---- Layer 2: app mapping vs oracle ----
    ladder = lm.build_ladder(tonic, mode, 4, 8)
    pred_app = lm.map_engine_notes_to_app(res_loop.notes, ladder, drums=False, steps=total_steps)
    oracle_app = build_oracle_app(ref, ladder, cell, total_steps)
    shift = best_global_step_shift(oracle_app, pred_app)
    app_m, app_missed, app_extra = match_steps(oracle_app, pred_app, shift, tol=0)
    app_pitch_ok = sum(1 for o, p in app_m if o["midi"] == p["midi"])
    app_pc_ok = sum(1 for o, p in app_m if o["midi"] % 12 == p["midi"] % 12)
    app_note_ok = app_pitch_ok  # step-matched AND exact ladder midi
    # ±1-step tolerant variant: isolates sub-step drift (off-by-one) from genuine
    # onset misses. If t1 ≫ t0, the bottleneck is grid alignment, not detection.
    app_m1, _, _ = match_steps(oracle_app, pred_app, shift, tol=1)
    app_pitch_ok1 = sum(1 for o, p in app_m1 if o["midi"] == p["midi"])

    # ---- Ceiling: how much the grid+ladder representation loses vs truth ----
    scale_pcs = set(scale_pitch_classes(tonic, mode))
    inkey = sum(1 for n in ref if (n.pitch % 12) in scale_pcs)

    _, _, note_f1 = prf(len(note_m), len(ref), len(pred_mid))
    _, _, onset_f1 = prf(len(onset_m), len(ref), len(pred_mid))
    _, _, app_step_f1 = prf(len(app_m), len(oracle_app), len(pred_app))
    _, _, app_note_f1 = prf(app_note_ok, len(oracle_app), len(pred_app))
    _, _, app_step_f1_t1 = prf(len(app_m1), len(oracle_app), len(pred_app))

    return {
        "key": pair.key,
        "bpm": round(bpm, 1), "bars": total_steps // STEPS_PER_BAR, "steps": total_steps,
        "tonic": tonic, "mode": mode, "step_shift": shift,
        "ref_notes": len(ref), "pred_notes": len(pred_mid), "oracle_notes": len(oracle_app),
        "pred_app_notes": len(pred_app),
        # layer 1
        "note_matches": len(note_m), "onset_matches": len(onset_m),
        "note_f1": round(note_f1, 4), "onset_f1": round(onset_f1, 4),
        "onset_pitch_ok": onset_pitch_ok,
        "pitch_mae_st": round(statistics.mean(pitch_abs), 4) if pitch_abs else 0.0,
        # layer 2
        "app_step_matches": len(app_m), "app_pitch_ok": app_pitch_ok, "app_pc_ok": app_pc_ok,
        "app_step_f1": round(app_step_f1, 4), "app_note_f1": round(app_note_f1, 4),
        "app_step_f1_t1": round(app_step_f1_t1, 4),
        # ceiling
        "ceiling_survival": round(len(oracle_app) / max(1, len(ref)), 4),
        "ceiling_inkey": round(inkey / max(1, len(ref)), 4),
        # raw accumulators for micro averaging
        "_acc": {
            "ref": len(ref), "pred": len(pred_mid), "oracle": len(oracle_app),
            "pred_app": len(pred_app),
            "note_m": len(note_m), "onset_m": len(onset_m),
            "onset_pitch_ok": onset_pitch_ok, "pitch_abs": pitch_abs,
            "app_m": len(app_m), "app_pitch_ok": app_pitch_ok, "app_pc_ok": app_pc_ok,
            "app_m1": len(app_m1), "app_pitch_ok1": app_pitch_ok1,
            "inkey": inkey,
        },
    }


def summarize(rows: list[dict]) -> dict:
    a = {k: 0 for k in ("ref", "pred", "oracle", "pred_app", "note_m", "onset_m",
                        "onset_pitch_ok", "app_m", "app_pitch_ok", "app_pc_ok",
                        "app_m1", "app_pitch_ok1", "inkey")}
    pitch_abs: list[float] = []
    for r in rows:
        acc = r["_acc"]
        for k in a:
            a[k] += acc[k]
        pitch_abs.extend(acc["pitch_abs"])
    _, _, note_f1 = prf(a["note_m"], a["ref"], a["pred"])
    _, _, onset_f1 = prf(a["onset_m"], a["ref"], a["pred"])
    _, _, app_step_f1 = prf(a["app_m"], a["oracle"], a["pred_app"])
    _, _, app_note_f1 = prf(a["app_pitch_ok"], a["oracle"], a["pred_app"])
    _, _, app_step_f1_t1 = prf(a["app_m1"], a["oracle"], a["pred_app"])
    _, _, app_note_f1_t1 = prf(a["app_pitch_ok1"], a["oracle"], a["pred_app"])
    return {
        "samples": len(rows),
        "layer1_engine": {
            "note_f1": round(note_f1, 4),
            "onset_f1": round(onset_f1, 4),
            "onset_pitch_acc": round(a["onset_pitch_ok"] / max(1, a["onset_m"]), 4),
            "pitch_mae_st": round(statistics.mean(pitch_abs), 4) if pitch_abs else 0.0,
        },
        "layer2_app": {
            "app_step_f1": round(app_step_f1, 4),
            "app_note_f1": round(app_note_f1, 4),
            "app_pitch_acc": round(a["app_pitch_ok"] / max(1, a["app_m"]), 4),
            "app_pc_acc": round(a["app_pc_ok"] / max(1, a["app_m"]), 4),
            "app_step_f1_t1": round(app_step_f1_t1, 4),   # ±1 step tolerant
            "app_note_f1_t1": round(app_note_f1_t1, 4),
        },
        "ceiling": {
            "survival": round(a["oracle"] / max(1, a["ref"]), 4),
            "inkey": round(a["inkey"] / max(1, a["ref"]), 4),
        },
    }


CSV_FIELDS = [
    "key", "bpm", "bars", "steps", "tonic", "mode", "step_shift",
    "ref_notes", "pred_notes", "oracle_notes", "pred_app_notes",
    "note_f1", "onset_f1", "onset_pitch_ok", "pitch_mae_st",
    "app_step_f1", "app_step_f1_t1", "app_note_f1", "app_step_matches", "app_pitch_ok", "app_pc_ok",
    "ceiling_survival", "ceiling_inkey",
]


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--root", type=Path)
    ap.add_argument("--wav-dir", type=Path)
    ap.add_argument("--midi-dir", type=Path)
    ap.add_argument("--wav-zip", type=Path)
    ap.add_argument("--midi-zip", type=Path)
    ap.add_argument("--split", default="dev", choices=["train", "dev", "test", "all"])
    ap.add_argument("--train-ratio", type=float, default=0.8)
    ap.add_argument("--dev-ratio", type=float, default=0.1)
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--offset", type=int, default=0)
    ap.add_argument("--min-notes", type=int, default=3)
    ap.add_argument("--bpm", type=float, default=None, help="override derived tempo")
    ap.add_argument("--pitch-model", default="pyin", choices=["pyin", "crepe"])
    ap.add_argument("--layers", default="both", choices=["both", "app"],
                    help="'app' skips the raw Layer-1 pass (~2x faster for Layer-2 A/B)")
    ap.add_argument("--normalize-key", action="store_true", default=True)
    ap.add_argument("--no-normalize-key", dest="normalize_key", action="store_false")
    ap.add_argument("--onset-tol", type=float, default=0.12)
    ap.add_argument("--offset-tol", type=float, default=0.18)
    ap.add_argument("--pitch-tol", type=int, default=0)
    ap.add_argument("--csv", type=Path)
    ap.add_argument("--summary-json", type=Path)
    args = ap.parse_args()

    pairs = eh.find_pairs(args.root, args.wav_dir, args.midi_dir, args.wav_zip, args.midi_zip)
    pairs, _ = eh.split_pairs(pairs, args.split, args.train_ratio, args.dev_ratio, args.seed)
    pairs.sort(key=lambda p: p.key)
    if args.offset:
        pairs = pairs[args.offset:]
    if args.limit:
        pairs = pairs[: args.limit]

    rows: list[dict] = []
    for i, pair in enumerate(pairs):
        try:
            row = eval_pair(pair, args)
        except Exception as e:  # keep the loop going; report the failure
            print(f"[{i + 1}/{len(pairs)}] {pair.key}  ERROR: {e}")
            continue
        if row is None:
            continue
        rows.append(row)
        print(f"[{i + 1}/{len(pairs)}] {pair.key}  "
              f"L1 note_f1={row['note_f1']:.3f}  "
              f"L2 app_note_f1={row['app_note_f1']:.3f} step_f1={row['app_step_f1']:.3f}  "
              f"ceil surv={row['ceiling_survival']:.2f} inkey={row['ceiling_inkey']:.2f}")

    summary = summarize(rows)
    print("\n=== SUMMARY ===")
    print(json.dumps(summary, indent=2))

    if args.csv:
        with open(args.csv, "w", newline="", encoding="utf-8") as fh:
            w = csv.DictWriter(fh, fieldnames=CSV_FIELDS)
            w.writeheader()
            for r in rows:
                w.writerow({k: r[k] for k in CSV_FIELDS})
        print(f"wrote {args.csv}")
    if args.summary_json:
        with open(args.summary_json, "w", encoding="utf-8") as fh:
            json.dump({"summary": summary, "config": vars(args) | {"root": str(args.root)}},
                      fh, indent=2, default=str)
        print(f"wrote {args.summary_json}")


if __name__ == "__main__":
    main()
