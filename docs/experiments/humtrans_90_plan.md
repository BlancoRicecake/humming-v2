# HumTrans 90% Accuracy Plan

## HONEST FULL-DEV BASELINE (2026-06-06) — supersedes the small-set numbers below

Measured on the **full dev split (1461 files)** from `cache/v1` with
`--align-time --normalize-key` (normalize-key is REQUIRED; without it octave
errors explode 26 -> 2652 and note_f1 collapses to 0.336):

- Note F1: **0.517**  (macro == micro)
- Onset F1: **0.793**
- Onset pitch accuracy: **0.713**
- Onset offset accuracy: 0.760
- Offset-fixed upper F1: **0.608**
- errors: missed_onset 8487 / extra_onset 7220 / wrong_pitch 7293 /
  bad_offset 3740 / merged 770 / false_split 1280 / octave 26

Cross-check (same 20 files as the old `humtrans_eval_dev20_aligned.csv`):
current engine macro f1 **0.745** vs recorded **0.611** -> NO regression; the
current WIP is actually better on the F01 window. The drop to 0.517 on full dev
is pure small-set overfitting: the first-20 (single speaker F01) is far easier
than the full 1461-file, multi-speaker distribution. The numbers below
(test20 0.776, dev windows 0.695-0.796) were measured on that easy slice.

**Real gap to 0.90 is +0.38, not +0.12.** All three layers must move:
onset segmentation (0.793), pitch (0.713), offset (structural).

### Phase-C feasibility probe (candidate coverage, full dev cache)
`backend/diag_candidate_coverage.py` — measures what fraction of REF notes is
reachable by the current boundary candidates (onset_proxy>=0.25, pitch-change
>=0.70st, RMS-dip<=0.82*median, pred boundaries). This is the hard ceiling on
selector recall (R3).

- onset-reachable    = **0.903** (full dev) / 0.849 (first 300) — boundary START
  generation is decent but caps ~0.85-0.90: ~10-15% of true onsets have NO
  candidate boundary near them (hard floor, span-independent).
- segment-reachable (onset+offset) = **0.665** default span8 / **0.736** with
  span16+maxdur4 (at 2.4x candidate blow-up). ~26-34% of true note ENDS are not
  reachable -> the note-end/offset evidence is the fundamental gap.
- (level-3 exact-pitch coverage is NOT a valid ceiling here: it uses raw median
  pitch + one global shift and ignores the pitch assistant, so it reads 0.349 <
  actual recall 0.509. Use onset/segment levels only.)

**CORRECTION (boundary R&D, `backend/diag_boundary_rnd.py`):** the 0.66-0.74
figure above was a SPAN-ENUMERATION artifact, not an evidence limit. Measuring
boundary presence span-independently (does ANY boundary land within tol of the
ref onset / ref end) tells a much better story:

| boundary config | onset-present | offset-present | both (ceiling) |
|---|---|---|---|
| baseline (onset>=0.25) | 0.849 | 0.944 | 0.804 |
| onset0.15 + energy-decay-offsets(0.5) | 0.948 | 0.985 | 0.934 |
| onset0.12 + decay0.5 + dips0.92 + pitchΔ0.5 | 0.960 | 0.988 | **0.948** |

So the **segmentation EVIDENCE ceiling is ~0.95**, comfortably above 0.90. The
real fixes are cheap-ish: (a) lower the onset_proxy threshold 0.25 -> ~0.12, and
(b) add energy-decay note-end boundaries (offset evidence was actually already
present 0.944, but onset evidence and start/end PAIRING were the gaps). The
remaining work to realize the ceiling is a better candidate ENUMERATION (pair
onset-type with nearby offset-type boundaries instead of all-pairs span-8) + a
selector.

**Revised feasibility verdict:** segmentation is NOT the blocker — its evidence
ceiling is ~0.95. The real binding constraint for note_f1>=0.90 is now the
**pitch layer**: onset_pitch_acc is only 0.713 post-assistant, and note_f1 ~=
seg_recall x pitch_acc x offset_ok. To hit 0.90 we need pitch_acc ~0.95 (octave
errors already low at 26 with normalize-key, so the misses are +/-1-2 st sung/
tracked pitch). CREPE is the main lever to quantify next.

### Pitch-lever probe (CREPE vs pYIN + pitch-tol diagnostic)
Same 200-file dev slice (offset 1200, M04/M05 speakers; cleaner than full dev):

| metric | pYIN | CREPE | pYIN @pitch_tol=1 |
|---|---|---|---|
| note f1 | 0.618 | 0.597 | 0.708 |
| onset f1 | 0.880 | 0.869 | 0.880 |
| onset_pitch_acc | 0.802 | 0.787 | **0.930** |
| onset_pitch_mae | 0.33 st | 0.37 st | — |
| offset-fixed upper | 0.708 | 0.686 | 0.819 |

- **CREPE is DEAD as a lever** — slightly worse than pYIN on every metric (octave
  errors already 1, nothing to fix). The pitch problem is DECISION, not tracking.
- **But raw pitch is within +/-1 st of the reference 93% of the time** (tol=1 ->
  onset_pitch_acc 0.930). So a perfect in-key "neighbor snapper" could reach
  ~0.93 exact. The current pitch assistant gets 0.80 -> there is **~+0.13
  headroom in the pitch-DECISION/assistant layer** (better key context, voice
  leading, scale inference) WITHOUT relaxing the exact-pitch metric.

### Overall feasibility for note_f1 >= 0.90 (exact pitch)
note_f1 ~= seg_recall x pitch_acc x offset_ok. Best-case with both axes pushed:
seg ~0.95 x pitch ~0.93 x offset ~ -> **~0.85-0.88 realistic, 0.90 at the edge.**
Levers ranked: (1) segmentation boundary R&D + selector (certain, large), (2)
pitch-assistant/snapping R&D toward the 0.93 raw ceiling (uncertain, +0.13 cap),
(3) CREPE — RULED OUT. Pure acoustics cannot exceed ~0.80 exact because humming
is sung ~+/-1 st off and the reference is the *intended* note.

### Sequence-selector v0 result (2026-06-06) — from-scratch re-segmentation FAILS
Built the full selector pipeline (`backend/seq_candidates.py` enriched-boundary
candidates w/ coverage 0.725; `train_sequence_selector.py`; `eval_sequence_
selector.py` WIS-DP non-overlap select). End-to-end on a held-out M-speaker dev
slice (trained on F01-100):

| tau | sel/file (ref~28) | note_f1 | onset_pitch_acc |
|---|---|---|---|
| 0.5 | 67 | 0.215 | 0.401 |
| 0.7 | 48 | 0.241 | 0.482 |
| 0.85 | 22 | 0.140 | 0.426 |

All **far below the 0.517 baseline.** Causes: (1) candidates carry RAW median
pitch — the selector bypasses the pitch assistant, so pitch craters 0.71->0.40;
(2) DP over-selects (precision 0.15); (3) tiny cross-dist training. But the
**strategic lesson** is bigger: the existing pipeline already segments well
(onset_f1 0.793). A from-scratch re-segmentation selector underperforms the
tuned pipeline. **Pivot:** instead of replacing segmentation, REFINE the
existing pred notes — (a) energy-decay note-END correction (the structural
offset fix; offset evidence presence is 0.99), and (b) pitch-assistant R&D for
the 0.71->~0.84 headroom — both operate on the already-good 0.517 pipeline.

### Offset refinement attempts (full dev) — both near-null
- Energy-decay note-END refinement (`eval_humtrans --refine-offsets`): HURTS
  (0.517 -> 0.509@decay0.4 / 0.500@decay0.5; duration_mae 41 -> 68/74ms). The
  reference note end is the *intended* musical duration, not acoustic energy
  decay, so decay points are worse than the current chunk-end. Offset is
  intrinsically hard (confirms A3 structural).
- Learned offset model (offset_correction_v1) on full dev: 0.517 -> **0.521**
  (+0.004, 3.7 changes/file). Tiny but real cross-validated (vs the test20-only
  rejection before). Keep as a minor contributor.

### Pitch-assistant diagnosis (full dev, 30812 onset-matched notes)
| category | share | lever |
|---|---|---|
| correct | 76.3% | — |
| assistant BROKE it (raw right, assisted wrong) | 2.6% (795) | over-correction; safe recover |
| raw within +/-1, still wrong | 9.0% (2773) | better snapping; partial recover |
| raw off >=2 (hard) | 12.1% (3725) | mostly unfixable |

raw err dist: exact 69.5%, within +/-1 87.8%, >=2 12%. Perfect-snapping pitch
ceiling ~88% (lower than the clean slice's 93%). The actionable pitch lever is
(1) reduce over-correction (the 2.6% the assistant breaks) and (2) better in-key
snapping for the 9% raw-within-1. Realistic pitch gain ~+3-5% -> note_f1 +~0.03-0.05.

### REALISTIC CEILING (full dev, exact pitch) — corrected down
Earlier "0.85-0.88 edge" was based on the cleaner M-speaker slice (pitch 0.80,
raw+/-1 0.93). On the FULL dev distribution (pitch 0.71, raw+/-1 0.88, 12% hard
pitch errors), with ALL viable levers (offset model +0.004, pitch-assistant
+~0.04, any segmentation refinement), realistic note_f1 lands **~0.60-0.70**, not
0.85. **0.90 exact on full HumTrans dev is not attainable** — it's a genuinely
hard, multi-speaker, off-pitch humming distribution where the reference is the
*intended* melody. Dead ends ruled out: CREPE, from-scratch selector,
energy-decay offset. Live levers: pitch-assistant conservatism + snapping.

### Pitch-assistant conservatism test (M-slice rebuild) — NEGATIVE
Rebuilt the M-speaker slice with `--no-assist-aggressive` (cache/v1_noaggr) and
compared on the same files:
- aggressive ON  (v1):     note_f1 0.597, onset_pitch_acc 0.798
- aggressive OFF:          note_f1 0.593, onset_pitch_acc 0.794  (WORSE)
- aggressive OFF + offset model: 0.597

So aggressive in-key snapping is **net positive** — it fixes more than it breaks.
The "assistant broke 2.6%" proxy was misleading (correction_cents ~0 -> mostly
.5-rounding-boundary artifacts, not real over-corrections). **The pitch assistant
is already well-tuned.** No easy pitch win by toggling conservatism; better
snapping would need a genuinely smarter pitch-decision model (melodic n-gram /
harmonic context), i.e. real R&D, not a knob.

### DEFINITIVE CONCLUSION (2026-06-07)
The existing pipeline (full-dev note_f1 0.517) is **near a local optimum for its
architecture.** Every modest lever tried is null-or-negative:
- offset learned model: +0.004 (only confirmed positive; tiny)
- energy-decay offset refine: negative
- assist-aggressive off: negative
- CREPE pitch: negative
- from-scratch sequence selector: far negative (0.24 vs 0.517)

0.90 exact on full HumTrans dev is unattainable (pitch ceiling note_f1<=onset_
pitch_acc, full-dev ~0.71; realistic with real R&D ~0.60-0.70). Meaningful gains
require a fundamentally better pitch-DECISION layer (the only axis with headroom),
which is open-ended research with payoff capped ~0.71 and uncertain. The
measurement foundation, diagnostics, and ruled-out dead-ends are the durable
deliverable. Temp caches: cache/v1_crepe (200), cache/v1_noaggr (261).

### A3 offset diagnosis (full dev, runs/dev_baseline_details)
- offset_delta median **+1.0 ms**, duration ratio pred/ref **0.994** -> NO
  systematic bias. mean -23.9ms, stdev 213ms, bad_offset 15.9% of onset+pitch
  -correct notes, fat symmetric tail (both end-early and end-late).
- Verdict: **global/median offset calibration is OFF the table** (nothing to
  shift). Offset errors are structural mis-segmentation -> only a better
  note-decision layer (Phase C) or segmentation fix can move offset.

---

## (Superseded) prior small-set best — kept for history

Current best independent test20 result:

- Engine: integrated learned pitch correction v1, no offset/split model
- Note F1: 0.776
- Onset F1: 0.937
- Onset pitch accuracy: 0.922
- Offset-fixed upper F1: 0.880

Rejected experiments:

- Offset correction model: test20 F1 0.779, too small and risky for default use.
- Split candidate model, local pitch: test20 F1 0.767.
- Split candidate model, original pitch: test20 F1 0.775.
- Split candidate model, conservative pitch: test20 F1 0.769.
- Pitch correction v3 with classes -2,-1,0,1,2: test20 F1 0.771.

Decision:

- Keep pitch correction v1 integrated.
- Keep learned offset correction opt-in until full-dev validation passes.
- Do not integrate split models into the app yet.
- Do not replace v1 with the +/-2 pitch model.

Implemented pipeline baseline:

- App default: `learned_pitch_correction=True`, `learned_offset_correction=False`.
- Canonical split: `datasets/HumTrans/humtrans_manifest.csv`.
- Pair discovery now prefers the official `all_wav.zip` / `all_midi.zip` files when
  they exist, so partial extracted folders cannot silently shrink evaluation.
- Cache location: `datasets/HumTrans/cache/v1/{split}/{key}.json.gz`.
- Cache builder: `backend/build_humtrans_cache.py`.
- Cached eval: `backend/eval_humtrans.py --cache-dir <cache/v1>`.
- Error taxonomy is reported in eval summary JSON under `errors`.
- Sequence candidate extraction starts from cache:
  `backend/extract_humtrans_sequence_candidates.py`.
- Rolling window validation:
  `backend/run_humtrans_windows.py --split dev --window-size 10 --windows N`.

Current dev rolling-window check:

| Window | Samples | Note F1 | Onset F1 | Onset pitch acc | Main errors |
|---|---:|---:|---:|---:|---|
| dev_w01 | 1-10 | 0.695 | 0.908 | 0.867 | wrong_pitch 29, missed_onset 23, bad_offset 20 |
| dev_w02 | 11-20 | 0.796 | 0.956 | 0.947 | bad_offset 30, wrong_pitch 17, missed_onset 12 |
| dev_w03 | 21-30 | 0.792 | 0.930 | 0.937 | bad_offset 23, missed_onset 22, wrong_pitch 15 |

This confirms that optimizing on a small repeated test set is misleading. The
first 10 dev files are much harder than the next 20, and the dominant failure
type changes by window.

Smoke commands:

```powershell
$env:PYTHONPATH='C:\Users\jlion\Documents\Humtrack\Humming V2\backend;C:\Users\jlion\Desktop\Humming V2\backend\.venv\Lib\site-packages'
& 'C:\Users\jlion\AppData\Local\Programs\Python\Python311\python.exe' 'backend\build_humtrans_cache.py' --root 'C:\Users\jlion\Documents\Humtrack\datasets\HumTrans' --split dev --limit 3 --cache-dir 'C:\Users\jlion\Documents\Humtrack\datasets\HumTrans\cache\v1' --align-time
& 'C:\Users\jlion\AppData\Local\Programs\Python\Python311\python.exe' 'backend\eval_humtrans.py' --root 'C:\Users\jlion\Documents\Humtrack\datasets\HumTrans' --split dev --limit 3 --align-time --cache-dir 'C:\Users\jlion\Documents\Humtrack\datasets\HumTrans\cache\v1'
& 'C:\Users\jlion\AppData\Local\Programs\Python\Python311\python.exe' 'backend\extract_humtrans_sequence_candidates.py' --cache-dir 'C:\Users\jlion\Documents\Humtrack\datasets\HumTrans\cache\v1' --split dev --limit 3 --out 'C:\Users\jlion\Documents\Humtrack\datasets\HumTrans\features\sequence_candidates_dev3_smoke.csv'
```

Next structural direction:

1. Move from frame-level split classification to note-level candidate selection.
2. Generate multiple possible note sequences from envelope, pitch contour, and onset evidence.
3. Score whole note candidates with features for pitch stability, attack evidence, duration, neighboring intervals, and key context.
4. Pick a non-overlapping sequence with dynamic programming/Viterbi-style decoding.
5. Train and evaluate this sequence selector on larger HumTrans train/dev splits before touching app defaults.

Reason:

The current onset detector is already high, but final note F1 is limited by pitch and offset agreement. Small post-correction models help a little, but false corrections quickly erase the gains. A 90% target needs a better note-decision layer, not more independent cleanup rules.

Immediate app-facing fixes:

- First-note playback: clamp tiny negative starts to 0 in render paths.
- First-note playback: enforce a small synth-only minimum audible duration so
  a visible note is not scheduled as a near-zero-length note.
- First-note playback: fire simultaneous sequencer events as awaited batches,
  with note-off events before note-on events at the same time.
- Piano/chord/bass over-splitting: after pitch assistant/model correction,
  merge conservative same/near-pitch fragments again because correction can
  turn jitter fragments into repeated rendered attacks.

Next implementation steps:

1. Build enough cache for full `dev` first, then `train`, so model iteration
   does not re-run the analyzer for every experiment.
2. Use rolling dev windows as the daily regression gate: optimize on one set,
   validate on the next unseen window, and reject changes that improve only the
   tuned window.
3. Train a note-sequence selector from cached candidates. The model should
   decide between keeping, merging, or splitting candidate notes rather than
   applying independent pitch/offset/split corrections.
4. Add role-aware app defaults only after full-dev stability is proven:
   chord/keys should prefer fewer repeated attacks, bass should prefer stable
   sustained fundamentals, and fast melody should preserve real changes.
5. Run full test once only after thresholds/model are frozen. The target metric
   remains `HumTrans full test note_f1 >= 0.90`.
