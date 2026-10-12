# HumTrack AI arrangement roadmap

## Product rule

HumTrack helps a beginner turn one hummed idea into a small song they can
understand and edit. The original melody remains the user's work. Generation
suggests accompaniment around it and always returns editable symbolic notes.

The first release flow is:

1. Hum or import a melody.
2. Compare the raw pitch with HumTrack's corrected pitch.
3. Review only low-confidence notes; fix an octave, split, or merge in one tap.
4. Lock the melody.
5. Hear three chord/accompaniment candidates.
6. Choose one and keep editing/exporting MIDI, WAV, and stems.

## Implemented foundation

- Every detected note preserves `sourceMidi`, correction confidence, whether an
  assistant changed it, and whether it is locked.
- SongSpec v1 is the model-neutral JSON boundary used by mobile and backend.
- The backend feature flag defaults to off and checks that a provider did not
  alter a locked melody. Enabled generation also requires a verified user JWT.
- The deterministic on-device beginner backing now gives three chord variants.
  This remains the instant fallback when no remote provider is configured.
- Basic Pitch has a separate held-out benchmark entry point. The existing
  five-sample comparison already rejected it as the default: it over-split
  legato humming and produced harmonic ghost notes, although it corrected one
  pYIN octave error. The production route remains pYIN.

## YuE2 boundary

**Corrected 2026-10-12.** The earlier statement here ("weights use CC BY-NC 4.0")
is out of date. Since 2025-01-30 the YuE code **and weights** are released under
Apache-2.0. The model card encourages commercial use of outputs, asks for the
credit "YuE by HKUST/M-A-P", and states that users are solely responsible for
generated content. (Checked 2026-10-12 on the GitHub repo and the
`m-a-p/YuE-s2-1B-general` model card.)

The license is no longer the blocker. These still are:

- **Training data is undisclosed.** 2025–2026 litigation (UMG/Sony v. Suno,
  GEMA v. Suno) turns on training-data provenance, so the production gate
  "training data permits commercial use" below cannot be passed yet.
- **Hardware/cost.** The baseline needs about 24 GB GPU memory; local inference
  on the 8 GB dev GPU is not supported, so any test needs a rented cloud GPU.
- **Product rule.** YuE turns lyrics into a whole song. HumTrack's rule is that
  the hummed melody stays the user's work, so YuE may only be evaluated as an
  optional, clearly labelled AI suggestion that respects melody lock.

Decision (Heo, 2026-10-12): YuE is an **experiment candidate only** — internal
accounts behind `ARRANGEMENT_ENABLED=1`, outputs labelled as AI-generated, never
shipped to users until every production gate below passes. Until then no YuE
source, weight, checkpoint, or generated asset is copied into the product
repository.

Primary references:

- YuE2 repository and license: https://github.com/multimodal-art-projection/YuE
- YuE2 model card: https://huggingface.co/m-a-p/YuE-s2-1B-general
- Basic Pitch repository and license: https://github.com/spotify/basic-pitch

## Hardware and experiment policy

This Windows machine has an 8 GB RTX 5060. The official YuE2 baseline describes
24 GB GPU memory, so local YuE2 inference is outside the supported target. A
smaller commercially compatible provider or model can be tested later through
the SongSpec adapter, without changing saved projects or the editor.

Research dependencies stay in `backend/requirements-research.txt`; they are not
part of the production image. Basic Pitch 0.4's package metadata still requires
TensorFlow on Python 3.12 even though it ships an ONNX model. On this machine we
validated that model with `basic-pitch --no-deps` plus `onnxruntime`; use Python
3.11 for the supported one-command installation. A candidate reaches production
only after:

- held-out quality and latency results are saved;
- melody-lock invariants pass;
- its code, weights, training data, and output terms permit commercial use;
- cloud cost and cancellation/fallback behavior are measured.

## Next gated milestones

1. Restore the HumTrans paired dataset and use `eval_basic_pitch.py` only to
   decide whether Basic Pitch is useful as a low-confidence fallback. Require a
   monophonic filter and amplitude gate; do not replace the pYIN default.
2. Test the guided flow with five beginners and measure completion, correction,
   candidate selection, export, and second-song rates.
3. Select one commercial-safe symbolic arrangement provider or small model.
4. Run it behind `ARRANGEMENT_ENABLED=1` for internal accounts only. YuE
   (Apache-2.0, training data undisclosed) may be tested here as an
   experiment candidate on a rented GPU; it cannot pass the production gate
   until its training-data terms are known.
5. Add audio continuation only after the symbolic workflow proves retention and
   after rights and per-generation cost are signed off.
