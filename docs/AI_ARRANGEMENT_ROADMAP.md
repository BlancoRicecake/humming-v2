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

The YuE2 repository code is Apache-2.0, while the published model weights use
CC BY-NC 4.0 and also require permission from the individual audio creators for
generated songs. A paid HumTrack feature must not bundle, host, fine-tune, or
serve those weights without a separate commercial agreement covering both
model weights and the relevant output rights.

Safe work in this branch is limited to ideas and interfaces: hierarchical song
planning, structured section/chord conditioning, editable outputs, and
objective evaluation. No YuE2 source, weight, checkpoint, or generated asset is
copied into HumTrack.

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
4. Run it behind `ARRANGEMENT_ENABLED=1` for internal accounts only.
5. Add audio continuation only after the symbolic workflow proves retention and
   after rights and per-generation cost are signed off.
