import type { Note, DetectedKey } from "./reuse";

export interface LabConfig {
  backend_url: string;
  backend_ok: boolean;
  render_available: boolean;
  ace_enabled: string;
  ace_healthy: boolean;
}

export interface SampleItem {
  id: string;
  label: string;
  filename: string;
  size_bytes: number;
}

export interface FuseParams {
  sample_id?: string;
  prompt: string;
  bpm: number;
  ace_task: "cover" | "complete";
  source_mode: "resynth" | "raw";
  lead_program?: number;
}

export interface FuseResult {
  melody_notes: Note[];
  ai_notes: Note[];
  detected_key: DetectedKey | null;
  duration: number;
  engine: "acestep" | "mock";
  engine_note: string | null;
  source_mode_used: string;
  original_id: string | null;
  melody_src_url: string;
  ai_wav_url: string;
}

export async function getConfig(): Promise<LabConfig> {
  const r = await fetch("/api/config");
  if (!r.ok) throw new Error(`config failed: ${r.status}`);
  return r.json();
}

export async function getSamples(): Promise<SampleItem[]> {
  const r = await fetch("/api/samples");
  if (!r.ok) throw new Error(`samples failed: ${r.status}`);
  return r.json();
}

export async function fuse(params: FuseParams, file?: File | null): Promise<FuseResult> {
  const fd = new FormData();
  fd.append("params", JSON.stringify(params));
  if (file) fd.append("audio", file, file.name);
  const r = await fetch("/api/fuse", { method: "POST", body: fd });
  if (!r.ok) throw new Error(`fuse failed: ${r.status} ${await r.text()}`);
  return r.json();
}

export interface ExportTrack {
  notes: Note[];
  program: number;
  channel: number;
}

export async function exportMidi(tracks: ExportTrack[], tempoBpm: number): Promise<Blob> {
  const r = await fetch("/api/export_midi", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ tracks, tempo_bpm: tempoBpm }),
  });
  if (!r.ok) throw new Error(`export failed: ${r.status} ${await r.text()}`);
  return r.blob();
}
