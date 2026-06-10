# Drum Pipeline 90% Plan

Goal: reach at least 90% `drum_f1` for the explicit drum/beatbox path.

## Metric

- Primary: `eval_drums.py` `drum_f1`
  - A prediction is correct only when onset is within tolerance and class matches.
  - Classes are normalized to `kick`, `snare`, `hihat`.
- Secondary:
  - `onset_f1`
  - `class_accuracy_on_matched_onsets`
  - `onset_mae_ms`

## Evaluation Splits

- Monophonic beatbox/product score:
  - Use single-instrument IDMT files or MIX files with `--collapse-ref-window`.
  - This matches the current product contract: one intended drum sound per vocal onset.
- Polyphonic ADT diagnostic:
  - Use raw IDMT MIX labels with no collapse.
  - This is not the product target until the backend can emit multiple drum notes at the same onset.

## Dataset Notes

- IDMT-SMT-Drums downloaded to `datasets/IDMT-SMT-DRUMS-V2`.
  - License: CC BY-NC-ND 4.0, evaluation only.
  - Best immediate fit for kick/snare/hi-hat.
- MDB Drums is next for broader class distribution.
- Groove/GMD is for groove/quantize preservation, not the first classifier target.

## Measured Baseline (2026-06-06)

### Harness fix (prerequisite)

The IDMT single-instrument `.svl` annotations store the drum class in the
**filename** (`#HH` / `#KD` / `#SD`); every point label is `New Point`. The
generic XML reader couldn't recover the class, so the monophonic split was
silently scoring ~0 (work items 1–2 below had never actually run). `eval_drums.py`
now has a dedicated `read_svl_events` that reads onset frames against the model's
own `sampleRate` and assigns the filename class. This unblocked the real numbers.

### Monophonic split — PRODUCT GATE (one drum per onset)

```powershell
python backend/eval_drums.py --root datasets/IDMT-SMT-DRUMS-V2 --key-not-contains "#MIX"
```

180 single-instrument files (WaveDrum):

- `drum_f1`: **0.916** ✅ (target 0.90 passed)
- `onset_f1`: 0.954
- `class_accuracy_on_matched_onsets`: 0.950
- `onset_mae_ms`: 13.6
- precision 0.944 / recall 0.890

Per class (recall / class-acc): KD 0.947 / 0.968 · HH 0.879 / **0.997** · SD 0.833 / 0.885.
Residual error is dominated by **onset recall** (missed hits), not classification.
Worst files are dense/fast WaveDrum snare rolls (`#SD`) where hits <80 ms apart
are merged away by `detect_onsets(min_interval_sec=0.08)`.

### Collapsed MIX — polyphony diagnostic (NOT the product gate)

```powershell
python backend/eval_drums.py --root datasets/IDMT-SMT-DRUMS-V2 --key-contains "#MIX" --collapse-ref-window 0.03
```

95 MIX files:

- `drum_f1`: 0.505 ❌
- `onset_f1`: 0.904 (onsets ARE found)
- `class_accuracy_on_matched_onsets`: 0.526 (blended kick+hat timbres confuse the classifier)

Interpretation: onset detection holds up on full kits, but the one-note-per-onset
product path can't represent simultaneous hits and the blended timbre breaks
classification. Out of product scope until the backend emits multiple drum notes
per instant.

## DOMAIN-GAP CAVEAT (the real open risk)

IDMT-SMT-Drums is **acoustic drums**, not voice. The product input is **phone-mic
vocal beatbox** ("boots and cats"), which is monophonic (matches the 0.916 split)
but timbrally different — and the `drums.py` thresholds were hand-calibrated on a
single Galaxy S10 beatbox take (upload_095). So 0.916 is an encouraging proxy and
upper bound, **not** a measured voice-beatbox accuracy. There is currently NO
labeled voice/beatbox benchmark — only unlabeled `_debug_uploads/*.wav` and one
`samples/5. 비트.wav`. Closing this is the highest-value next step and requires
on-device recording + labeling (kick/snare/hat takes + natural patterns).

## VOICE BENCHMARK — AVP (2026-06-06)

Downloaded **AVP (Amateur Vocal Percussion)**, the right-domain dataset: 28
amateur beatboxers, built-in laptop mic, monophonic, per-onset labels
(`kd/sd/hhc/hho`) in CSV — matches the product. CC-BY-4.0 (commercial OK).
`datasets/AVP_Dataset/AVP_Dataset`. Use this inner directory as the benchmark
root; the outer unzip folder also contains `__MACOSX` archive sidecars.
`eval_drums.py` reads its CSVs as-is (no adapter needed: `kd→kick`,
`sd→snare`, `hhc/hho→hihat`) and now ignores `__MACOSX`/`._*` metadata files.

### Headline (Improvisation files = natural beatbox patterns, 56 files)

```powershell
python backend/eval_drums.py --root datasets/AVP_Dataset/AVP_Dataset --key-contains "Improvisation"
```

- `drum_f1`: **0.484** ❌ (vs IDMT acoustic 0.916 — the domain gap is real)
- `onset_f1`: 0.830 · `class_accuracy_on_matched_onsets`: 0.607 · `onset_mae_ms`: 24.6
- By modality: **Fixed (standardized syllables) 0.554** vs **Personal (free) 0.412**.
  → Guiding users to fixed sounds ("boots-n-cats") is worth ~+14 pts f1.

### Confusion (Improvisation, matched onsets)

```
ref kick : 532→kick  235→snare   68→hihat   recall 0.64
ref snare: 207→kick  130→snare  381→hihat   recall 0.18   ← catastrophic
ref hihat: 159→kick   31→snare  830→hihat   recall 0.81
```

**Voiced snare is the killer** — 53% of snares are heard as hi-hat. Kick also
leaks (recall 0.64).

### V2 RF update (2026-06-06)

Added a v2 feature contract for the voice-drum model: v1's 10 spectral/decay
features are preserved for backward compatibility, while v2 adds normalized
narrow-band energy, body/air ratios, and early/body/tail temporal shape cues.
Runtime loading now prefers `models/drum_classifier_v2.npz` and falls back to the
existing `drum_classifier_v1.npz`.

Training command:

```powershell
python backend/train_drum_classifier_model.py --root datasets/AVP_Dataset/AVP_Dataset --out backend/models/drum_classifier_v2.npz --model rf --feature-set v2 --holdout-mod 4
```

Results:

- speaker-held-out classification accuracy: **0.818** (`drum_classifier_rf_v2_train.json`)
- held-out improvisation-only classification accuracy: **0.822**
- end-to-end AVP Improvisation `drum_f1`: **0.656** (`drum_avp_improv_v2_rf.json`)
- macro `drum_f1`: 0.653 · `onset_f1`: 0.830 · matched-onset class accuracy: 0.786
- split macro: Fixed **0.745**, Personal **0.562**

This is a real gain over v1 RF (macro `drum_f1` ~0.626, class accuracy ~0.754),
but the remaining gap is now dominated by onset precision/recall and highly
inconsistent personal syllables.

### Root cause — feature separability (AVP isolated files, ground-truth onsets)

Per-class medians (`diag_avp_features.py`):

| feature    | kick  | snare | hihat |
|------------|-------|-------|-------|
| centroid   | 2449  | 7572  | 8004  |
| rolloff    | 4846  | 12603 | 13137 |
| zcr        | 0.063 | 0.272 | 0.301 |
| high_ratio | 0.146 | 0.670 | 0.746 |

- **Snare ≈ hi-hat on every current feature** (~70% overlap). `diag_avp_probe.py`
  best single NEW discriminator `lowmid_200_2k` only reaches **0.70** balanced
  snare-vs-hat accuracy. Voiced snare/hat are genuinely close.
- **Kick is separable but mis-thresholded.** Current `KICK_CENTROID=1800` /
  `KICK_ZCR_MAX=0.08` were set on one S10 take; voice-kick median centroid is 2449
  (> 1800) and zcr p90 0.239, so half the kicks fall through → isolated kick
  recall only 0.39. `lowmid_200_2k` separates kick strongly (0.591 vs 0.07/0.02).

## Realistic Assessment of the 90% Target

- **One-sound-at-a-time IDMT (acoustic): already ≥90%.** The pipeline (onset +
  classifier) is sound; the engine is not the problem.
- **Free-form amateur VOICE beatbox: heuristic ceiling ~0.55** (measured). Hitting
  0.90 on unconstrained voice is blocked by intrinsic snare/hat timbre overlap and
  is unlikely with hand-tuned spectral thresholds alone.
- The realistic 90% path is a combination, not one knob.

## Work Items (re-prioritized by measured impact)

1. ~~Monophonic IDMT~~ 0.916 · ~~collapsed MIX~~ 0.505 · ~~build voice benchmark~~
   AVP wired in, baseline 0.484.
2. **Recalibrate KICK to voice** (data-backed, constraint-safe): raise
   `KICK_CENTROID`→~3200, `KICK_ZCR_MAX`→~0.12, and add a `lowmid_200_2k` energy
   ratio as the primary kick gate. Expect kick recall 0.39→~0.8. Expose the new
   feature per the debug-visibility contract (`AnalyzeResponse` + UI).
3. **Add `lowmid_200_2k` to the snare/hat split** (best available, ~0.70) and
   re-tune the hat gate so it stops eating snares (current `zcr≥0.30` dominance).
4. **Lift onset recall** (0.76 Personal / 0.83 Fixed): lower `delta` from 0.06 for
   soft voiced hits; re-check precision on AVP.
5. **Product-UX lever**: prompt users toward fixed syllables (kick="b/doo",
   hat="ts", snare="k/psh") — measured +14 pts f1 (Fixed vs Personal).
6. **DECISION NEEDED — to actually reach 90% on free voice**: either (a) accept the
   ~0.55–0.65 heuristic ceiling + UX guidance, or (b) allow a *small, locally-fit*
   classifier (e.g. logistic/GBT on these features, no cloud/deep-learning) to break
   the snare/hat overlap — this brushes the "no training" constraint and needs sign-off.
7. Keep drum quantize off by default; cap displacement and preserve groove phase.

## Local model v1 — built, measured, gated OFF (2026-06-06)

User approved a small local model (exception to "no training", drum-classifier only).
Built following the existing `train_*.py` + `models/*.npz` pure-numpy pattern (no
sklearn at serve time):

- `app/drum_features.py` — shared 10-feature vector (timbre axes + band-energy
  ratios + sustain), one source of truth for train and serve.
- `train_drum_classifier_model.py` — OVR logistic on AVP isolated onsets,
  **split by participant** (honest speaker-held-out score).
- `app/drum_classifier.py` — pure-numpy inference, `models/drum_classifier_v1.npz`.
- `app/drum_onset.py` — model-first in `build_drum_notes`, heuristic fallback.

Results:

- **Speaker-held-out classification (isolated onsets): 0.698** — kick recall
  0.39→**0.78**, snare 0.10→**0.47**, hihat 0.78. Big lift over the heuristic.
- **But end-to-end on improvisation it REGRESSES**: `drum_f1` 0.484→0.501 only,
  and snare recall **collapses 0.18→0.01** (model over-predicts kick: 509/718
  snares → kick). Acoustic IDMT also tanks (0.92→0.28).
- **Root cause: train/serve domain shift.** The model learns from *clean isolated
  ground-truth onsets*; at serve time it sees *detected-onset windows in
  continuous beatbox* (slightly early onsets → low-freq-biased → kick). Different
  feature distribution → broken.

**Decision: model is OFF by default** (`available()` requires
`HUMTRACK_DRUM_MODEL=1`). Production stays on the heuristic (improv 0.484, IDMT
0.916). The plumbing stays live for the next iteration.

**Next iteration to make the model ship-worthy:**
1. Harvest training data from **detected onsets** (run the onset detector over
   improv + isolated, match detections to labels within tolerance, take the
   matched window + label) — train on the serve-time distribution.
2. Hold out by participant; gate ship on improv `drum_f1` not isolated accuracy.
3. Consider a small GBT (nonlinear) once features are serve-aligned; linear caps
   snare/hat. Keep a voice-vs-acoustic guard so acoustic input isn't degraded.
4. Onset recall is still a hard cap (improv onset_f1 0.83) — pursue in parallel.

## Step 1+2 results — detected-onset retrain & onset analysis (2026-06-06)

### Step 1: retrain classifier on DETECTED onsets (fixed the train/serve shift)

`train_drum_classifier_model.py` now harvests windows at the onset-detector's
onsets, matched to labels within ±50 ms (serve-aligned). Trained on AVP improv +
isolated, split by participant:

- Speaker-held-out classification **0.735** (was 0.698 on ground-truth onsets);
  held-out **improv-only 0.750**. Snare recall no longer collapses.
- Direct serve-path (`predict_segment`) over all improv matched onsets: kick 0.78,
  **snare 0.40**, hihat 0.81. The model is now healthy — snare/hat overlap remains
  the residual (snare 326→hihat), not a collapse.
- End-to-end improv `drum_f1` 0.484→**0.509** (small, because onset is the cap).

### Step 2: onset detection is the dominant end-to-end cap

Onset-only sweep on improv (`diag_onset_sweep.py`) — recall is stuck ~0.83 across
`delta`/`min_interval`; loosening only adds false positives. The real lever is the
**amplitude gate** (`min_peak_ratio`), which was discarding soft voiced hits:

| gate | precision | recall | onset_f1 |
|------|-----------|--------|----------|
| 0.12 (current) | 0.556 | 0.834 | 0.667 |
| 0.06 | 0.492 | 0.939 | 0.646 |
| 0.03 | 0.438 | 0.982 | 0.606 |

Recall is recoverable to 0.94+, but at a steep precision cost (phantom hits). Onset
F1 does not improve — it is a pure recall↔precision trade.

## CORRECTION — accuracy DOES have algorithmic headroom (measured)

An earlier draft called ~0.55–0.65 a hard ceiling. That was a *linear,
speaker-independent, single-window* ceiling, not the real one.
`diag_accuracy_levers.py` measures untested levers on improv detected-onset
classification (matched onsets):

| approach | improv class-acc |
|----------|------------------|
| A) cross-speaker **linear** (current logistic) | 0.692 |
| B) cross-speaker **nonlinear (GBT)** | **0.730** (+0.04) |
| C) **within-speaker** (enroll on user's own isolated sounds) | **0.757** mean, median 0.768, **max 0.926**, min 0.435 |

So classification rises 0.69 → 0.73 (GBT) → 0.77 (per-user), and the most
consistent users already hit **0.93** with enrollment. Untested-but-promising:
richer features (MFCC/mel + deltas), and GBT pre-trained cross-speaker then
*adapted* per-user (transfer + personalization) — likely beats both C and B.

Real accuracy levers, ranked:
1. **Per-user enrollment** (biggest, and it's the AVP dataset's design intent):
   ask the user once to record their kick/snare/hat; classify their beats against
   their own templates. Turns the hard cross-speaker problem into an easy
   within-speaker one. Best users → 0.93.
2. **Nonlinear model (GBT)** — +0.04 for free, user already approved it.
3. **Richer features** (MFCC/mel/contrast/deltas) — untested headroom.
4. **Onset recall** is recoverable (0.83→0.94+) but trades precision.

## Residual hard part — what still bounds end-to-end drum_f1

Two stages multiply, so both must be high:
- onset_f1 ≈ 0.83 at usable precision (recall recoverable to 0.94+ via the gate,
  but precision trades → phantom hits).
- class-acc: 0.69 (current linear, no enrollment) → 0.73 (GBT) → 0.77 typical /
  0.93 best (per-user enrollment).

So end-to-end `drum_f1` today (no enrollment, linear) ≈ 0.5; with **GBT +
per-user enrollment + a chosen recall/precision point** a realistic target is
~0.75–0.85 for cooperative/consistent users, and ~0.9 for the most consistent.
A clean speaker-independent 0.90 on *arbitrary, inconsistent* amateur voice is
still at/beyond research SOTA (some users are intrinsically inconsistent — see the
0.435 within-speaker floor). The number is a function of HOW the user beatboxes,
not a single fixable bug.

### Recommended path (combine — none alone reaches the goal)
1. **Per-user enrollment** (biggest accuracy lever): record the user's own
   kick/snare/hat once, classify against their templates. Best users → 0.93.
2. **GBT classifier** (user-approved) + **richer features** (MFCC/mel/deltas).
3. **Constrain input via UX** — standardized syllables measured **Fixed 0.554 vs
   Personal 0.412** (+14 pts): teach "boots-n-cats" (kick=b/doo, hat=ts, snare=k/psh).
4. **Pick the onset recall/precision point deliberately** and lean on the existing
   editor for the rest.
5. **Ship the detected-onset model** (healthy now) after exposing its debug
   features (debug-visibility contract).

## Per-user enrollment experiment (Path A) — measured (2026-06-06)

`diag_enrollment.py`: simulate "record your own kick/snare/hat" (first k isolated
hits per class), classify the user's improv. Strategies — `proto` (per-user
nearest-prototype, pure-numpy, shippable), `gbt` (per-user GBT), `hybrid`
(cross-speaker GBT + the user's k examples, upweighted ×40):

| k/class | proto | gbt(within) | hybrid |
|---------|-------|-------------|--------|
| 3  | 0.656 | 0.304 | 0.739 |
| 5  | 0.654 | 0.304 | 0.736 |
| 8  | 0.643 | 0.304 | 0.746 |
| 15 | 0.640 | 0.615 | 0.749 |

Findings:
- **Enrollment helps only modestly.** Cross-speaker GBT alone is 0.730; hybrid
  with enrollment is ~0.74–0.75 — a real but small +0.01–0.02, even with the
  user's examples upweighted ×40. Personalization can't fix users whose *own*
  snare and hi-hat overlap (the within-speaker floor is 0.435; ceiling 0.926).
- **Good UX news: only ~3 examples/class needed** — hybrid is flat from k=3.
- **Per-user GBT is broken at low k** (0.30 until k≥15) — too little data to train
  a tree per user; never train a fresh per-user model on a handful of examples.
- **The pure-numpy `proto` (shippable, no training) is 0.65** — below cross-speaker
  GBT; only attractive as an on-device option, not for headline accuracy.

Conclusion on Path A: enrollment is a cheap, optional nicety (helps consistent
users toward their 0.85–0.93 personal ceiling) but is **not** the big lever its
premise suggested. The better bang-for-effort is shipping the **GBT** (0.69→0.73,
zero user friction) and **richer features**; enrollment is a follow-on for power
users, not the foundation.

## Path B — RandomForest classifier shipped to serve (2026-06-06) ✅ real win

GBT/forest beats the linear model and is exportable to pure numpy. Trained a
RandomForest (200 trees, depth 12) on AVP detected onsets; serialized every tree
(children/feature/threshold + leaf class-probs) into the existing `.npz`, and added
a pure-numpy forest traversal to `drum_classifier.py` (no sklearn at serve, 1.6 MB).

- Speaker-held-out classification **0.769** (logistic 0.735), improv-only **0.795**.
- **End-to-end improv `drum_f1` 0.484 → 0.618** (heuristic→RF), class-acc 0.607 → **0.754**.
- Confusion now healthy/balanced — kick 0.77, **snare 0.62** (was 0.18 heuristic /
  0.01 in the broken v1), hihat 0.80. No collapse.
- sklearn is dev/train-only; serve path stays pure numpy.

This is the biggest single-lever win measured: +0.134 drum_f1 (+28% relative), zero
user friction. Onset_f1 (0.83) is now the remaining cap (drum_f1 ≈ 0.83 × 0.754).

**DEFAULT-ON shipped (debug-visibility contract honored):**
- `drum_classifier.available()` now defaults ON; `HUMTRACK_DRUM_MODEL=0` disables
  (fallback to the heuristic, e.g. for acoustic-drum input).
- The 4 new decision features (`drum_lowmid_ratio`, `drum_mid_ratio`,
  `drum_vhigh_ratio`, `drum_sustain_ratio`) are exposed in `Note` (schemas.py),
  populated in `drum_onset.py` from the exact vector the model classifies, mirrored
  in `frontend/src/types.ts` + a `NoteTable` column, and in `mobile` `models.dart`.
- Verified: default-ON eval improv `drum_f1` 0.618 (no env); `=0` → heuristic 0.484;
  frontend `tsc` clean.

## Tooling added this session

- `eval_drums.py`: `read_svl_events` (IDMT single-instrument `.svl` class-from-filename).
- `diag_avp_features.py`: per-class voice feature percentiles + isolated confusion.
- `diag_avp_probe.py`: candidate new-feature separability for snare-vs-hat.
- Result CSV/JSON in `docs/experiments/drum_*`.
