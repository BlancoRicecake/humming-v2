import { useCallback, useEffect, useMemo, useState } from "react";
import { useRecorder } from "./hooks/useRecorder";
import { blobToMonoPcm, encodeWav } from "./lib/wav";
import {
  analyzeAudio,
  assistNotes,
  exportMidi,
  getRenderCapabilities,
  renderAudio,
} from "./lib/api";
import { playAudioBlob, playNotes, stopPlayback, type OscType } from "./lib/playback";
import type { RenderCapabilities } from "./types";
import { WaveformView } from "./components/Waveform";
import { PianoRoll } from "./components/PianoRoll";
import { ControlPanel } from "./components/ControlPanel";
import { NoteTable } from "./components/NoteTable";
import { SamplePicker } from "./components/SamplePicker";
import { CandidatePicker } from "./components/CandidatePicker";
import { INSTRUMENT_ROLES, isChordCapable } from "./lib/instruments";
import { expandChords } from "./lib/chords";
import type { AnalyzeOptions, AnalyzeResponse, Scale } from "./types";

const DEFAULT_OPTIONS: AnalyzeOptions = {
  fmin_hz: 65,
  fmax_hz: 1000,
  enter_ratio: 0.20,
  exit_ratio: 0.12,
  exit_hold_sec: 0.025,
  min_chunk_dur_sec: 0.06,
  merge_gap_sec: 0.04,
  rms_dip_split: true,
  pitch_split: true,
  voiced_prob_threshold: 0.45,
  auto_key: true,
  pitch_assistant: true,
  key_tonic: null,
  scale: null,
  quantize_strength: 1.0,
};

const TONICS = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"];
const KEY_MODES: Scale[] = ["major", "minor"];

function midiToHz(p: number) {
  return 440.0 * Math.pow(2, (p - 69) / 12);
}

export default function App() {
  const recorder = useRecorder();
  const [options, setOptions] = useState<AnalyzeOptions>(DEFAULT_OPTIONS);
  const [result, setResult] = useState<AnalyzeResponse | null>(null);
  const [analyzing, setAnalyzing] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [hoverNote, setHoverNote] = useState<number | null>(null);
  const [selectedNote, setSelectedNote] = useState<number | null>(null);
  const [assisting, setAssisting] = useState(false);
  const [lastSource, setLastSource] = useState<Blob | null>(null);
  const [sourceLabel, setSourceLabel] = useState<string>("");
  const [osc, setOsc] = useState<OscType>("triangle");
  const [showEnvelope, setShowEnvelope] = useState(true);
  const [caps, setCaps] = useState<RenderCapabilities | null>(null);
  const [sfProgram, setSfProgram] = useState<number>(0);
  const [chordMode, setChordMode] = useState(false);
  const [rendering, setRendering] = useState(false);

  useEffect(() => {
    getRenderCapabilities().then(setCaps).catch((e) =>
      console.warn("render capabilities unavailable:", e),
    );
  }, []);

  // Stage 2 boundary — try to decode in browser to WAV; fall back to raw blob
  // (backend handles m4a/mp3 via librosa + ffmpeg).
  const runAnalyze = useCallback(async (blob: Blob, label: string) => {
    setAnalyzing(true);
    setError(null);
    setSourceLabel(label);
    try {
      let upload: Blob = blob;
      let filename = "input.bin";
      try {
        const { samples, sampleRate } = await blobToMonoPcm(blob, 22050);
        upload = encodeWav(samples, sampleRate);
        filename = "input.wav";
      } catch (decodeErr) {
        console.warn("client decode failed, sending raw bytes:", decodeErr);
      }
      setLastSource(upload);
      const res = await analyzeAudio(upload, options, filename);
      setResult(res);
      setSelectedNote(null);
    } catch (e: any) {
      setError(e?.message ?? String(e));
    } finally {
      setAnalyzing(false);
    }
  }, [options]);

  // Stage 1 — record
  const onRecordToggle = useCallback(async () => {
    if (recorder.state === "recording") recorder.stop();
    else {
      setResult(null); setLastSource(null); setSourceLabel("");
      await recorder.start();
    }
  }, [recorder]);

  const onAnalyzeAfterRecord = useCallback(() => {
    if (recorder.blob && !analyzing) runAnalyze(recorder.blob, "recording");
  }, [recorder.blob, analyzing, runAnalyze]);

  // Sample button / file picker — bypass recorder
  const onSourceLoaded = useCallback(async (blob: Blob, label: string) => {
    recorder.reset();
    setResult(null);
    await runAnalyze(blob, label);
  }, [recorder, runAnalyze]);

  // chord mode only applies to a chord-capable instrument on a take with a key
  const chordActive = chordMode && isChordCapable(sfProgram) && !!result?.detected_key?.tonic;
  const renderNotes = useMemo(() => {
    if (!result) return [];
    return chordActive ? expandChords(result.notes, result.detected_key) : result.notes;
  }, [result, chordActive]);

  // Stage 8 — playback
  const onPlayNotes = useCallback(async () => {
    if (renderNotes.length) await playNotes(renderNotes, osc);
  }, [renderNotes, osc]);

  const onPlayOriginal = useCallback(async () => {
    if (lastSource) await playAudioBlob(lastSource);
  }, [lastSource]);

  // Stage 9 — MIDI export
  const onDownloadMidi = useCallback(async () => {
    if (!renderNotes.length) return;
    const blob = await exportMidi(renderNotes, 120, sfProgram);
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url; a.download = "soundlab.mid"; a.click();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  }, [renderNotes, sfProgram]);

  // Stage 8 — SoundFont render & play
  const onPlaySoundFont = useCallback(async () => {
    if (!renderNotes.length || !caps?.soundfont_available) return;
    setRendering(true);
    setError(null);
    try {
      const blob = await renderAudio(renderNotes, sfProgram);
      await playAudioBlob(blob);
    } catch (e: any) {
      setError(`SoundFont render failed: ${e?.message ?? e}`);
    } finally {
      setRendering(false);
    }
  }, [renderNotes, caps, sfProgram]);

  const onDownloadRenderedWav = useCallback(async () => {
    if (!renderNotes.length || !caps?.soundfont_available) return;
    setRendering(true);
    try {
      const blob = await renderAudio(renderNotes, sfProgram);
      const url = URL.createObjectURL(blob);
      const a = document.createElement("a");
      a.href = url; a.download = "soundlab.wav"; a.click();
      setTimeout(() => URL.revokeObjectURL(url), 1000);
    } catch (e: any) {
      setError(`SoundFont render failed: ${e?.message ?? e}`);
    } finally {
      setRendering(false);
    }
  }, [renderNotes, caps, sfProgram]);

  const recordLabel = useMemo(() => {
    switch (recorder.state) {
      case "recording": return `Stop  (${recorder.elapsed.toFixed(1)}s)`;
      case "requesting": return "Requesting mic…";
      case "processing": return "Processing…";
      default: return "Record";
    }
  }, [recorder.state, recorder.elapsed]);

  const reanalyze = useCallback(() => {
    if (lastSource) runAnalyze(lastSource, sourceLabel || "re-analyze");
  }, [lastSource, sourceLabel, runAnalyze]);

  // Step 4/5 — re-run Auto Key + Pitch Assistant on existing notes (no re-analyze)
  const applyAssist = useCallback(async (patch: Partial<AnalyzeOptions>) => {
    const merged = { ...options, ...patch };
    setOptions(merged);
    if (!result) return;
    setAssisting(true);
    setError(null);
    try {
      const r = await assistNotes(result.notes, {
        auto_key: merged.auto_key,
        pitch_assistant: merged.pitch_assistant,
        key_tonic: merged.key_tonic,
        scale: merged.scale,
      });
      setResult({
        ...result,
        notes: r.notes,
        detected_key: r.detected_key,
        assist_applied_count: r.assist_applied_count,
        key_candidates: r.key_candidates,
      });
      setSelectedNote(null);
    } catch (e: any) {
      setError(e?.message ?? String(e));
    } finally {
      setAssisting(false);
    }
  }, [options, result]);

  const onKeyChange = useCallback((value: string) => {
    if (value === "auto") {
      applyAssist({ auto_key: true });
    } else {
      const [tonic, mode] = value.split(":");
      applyAssist({ auto_key: false, key_tonic: tonic, scale: mode as Scale });
    }
  }, [applyAssist]);

  // Step 5 — per-note candidate override (pure client-side; re-render via Play/export)
  const onSelectCandidate = useCallback((pitch: number) => {
    if (selectedNote == null || !result) return;
    const notes = result.notes.map((n, idx) =>
      idx === selectedNote
        ? { ...n, pitch, pitch_hz: midiToHz(pitch), source: "user" as const }
        : n,
    );
    setResult({ ...result, notes });
  }, [selectedNote, result]);

  const keyValue = options.auto_key ? "auto" : `${options.key_tonic}:${options.scale}`;
  const dk = result?.detected_key;
  const keyCaption = !dk?.tonic
    ? "키 미검출"
    : dk.key_tier === "high"
      ? `${dk.tonic} ${dk.scale}로 정리했어요`
      : dk.key_tier === "mid"
        ? `${dk.tonic} ${dk.scale} 기준으로 살짝 정리했어요`
        : `${dk.tonic} ${dk.scale}가 가장 가까워 보여요 (불확실)`;
  const topKeys = (result?.key_candidates ?? [])
    .map((c) => `${c.tonic} ${c.scale.slice(0, 3)} ${c.correlation.toFixed(2)}`)
    .join("  /  ");

  return (
    <div className="app">
      <header>
        <h1>SoundLab</h1>
        <p className="sub">
          input → preprocess → voice-region → chunk → pitch → notes → key/scale → synth → output
        </p>
      </header>

      {/* Stage 1 — input */}
      <section className="row">
        <button
          className={`primary ${recorder.state === "recording" ? "active" : ""}`}
          onClick={onRecordToggle}
          disabled={recorder.state === "requesting" || recorder.state === "processing" || analyzing}
        >
          {recordLabel}
        </button>
        <button onClick={onAnalyzeAfterRecord} disabled={!recorder.blob || analyzing}>
          {analyzing ? "Analyzing…" : "Analyze"}
        </button>
        <button onClick={reanalyze} disabled={!lastSource || analyzing}>
          Re-analyze
        </button>
        <button onClick={onPlayOriginal} disabled={!lastSource}>Play original</button>
        <button onClick={onPlayNotes} disabled={!result?.notes.length}>Play notes (Tone.js)</button>
        <button
          onClick={onPlaySoundFont}
          disabled={!result?.notes.length || !caps?.soundfont_available || rendering}
          title={caps?.error ?? undefined}
        >
          {rendering ? "Rendering…" : "Play with SoundFont"}
        </button>
        <button onClick={() => stopPlayback()}>Stop</button>
        <button onClick={onDownloadMidi} disabled={!result?.notes.length}>Download .mid</button>
        <button
          onClick={onDownloadRenderedWav}
          disabled={!result?.notes.length || !caps?.soundfont_available || rendering}
        >
          Download .wav
        </button>
        <button onClick={() => { recorder.reset(); setResult(null); setLastSource(null); setSourceLabel(""); setError(null); }}
                disabled={recorder.state === "recording"}>
          Reset
        </button>
      </section>

      <SamplePicker onSourceLoaded={onSourceLoaded} disabled={analyzing || recorder.state === "recording"} />

      {sourceLabel && (
        <div className="meta" style={{ marginBottom: 8 }}>
          source: <strong>{sourceLabel}</strong>
        </div>
      )}

      {error && <div className="error">⚠ {error}</div>}
      {recorder.error && <div className="error">⚠ recorder: {recorder.error}</div>}

      <div className="instrument-bar">
        <label>
          악기
          <select
            value={sfProgram}
            onChange={(e) => setSfProgram(parseInt(e.target.value, 10))}
            disabled={!caps?.soundfont_available || rendering || analyzing}
          >
            {INSTRUMENT_ROLES.map((r) => (
              <optgroup key={r.role} label={r.label}>
                {r.instruments.map((inst) => (
                  <option key={inst.program} value={inst.program}>{inst.label}</option>
                ))}
              </optgroup>
            ))}
          </select>
        </label>
        <label className="checkbox" title={isChordCapable(sfProgram) ? undefined : "이 악기는 코드 모드를 지원하지 않습니다"}>
          <input
            type="checkbox"
            checked={chordMode}
            disabled={!isChordCapable(sfProgram) || rendering || analyzing}
            onChange={(e) => setChordMode(e.target.checked)}
          />
          코드 모드 {chordActive && "(다이아토닉 트라이어드)"}
        </label>
        <span className="meta">드럼은 비트(퍼커션) 입력에서 자동으로 Kick/Snare/HiHat로 재생됩니다.</span>
        {!caps?.soundfont_available && (
          <span className="meta" style={{ color: "var(--warn)" }}>
            SoundFont 미가용 — {caps?.error ?? "백엔드 미초기화"}
          </span>
        )}
      </div>

      <ControlPanel
        options={options} onChange={setOptions}
        osc={osc} onOscChange={setOsc}
        disabled={analyzing}
      />

      {result && (
        <>
          <section className="result-bar">
            <h2>Step 4 · result</h2>
            <div className="result-controls">
              <div className="rc-item">
                <span className="rc-label">추천 Key</span>
                <strong>{keyCaption}</strong>
                {dk && dk.confidence > 0 && (
                  <span className="meta"> (conf {dk.confidence.toFixed(2)}, {dk.key_tier})</span>
                )}
              </div>
              <label className="rc-item">
                <span className="rc-label">Key</span>
                <select value={keyValue} onChange={(e) => onKeyChange(e.target.value)}
                        disabled={assisting || analyzing}>
                  <option value="auto">Auto</option>
                  {TONICS.flatMap((t) => KEY_MODES.map((m) => (
                    <option key={`${t}:${m}`} value={`${t}:${m}`}>{t} {m}</option>
                  )))}
                </select>
              </label>
              <label className="rc-item checkbox">
                <input type="checkbox" checked={options.pitch_assistant}
                       disabled={assisting || analyzing}
                       onChange={(e) => applyAssist({ pitch_assistant: e.target.checked })} />
                Pitch Assistant
              </label>
              <div className="rc-item">
                <span className="rc-label">보정된 노트</span>
                <strong>{result.assist_applied_count}</strong>개
              </div>
              {assisting && <span className="meta">적용 중…</span>}
            </div>
            {topKeys && (
              <div className="meta" style={{ marginTop: 6 }}>
                키 후보: {topKeys}
                {dk && !dk.key_applied && dk.tonic && " · 자동 보정 보류(저신뢰)"}
              </div>
            )}
          </section>

          <section>
            <h2>Stage 3-4 · waveform · envelope · chunks</h2>
            <div className="row" style={{ marginBottom: 8 }}>
              <label className="checkbox">
                <input type="checkbox" checked={showEnvelope}
                       onChange={(e) => setShowEnvelope(e.target.checked)} />
                Show envelope debug
              </label>
            </div>
            <WaveformView
              waveform={result.waveform}
              pitchTrack={{ times: result.pitch_track.times, midi: result.pitch_track.midi }}
              envelope={result.envelope}
              chunks={result.chunks}
              showEnvelope={showEnvelope}
            />
            <div className="meta">
              chunks: {result.chunks.length} · notes: {result.notes.length} ·
              duration: {result.waveform.duration.toFixed(2)}s
            </div>
          </section>

          <section>
            <h2>Step 5 · piano roll {chordActive ? "(코드 모드 — 편집은 단음 모드에서)" : "(노트 클릭 → 후보 선택)"}</h2>
            <PianoRoll
              notes={renderNotes}
              duration={result.waveform.duration}
              highlightNoteIndex={chordActive ? null : hoverNote}
              selectedIndex={chordActive ? null : selectedNote}
              onNoteClick={chordActive ? undefined : setSelectedNote}
            />
            <div className="legend meta">
              <span className="sw raw" /> raw
              <span className="sw assistant" /> 어시스턴트 보정
              <span className="sw user" /> 직접 수정
            </div>
            {!chordActive && selectedNote != null && result.notes[selectedNote]?.kind === "pitched" && (
              <CandidatePicker
                note={result.notes[selectedNote]}
                index={selectedNote}
                onSelect={onSelectCandidate}
                onClose={() => setSelectedNote(null)}
              />
            )}
          </section>

          <section>
            <h2>Stage 5-6 · note table (debug)</h2>
            <NoteTable
              notes={result.notes}
              highlight={hoverNote}
              selected={selectedNote}
              onHover={setHoverNote}
              onSelect={setSelectedNote}
            />
          </section>
        </>
      )}

      <footer>
        <small>
          Local SoundLab · librosa pyin + numpy RMS state-machine · mido MIDI · Tone.js synth.
        </small>
      </footer>
    </div>
  );
}
