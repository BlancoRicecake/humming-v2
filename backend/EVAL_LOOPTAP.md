# LoopTap engine→app accuracy harness

Measures the **full LoopTap hum-to-MIDI path** on HumTrans — the loop-grid engine
(`loop_quantize` → integer `step`/`dur_steps`) **plus** the app-side octave-fold +
in-key ladder snap — so we can tell whether a miss is the engine's fault or the
app mapping's. Unlike `eval_humtrans.py` (raw engine notes only), this covers the
mapping the LoopTap UI actually applies.

## Pieces

- `app/looptap_map.py` — Python mirror of the Dart conversion
  (`mobile/lib/looptap/music/hum_map.dart` = `phraseOctaveShift` / `snapToLadder` /
  `drumKind`, and `theory.dart` `buildLadder`). **Keep in sync with Dart.**
- `eval_looptap.py` — the harness (oracle reference + 2 layers + ceiling).
- `tests/test_looptap_map.py` — Python unit tests; emits the golden vectors.
- `mobile/test/looptap/hum_map_parity_test.dart` — checks Dart matches the golden,
  so the two implementations can't drift.

## Run

```powershell
# dev baseline (2-layer + ceiling), save CSV + summary
.\.venv\Scripts\python eval_looptap.py --root <HumTrans> --split dev --limit 30 `
    --csv looptap_eval_dev.csv --summary-json looptap_summary_dev.json

# fast Layer-2-only A/B (skips the raw engine pass)
.\.venv\Scripts\python eval_looptap.py --root <HumTrans> --split dev --limit 30 `
    --layers app --pitch-model pyin
```

`<HumTrans>` = `C:\Users\jlion\Documents\Humtrack\datasets\HumTrans`.

## What the metrics mean

- **Layer 1 (engine):** raw engine notes vs ground truth — `note_f1`, `onset_f1`,
  `onset_pitch_acc`, `pitch_mae_st`. The foundation `eval_humtrans.py` also reports.
- **Layer 2 (app mapping):** predicted app notes (engine step + ladder snap) vs an
  **oracle** = ground truth quantized to the same grid+ladder = best the app could
  represent. `app_step_f1`, `app_note_f1`, `app_pitch_acc`, `app_pc_acc`.
  - **`_t1` variants = ±1-step tolerant.** Because HumTrans is free-rhythm (no
    count-in), a single tempo can't track intra-phrase drift, so correct notes tip
    one 16th early/late. The **real app locks tempo via count-in**, so the `_t1`
    metrics are the most real-app-representative.
- **Ceiling:** how much the grid+ladder representation itself loses vs the true
  melody (`survival` = grid-collision retention, `inkey` = fraction already in key).
  Near 1.0 here, so the oracle is a faithful target.

## Baseline (pYIN, autocorr tempo fit, mean octave shift) — 2026-06-11

| metric | dev 30 | test 30 |
|---|---|---|
| Layer1 note_f1 / onset_f1 | 0.037 / 0.473 | 0.043 / 0.446 |
| app_step_f1 (tol=0) | 0.527 | 0.703 |
| app_note_f1 (tol=0) | 0.487 | 0.660 |
| **app_note_f1 (±1)** | **0.898** | **0.910** |
| **app_step_f1 (±1)** | **0.959** | **0.967** |
| app_pitch_acc | 0.925 | 0.938 |
| ceiling survival / inkey | 0.999 / 0.966 | 0.996 / 0.972 |

**Read:** the engine→app conversion preserves the melody well (±1 note ~0.90); the
in-key ladder snap recovers the raw engine pitch error (Layer-1 MAE ~2.1 st →
app pitch acc ~0.93). tol=0 step is dominated by free-rhythm drift, not real-app.

## Iteration log

- **Tempo fit (accepted):** median-IOI → onset-autocorrelation beat estimate.
  tol=0 step 0.48→0.53, pitch 0.84→0.86; generalized to test. The grid now matches
  the performance instead of a crude guess.
- **CREPE pitch (rejected):** vs pYIN gave +0.002 pitch acc (no gain), −0.009 on
  ±1 note, much higher latency. The pitch ceiling is not tracker-bound; octave-fold
  is already fine (pc≈pitch). Stay on pYIN.
- **Mean phrase-octave-shift (accepted, 2026-06-11):** `phraseOctaveShift` median
  → arithmetic mean (hum_map.dart + looptap_map.py, golden regenerated). The
  median is knife-edged: near the ÷12 rounding boundary a 1-st difference between
  the engine's and the melody's median flips the WHOLE phrase by an octave —
  diag_looptap_pitch.py showed one such sample held 33% of all dev30 pitch errors
  (GT median exactly on the 0.5 boundary). Rule A/B (diag_looptap_octave.py,
  dev100, symmetric pred/oracle): mean beats wmedian/snap-cost-argmin — shift
  agreement 0.94→0.96. Result: ±1 note 0.864→0.898 (dev) / 0.870→0.910 (test),
  pitch acc 0.863→0.925 / 0.893→0.938.
- **Raw-pitch (continuous) ladder snap (rejected, 2026-06-11):** snapping
  pitch_raw directly to the ladder instead of the assistant-corrected int pitch
  is a wash (+0.001): it fixes 15 notes but breaks 14 others on dev30. The
  assistant's chromatic decision is already net-positive (pre-assistant
  pitch_original snap scores −2.4%p).

## Untried levers (diminishing returns)

- Retrain `learned_pitch_correction` on HumTrans for the residual ~7% pitch errors
  (post-octave-fix taxonomy: mostly raw-far detection errors, hard).
- Onset/segmentation work to raise tol=0 step recall (mostly a free-rhythm artifact;
  the real app already mitigates via count-in).
