import { useEffect, useState, useCallback } from "react";
import { PianoRoll, NoteTable, CandidatePicker } from "./reuse";
import type { Note } from "./reuse";
import {
  getConfig, getSamples, fuse, exportMidi,
  type LabConfig, type SampleItem, type FuseResult,
} from "./api";

const LEAD_PROGRAM = 73; // GM Flute — sustained, tracks pitch well for cover
const AI_PROGRAM = 0;    // GM Piano for the transcribed AI track

type PickerState = { track: "melody" | "ai"; index: number } | null;

export function App() {
  const [config, setConfig] = useState<LabConfig | null>(null);
  const [samples, setSamples] = useState<SampleItem[]>([]);
  const [sampleId, setSampleId] = useState<string>("");
  const [prompt, setPrompt] = useState("warm lo-fi piano with soft drums");
  const [bpm, setBpm] = useState(90);
  const [aceTask, setAceTask] = useState<"cover" | "complete">("cover");
  const [sourceMode, setSourceMode] = useState<"resynth" | "raw">("resynth");

  const [loading, setLoading] = useState(false);
  const [progress, setProgress] = useState("");
  const [error, setError] = useState<string | null>(null);

  const [result, setResult] = useState<FuseResult | null>(null);
  const [melodyNotes, setMelodyNotes] = useState<Note[]>([]);
  const [aiNotes, setAiNotes] = useState<Note[]>([]);
  const [picker, setPicker] = useState<PickerState>(null);

  useEffect(() => {
    getConfig().then(setConfig).catch(() => setConfig(null));
    getSamples().then((s) => {
      setSamples(s);
      if (s.length) setSampleId(s[0].id);
    }).catch((e) => setError(String(e)));
  }, []);

  const runFuse = useCallback(async () => {
    setLoading(true); setError(null); setResult(null); setPicker(null);
    setProgress("허밍 분석 → 멜로디 재합성 → AI 생성 → 전사… (Mock은 수초, 실제 ACE는 수분)");
    try {
      const res = await fuse({
        sample_id: sampleId, prompt, bpm, ace_task: aceTask,
        source_mode: sourceMode, lead_program: LEAD_PROGRAM,
      });
      setResult(res);
      setMelodyNotes(res.melody_notes);
      setAiNotes(res.ai_notes);
    } catch (e) {
      setError(String(e));
    } finally {
      setLoading(false); setProgress("");
    }
  }, [sampleId, prompt, bpm, aceTask, sourceMode]);

  const onPick = (track: "melody" | "ai") => (index: number) => setPicker({ track, index });

  const applyPitch = (pitch: number) => {
    if (!picker) return;
    const setter = picker.track === "melody" ? setMelodyNotes : setAiNotes;
    setter((prev) => prev.map((n, i) =>
      i === picker.index ? { ...n, pitch, source: "user" as const } : n));
    setPicker(null);
  };

  const doExport = async () => {
    try {
      const blob = await exportMidi([
        { notes: melodyNotes, program: LEAD_PROGRAM, channel: 0 },
        { notes: aiNotes, program: AI_PROGRAM, channel: 1 },
      ], bpm);
      const url = URL.createObjectURL(blob);
      const a = document.createElement("a");
      a.href = url; a.download = "ace_fusion.mid"; a.click();
      URL.revokeObjectURL(url);
    } catch (e) {
      setError(String(e));
    }
  };

  const pickedNote = picker
    ? (picker.track === "melody" ? melodyNotes : aiNotes)[picker.index]
    : null;

  const keyLabel = result?.detected_key?.tonic
    ? `${result.detected_key.tonic} ${result.detected_key.scale ?? ""}`
    : "—";

  return (
    <div className="app">
      <header>
        <h1>ACE-Fusion Lab <span className="sub">허밍 + ACE-Step → 편집 가능한 MIDI</span></h1>
        <StatusBanner config={config} result={result} />
      </header>

      <section className="panel">
        <h2>① 입력</h2>
        <div className="row">
          <label>샘플 (HumTrans)
            <select value={sampleId} onChange={(e) => setSampleId(e.target.value)}>
              {samples.map((s) => <option key={s.id} value={s.id}>{s.label}</option>)}
            </select>
          </label>
          {sampleId && (
            <audio controls src={`/api/sample_audio/${sampleId}`} className="aud" />
          )}
        </div>
        <div className="row">
          <label className="grow">텍스트 프롬프트
            <input value={prompt} onChange={(e) => setPrompt(e.target.value)}
              placeholder="e.g. warm lo-fi piano, 80bpm" />
          </label>
        </div>
        <div className="row">
          <label>BPM
            <input type="number" value={bpm} min={40} max={240}
              onChange={(e) => setBpm(Number(e.target.value))} />
          </label>
          <label>ACE Task
            <select value={aceTask} onChange={(e) => setAceTask(e.target.value as any)}>
              <option value="cover">cover (멜로디 유지·리스타일)</option>
              <option value="complete">complete (반주 생성)</option>
            </select>
          </label>
          <label>소스 형태
            <select value={sourceMode} onChange={(e) => setSourceMode(e.target.value as any)}>
              <option value="resynth">재합성(깨끗한 멜로디)</option>
              <option value="raw">원본 허밍</option>
            </select>
          </label>
          <button className="primary" disabled={loading || !sampleId} onClick={runFuse}>
            {loading ? "생성 중…" : "② 생성"}
          </button>
        </div>
        {progress && <p className="progress">{progress}</p>}
        {error && <p className="error">⚠ {error}</p>}
      </section>

      {result && (
        <>
          <section className="panel">
            <h2>③ 결과 <span className="meta">
              · 엔진: <b>{result.engine}</b> · 키: <b>{keyLabel}</b>
              · 소스: {result.source_mode_used}</span></h2>
            <div className="row players">
              {result.original_id && (
                <Player label="원본 허밍" src={`/api/sample_audio/${result.original_id}`} />)}
              <Player label="ACE 입력(멜로디)" src={result.melody_src_url} />
              <Player label="AI 생성 풀트랙" src={result.ai_wav_url} />
            </div>
          </section>

          <section className="panel">
            <h2>④ 편집 — 멜로디 트랙 <span className="meta">({melodyNotes.length} notes · 노트 클릭 → 음정 수정)</span></h2>
            <PianoRoll notes={melodyNotes} duration={result.duration}
              selectedIndex={picker?.track === "melody" ? picker.index : null}
              onNoteClick={onPick("melody")} />
          </section>

          <section className="panel">
            <h2>④ 편집 — AI 트랙 (CREPE 전사) <span className="meta">({aiNotes.length} notes)</span></h2>
            <PianoRoll notes={aiNotes} duration={result.duration}
              selectedIndex={picker?.track === "ai" ? picker.index : null}
              onNoteClick={onPick("ai")} />
          </section>

          <section className="panel">
            <button className="primary" onClick={doExport}>⑤ 병합 MIDI 내보내기 (.mid)</button>
            <span className="meta"> 멜로디(Ch1) + AI(Ch2) 멀티트랙</span>
          </section>

          <section className="panel">
            <h2>노트 테이블 — 멜로디</h2>
            <NoteTable notes={melodyNotes} onSelect={onPick("melody")} />
          </section>
        </>
      )}

      {pickedNote && (
        <div className="picker-overlay" onClick={() => setPicker(null)}>
          <div onClick={(e) => e.stopPropagation()}>
            <CandidatePicker note={pickedNote} index={picker!.index}
              onSelect={applyPitch} onClose={() => setPicker(null)} />
          </div>
        </div>
      )}
    </div>
  );
}

function Player({ label, src }: { label: string; src: string }) {
  return (
    <div className="player">
      <div className="meta">{label}</div>
      <audio controls src={src} className="aud" />
    </div>
  );
}

function StatusBanner({ config, result }: { config: LabConfig | null; result: FuseResult | null }) {
  if (!config) return <div className="banner warn">오케스트레이터(:8200) 연결 대기…</div>;
  const aceOn = config.ace_healthy;
  return (
    <div className={`banner ${config.backend_ok ? "" : "warn"}`}>
      백엔드 {config.backend_ok ? "✓" : "✗ (:8000 미기동)"} ·
      {" "}렌더 {config.render_available ? "✓" : "✗ (SoundFont 없음 → 원본허밍 사용)"} ·
      {" "}ACE-Step {aceOn ? "✓ 실모델" : "✗ Mock 모드"}
      {result?.engine === "mock" && result.engine_note && (
        <span className="note"> · {result.engine_note}</span>)}
    </div>
  );
}
