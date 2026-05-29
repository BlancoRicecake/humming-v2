import type { AnalyzeOptions, AnalyzeResponse, AssistResponse, Note, RenderCapabilities } from "../types";

const BASE = "/api";

export async function assistNotes(
  notes: Note[],
  options: Pick<AnalyzeOptions, "auto_key" | "pitch_assistant" | "key_tonic" | "scale">,
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
): Promise<Blob> {
  const res = await fetch(`${BASE}/export_midi`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ notes, tempo_bpm: tempoBpm, program }),
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

export async function renderAudio(
  notes: Note[],
  program = 0,
  sampleRate = 44100,
): Promise<Blob> {
  const res = await fetch(`${BASE}/render_audio`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ notes, program, sample_rate: sampleRate }),
  });
  if (!res.ok) throw new Error(`render failed: ${res.status} ${await res.text()}`);
  return res.blob();
}
