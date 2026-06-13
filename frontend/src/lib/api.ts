import type { AnalyzeOptions, AnalyzeResponse, AssistResponse, AuditionItem, AuditionPaletteResponse, AuditionRenderRequest, Note, RenderCapabilities, SoundfontPreset, TrackType } from "../types";

const BASE = "/api";

export async function assistNotes(
  notes: Note[],
  options: Pick<AnalyzeOptions, "auto_key" | "pitch_assistant" | "assist_aggressive" | "key_tonic" | "scale">,
): Promise<AssistResponse> {
  const res = await fetch(`${BASE}/assist`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ notes, options }),
  });
  if (!res.ok) throw new Error(`assist failed: ${res.status} ${await res.text()}`);
  return res.json();
}

export async function analyzeAudio(
  audio: Blob,
  options: AnalyzeOptions,
  filename = "audio.bin",
): Promise<AnalyzeResponse> {
  const fd = new FormData();
  fd.append("audio", audio, filename);
  fd.append("options", JSON.stringify(options));
  const res = await fetch(`${BASE}/analyze`, { method: "POST", body: fd });
  if (!res.ok) throw new Error(`analyze failed: ${res.status} ${await res.text()}`);
  return res.json();
}

export async function exportMidi(
  notes: Note[],
  tempoBpm = 120,
  program = 0,
  bank = 0,
): Promise<Blob> {
  const res = await fetch(`${BASE}/export_midi`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ notes, tempo_bpm: tempoBpm, program, bank }),
  });
  if (!res.ok) throw new Error(`export failed: ${res.status} ${await res.text()}`);
  return res.blob();
}

export interface SampleInfo {
  slug: string;
  label: string;
  filename: string;
  size_bytes: number;
}

export async function listSamples(): Promise<SampleInfo[]> {
  const res = await fetch(`${BASE}/samples`);
  if (!res.ok) throw new Error(`samples list failed: ${res.status}`);
  return res.json();
}

export async function fetchSampleBlob(slug: string): Promise<Blob> {
  const res = await fetch(`${BASE}/samples/${encodeURIComponent(slug)}`);
  if (!res.ok) throw new Error(`sample ${slug} failed: ${res.status}`);
  return res.blob();
}

export async function getRenderCapabilities(): Promise<RenderCapabilities> {
  const res = await fetch(`${BASE}/render_capabilities`);
  if (!res.ok) throw new Error(`render_capabilities failed: ${res.status}`);
  return res.json();
}

export async function listSoundfontPresets(): Promise<SoundfontPreset[]> {
  const res = await fetch(`${BASE}/soundfont_presets`);
  if (!res.ok) throw new Error(`soundfont_presets failed: ${res.status} ${await res.text()}`);
  const data = await res.json();
  return data.presets as SoundfontPreset[];
}

export async function renderDemo(
  bank: number,
  program: number,
  sampleRate = 44100,
): Promise<Blob> {
  const res = await fetch(`${BASE}/render_demo`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ bank, program, sample_rate: sampleRate }),
  });
  if (!res.ok) throw new Error(`render_demo failed: ${res.status} ${await res.text()}`);
  return res.blob();
}

export async function renderAudio(
  notes: Note[],
  program = 0,
  bank = 0,
  sampleRate = 44100,
): Promise<Blob> {
  const res = await fetch(`${BASE}/render_audio`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ notes, program, bank, sample_rate: sampleRate }),
  });
  if (!res.ok) throw new Error(`render failed: ${res.status} ${await res.text()}`);
  return res.blob();
}

// --- sound picker (Space B) -------------------------------------------------
export async function getAuditionPalette(role: TrackType): Promise<AuditionPaletteResponse> {
  const res = await fetch(`${BASE}/audition_palette?role=${encodeURIComponent(role)}`);
  if (!res.ok) throw new Error(`audition_palette failed: ${res.status} ${await res.text()}`);
  return res.json();
}

export async function auditionRender(req: AuditionRenderRequest): Promise<Blob> {
  const res = await fetch(`${BASE}/audition_render`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(req),
  });
  if (!res.ok) throw new Error(`audition_render failed: ${res.status} ${await res.text()}`);
  return res.blob();
}

// Map a palette item to its render request (discriminated by source).
export function toRenderRequest(it: AuditionItem): AuditionRenderRequest {
  if (it.source === "gm") {
    return { source: "gm", bank: it.gm!.bank, program: it.gm!.program, track_type: it.track_type };
  }
  if (it.source === "catalog") {
    return { source: "catalog", soundfont_id: it.soundfont_id!, track_type: it.track_type };
  }
  return { source: "sentinel", sentinel_id: it.sentinel_id!, track_type: it.track_type };
}
