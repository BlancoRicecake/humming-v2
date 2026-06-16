import { useCallback, useEffect, useRef, useState } from "react";
import type { RenderCapabilities } from "../../types";
import {
  getGuitarLabSounds,
  guitarLabRender,
  type GuitarLabParams,
  type GuitarSound,
} from "../../lib/api";
import { playAudioBlob } from "../../lib/playback";

const LS_KEY = "soundlab.guitarlab.v2";

// Mirrors VOICINGS in backend/app/guitar_lab.py — semitone offsets from root,
// low string -> high string.
const VOICINGS: { value: string; label: string; offsets: number[] }[] = [
  { value: "power", label: "파워코드 (5도)", offsets: [0, 7] },
  { value: "power_oct", label: "파워코드 +옥타브", offsets: [0, 7, 12] },
  { value: "triad_maj", label: "메이저 3화음", offsets: [0, 4, 7] },
  { value: "triad_min", label: "마이너 3화음", offsets: [0, 3, 7] },
  { value: "open_E_maj", label: "6현 바레 E (메이저)", offsets: [0, 7, 12, 16, 19, 24] },
  { value: "open_E_min", label: "6현 바레 E (마이너)", offsets: [0, 7, 12, 15, 19, 24] },
  { value: "barre_A_maj", label: "5현 바레 A (메이저)", offsets: [0, 7, 12, 16, 19] },
];

// Real 6-string guitar range (standard tuning, sounding pitch): E2..E6.
const GUITAR_LO = 40; // E2 (open low E)
const GUITAR_HI = 88; // E6 (24th fret, high E)

const DEFAULTS: GuitarLabParams = {
  root: 40,
  voicing: "open_E_maj",
  strum_ms: 28,
  direction: "down",
  velocity: 100,
  velocity_falloff: 18,
  velocity_jitter: 8,
  timing_jitter_ms: 4,
  ring_ms: 1400,
  palm_mute: false,
  let_ring: false,
  pattern: "",
  bpm: 96,
  repeats: 1,
  reverb: 0.25,
};

const NOTE_NAMES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"];
function noteName(midi: number): string {
  return `${NOTE_NAMES[((midi % 12) + 12) % 12]}${Math.floor(midi / 12) - 1}`;
}

function loadParams(): GuitarLabParams {
  try {
    const raw = localStorage.getItem(LS_KEY);
    if (raw) return { ...DEFAULTS, ...JSON.parse(raw) };
  } catch {
    /* ignore */
  }
  return { ...DEFAULTS };
}

interface Props {
  caps: RenderCapabilities | null;
}

export function GuitarLab({ caps }: Props) {
  const [sounds, setSounds] = useState<GuitarSound[]>([]);
  const [soundKey, setSoundKey] = useState<string>("");
  const [params, setParams] = useState<GuitarLabParams>(() => loadParams());
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [slotA, setSlotA] = useState<GuitarLabParams | null>(null);
  const [slotB, setSlotB] = useState<GuitarLabParams | null>(null);
  const playingRef = useRef<HTMLAudioElement | null>(null);

  const engineOk = !!caps?.soundfont_available;

  // Notes the current voicing+root will actually sound — clamped to the real
  // guitar range so the user can see they're testing within E2..E6.
  const allNotes = (VOICINGS.find((v) => v.value === params.voicing)?.offsets ?? []).map((o) => params.root + o);
  const soundingNotes = [...new Set(allNotes.filter((n) => n >= GUITAR_LO && n <= GUITAR_HI))].sort((a, b) => a - b);
  const outOfRange = allNotes.length - soundingNotes.length;

  useEffect(() => {
    try {
      localStorage.setItem(LS_KEY, JSON.stringify(params));
    } catch {
      /* ignore */
    }
  }, [params]);

  useEffect(() => {
    getGuitarLabSounds()
      .then((items) => {
        setSounds(items);
        setSoundKey((k) => k || (items[0]?.key ?? ""));
      })
      .catch((e) => setErr(String(e?.message ?? e)));
  }, []);

  const set = useCallback(<K extends keyof GuitarLabParams>(key: K, value: GuitarLabParams[K]) => {
    setParams((p) => ({ ...p, [key]: value }));
  }, []);

  const play = useCallback(
    async (which: GuitarLabParams) => {
      if (!engineOk) return;
      const sound = sounds.find((s) => s.key === soundKey);
      if (!sound) return;
      if (playingRef.current) {
        playingRef.current.pause();
        playingRef.current = null;
      }
      setBusy(true);
      setErr(null);
      try {
        const blob = await guitarLabRender(sound, which);
        playingRef.current = await playAudioBlob(blob);
      } catch (e) {
        setErr(String((e as Error)?.message ?? e));
      } finally {
        setBusy(false);
      }
    },
    [engineOk, sounds, soundKey],
  );

  const exportPreset = useCallback(() => {
    const sound = sounds.find((s) => s.key === soundKey);
    const preset = {
      _meta: "soundlab guitar-lab preset",
      sound: sound ? { key: sound.key, source: sound.source, label: sound.label, bank: sound.bank, program: sound.program, soundfont_id: sound.soundfont_id } : null,
      params,
    };
    const blob = new Blob([JSON.stringify(preset, null, 2)], { type: "application/json" });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = "guitar-lab-preset.json";
    a.click();
    URL.revokeObjectURL(url);
  }, [sounds, soundKey, params]);

  const num = (
    key: keyof GuitarLabParams,
    label: string,
    min: number,
    max: number,
    step: number,
    fmt?: (v: number) => string,
  ) => {
    const v = params[key] as number;
    return (
      <label className="gl-field">
        <span className="gl-label">
          {label} <b>{fmt ? fmt(v) : v}</b>
        </span>
        <input
          type="range"
          min={min}
          max={max}
          step={step}
          value={v}
          onChange={(e) => set(key, Number(e.target.value) as never)}
        />
      </label>
    );
  };

  return (
    <section className="gl">
      <div className="gl-bar">
        <strong>기타 연구소</strong>
        <select value={soundKey} onChange={(e) => setSoundKey(e.target.value)}>
          {sounds.map((s) => (
            <option key={s.key} value={s.key}>
              {s.category} · {s.label}
            </option>
          ))}
        </select>
        <button className="gl-play" disabled={!engineOk || busy || !soundKey} onClick={() => play(params)}>
          ▶ 재생
        </button>
        <button disabled={busy} onClick={exportPreset}>
          프리셋 내보내기
        </button>
        <button disabled={busy} onClick={() => setParams({ ...DEFAULTS })}>
          초기화
        </button>
      </div>

      {!engineOk && (
        <p className="gl-warn">SoundFont 미가용 — {caps?.error ?? "백엔드 미초기화"}</p>
      )}
      {err && <p className="gl-warn">{err}</p>}

      <div className="gl-grid">
        <label className="gl-field">
          <span className="gl-label">코드 보이싱</span>
          <select value={params.voicing} onChange={(e) => set("voicing", e.target.value)}>
            {VOICINGS.map((v) => (
              <option key={v.value} value={v.value}>
                {v.label}
              </option>
            ))}
          </select>
        </label>

        {num("root", "루트음", GUITAR_LO, 64, 1, (v) => noteName(v))}

        <label className="gl-field">
          <span className="gl-label">
            울리는 음 {outOfRange > 0 && <b className="gl-oor">· {outOfRange}음 음역 밖(제외됨)</b>}
          </span>
          <span className="gl-notes">{soundingNotes.map((n) => noteName(n)).join(" · ") || "—"}</span>
        </label>

        <label className="gl-field">
          <span className="gl-label">스트로크 방향</span>
          <div className="gl-seg">
            <button className={params.direction === "down" ? "active" : ""} onClick={() => set("direction", "down")}>
              ↓ 다운 (저→고)
            </button>
            <button className={params.direction === "up" ? "active" : ""} onClick={() => set("direction", "up")}>
              ↑ 업 (고→저)
            </button>
          </div>
        </label>

        {num("strum_ms", "스트럼 간격", 0, 120, 1, (v) => `${v} ms`)}
        {num("velocity", "기본 세기", 1, 127, 1)}
        {num("velocity_falloff", "세기 감쇠 곡선", 0, 60, 1, (v) => `${v} %`)}
        {num("velocity_jitter", "세기 랜덤", 0, 30, 1, (v) => `±${v}`)}
        {num("timing_jitter_ms", "타이밍 랜덤", 0, 20, 0.5, (v) => `±${v} ms`)}
        {num("ring_ms", "줄 울림(링)", 100, 3000, 10, (v) => `${v} ms`)}
        {num("reverb", "리버브", 0, 1, 0.01, (v) => v.toFixed(2))}

        <label className="gl-field gl-check">
          <input type="checkbox" checked={params.palm_mute} onChange={(e) => set("palm_mute", e.target.checked)} />
          <span>팜뮤트 (빠른 감쇠 + 약하게)</span>
        </label>
        <label className="gl-field gl-check">
          <input type="checkbox" checked={params.let_ring} onChange={(e) => set("let_ring", e.target.checked)} />
          <span>렛링 (다음 스트럼에 안 끊김)</span>
        </label>
      </div>

      <div className="gl-pattern">
        <label className="gl-field">
          <span className="gl-label">스트럼 패턴 (D=다운, U=업, 그 외=쉼)</span>
          <input
            type="text"
            placeholder="예: DUUDU (비우면 단일 다운)"
            value={params.pattern}
            onChange={(e) => set("pattern", e.target.value)}
          />
        </label>
        {num("bpm", "BPM", 40, 200, 1)}
        {num("repeats", "반복", 1, 8, 1, (v) => `${v}회`)}
      </div>

      <div className="gl-ab">
        <span>A/B 비교:</span>
        <button onClick={() => setSlotA({ ...params })}>A에 저장</button>
        <button disabled={!slotA || busy} onClick={() => slotA && play(slotA)}>
          A 재생
        </button>
        <button disabled={!slotA} onClick={() => slotA && setParams({ ...slotA })}>
          A 불러오기
        </button>
        <span className="gl-sep">|</span>
        <button onClick={() => setSlotB({ ...params })}>B에 저장</button>
        <button disabled={!slotB || busy} onClick={() => slotB && play(slotB)}>
          B 재생
        </button>
        <button disabled={!slotB} onClick={() => slotB && setParams({ ...slotB })}>
          B 불러오기
        </button>
      </div>
    </section>
  );
}
