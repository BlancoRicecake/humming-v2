# Humming V2 — voice-to-MIDI MVP

Local-first web app that turns a humming recording into a single-line MIDI.
Inspired by Dubler 2, but offline: record in the browser → analyze in a Python
backend → visualize the result and export `.mid`. No cloud, no paid APIs.

## Status
- [x] Stage 1 — humming → monophonic MIDI (onset segmentation + pitch median)
- [x] Stage 2 — key/scale quantization + optional tempo-grid quantize
- [x] Stage 3 — ghost-note filtering + consecutive same-pitch merge
- [x] Stage 4 — legato/staccato auto-classification
- [x] **+** pitch bend export, MIDI sanitization, SoundFont preview (FluidSynth)
- [ ] Stage 5 — drum trigger few-shot prototype
- [ ] Stage 6 — chord generation
- [ ] Stage 7 — realtime WebSocket prototype

## Layout
```
backend/
  app/
    main.py        FastAPI entry — /analyze /export_midi /render_audio /render_capabilities
    analyze.py     load → onset (HPSS) → pyin → voiced gating → segments → quantize → articulation
    onset.py       librosa onset detection (HPSS-aware) + tempo estimate
    pitch.py       pYIN (auto frame_length) + optional torchcrepe backend
    scales.py      diatonic / modal / pentatonic quantizer
    grid.py        tempo-grid quantizer
    midi_build.py  articulation transform + pitch-bend events + pretty_midi export
    render.py      FluidSynth direct (bypasses pretty_midi.fluidsynth) for SF2 playback
  bin/             bundled FluidSynth 2.5.4 win64 portable (auto-downloaded at scaffold time)
  tests/           pytest regression suite + synthetic fixtures
  smoke_test.py    standalone end-to-end check (no test framework)
frontend/
  src/
    App.tsx                   record → analyze → visualize → playback → export
    components/
      Waveform.tsx            canvas: peaks + onset markers + pitch contour
      PianoRoll.tsx           canvas: notes colored by articulation
      ControlPanel.tsx        all analysis options
      InstrumentSelect.tsx    SoundFont GM program + pitch-bend toggle
      NoteTable.tsx           debug table with articulation column
    lib/
      wav.ts                  MediaRecorder blob → mono 22.05 kHz WAV
      api.ts                  fetch wrappers
      playback.ts             Tone.js preview + HTMLAudioElement for SoundFont renders
    hooks/useRecorder.ts      MediaRecorder hook
```

## Run

### Backend
Python 3.11 recommended (librosa/numpy/scipy/numba wheels are best-supported there).

```powershell
cd backend
python -m venv .venv
.\.venv\Scripts\python -m pip install -r requirements.txt
.\.venv\Scripts\python -m pip install pyfluidsynth     # optional, for SoundFont preview
.\.venv\Scripts\python -m uvicorn app.main:app --reload --port 8000
```

#### SoundFont (FluidSynth) preview — optional
The `/render_audio` endpoint synthesizes the detected notes through the user-provided
GeneralUser GS SoundFont using FluidSynth. A portable FluidSynth 2.5.4 Windows x64
build is already extracted under [`backend/bin/`](backend/bin/), and the backend adds
that directory to `PATH` automatically at startup.

Defaults (override with environment variables):
- `HUMMING_SF2_PATH` — default `C:\Users\jlion\Downloads\GeneralUser_GS_v2.0.3--doc_r6\GeneralUser-GS\GeneralUser-GS.sf2`

To verify the preview is wired up:
```powershell
curl http://127.0.0.1:8000/render_capabilities
# expect: { "soundfont_available": true, ... }
```

If `soundfont_available` is `false`, the response includes an `error` field describing what's missing.

#### Optional pitch backend
CREPE is heavy (≈2 GB of torch wheels) but more accurate on noisy vocals:
```powershell
.\.venv\Scripts\python -m pip install torch torchcrepe
```
Then choose "CREPE" in the UI control panel. pYIN is the default.

### Frontend
```powershell
cd frontend
npm install
npm run dev
```
Open http://localhost:5173. Vite proxies `/api/*` → `http://127.0.0.1:8000`.

## Pipeline
1. Browser records via `MediaRecorder` (webm/opus).
2. Client decodes blob → 22.05 kHz mono Float32 via `OfflineAudioContext`, encodes a 16-bit WAV.
3. Backend reads WAV, runs HPSS-filtered onset detection.
4. Pitch contour via `librosa.pyin` (auto `frame_length` from `fmin`), or CREPE if installed.
5. Onsets without a voiced region within 120 ms are dropped.
6. For each onset segment we skip a short attack window, median-filter the pitch frames, then take the median MIDI value over voiced frames above `voiced_prob_threshold`.
7. The note's end is tightened to the last voiced frame + 20 ms — keeps repeated staccato notes distinct.
8. Optional scale snap (`quantize_midi_to_scale`).
9. Optional tempo-grid quantize (`1/4`, `1/8`, `1/16`, `1/32`, plus `1/8t`, `1/16t` triplets).
10. Articulation classifier tags each transition as **legato** (gap < 30 ms), **staccato** (gap > 90 ms + sharp attack), or **normal**.
11. MIDI export: dedup + same-pitch overlap clipping, articulation reshape (legato +15 ms overlap, staccato 60 % duration), optional pitch-bend events (sparse, ±2 st).
12. Optional SoundFont render: pyfluidsynth direct → WAV bytes.

## Regression suite

```powershell
cd backend
.\.venv\Scripts\python -m pytest tests/ -v
```

Covers: monotone, triad melody, pentatonic, vibrato non-explosion, noisy SNR 25 dB, staccato pitch recall, legato non-over-segmentation, scale-snap correctness, chromatic passthrough, staccato/legato articulation tagging, tempo-grid snap accuracy.

## Debug knobs (Control Panel)
- pitch backend (pYIN / CREPE), fmin, fmax
- onset delta, min note duration, voiced threshold
- HPSS toggle for onset detection
- key + scale + quantize strength
- tempo grid + grid strength + tempo override
- same-pitch merge

The UI surfaces onset markers, pitch contour, per-note confidence, voicing %, and articulation color/label — every analysis decision is inspectable.

## Constraints honored
- No paid APIs. No cloud. All processing on `localhost`.
- No model training. pYIN / torchcrepe pretrained only.
- Visualization-first: every detected signal is plotted or tabled.
