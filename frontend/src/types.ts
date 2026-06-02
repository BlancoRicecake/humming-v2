export type Scale =
  | "major" | "minor"
  | "harmonic_minor" | "melodic_minor"
  | "dorian" | "phrygian" | "lydian" | "mixolydian" | "locrian"
  | "major_pentatonic" | "minor_pentatonic" | "blues" | "chromatic";

export interface AnalyzeOptions {
  // Stage 2 — preprocessing
  fmin_hz: number;
  fmax_hz: number;
  // Stage 3 — voice region detection
  enter_ratio: number;
  exit_ratio: number;
  exit_hold_sec: number;
  // Stage 4 — chunk segmentation
  min_chunk_dur_sec: number;
  merge_gap_sec: number;
  rms_dip_split: boolean;
  pitch_split: boolean;
  // Stage 5 — per-chunk analysis
  voiced_prob_threshold: number;
  // Stage 7 — key/scale
  auto_key: boolean;
  pitch_assistant: boolean;
  key_tonic: string | null;
  scale: Scale | null;
  quantize_strength: number;
}

export interface Note {
  start: number;
  end: number;
  duration: number;
  pitch: number;
  pitch_raw: number;
  pitch_hz: number;
  velocity: number;
  confidence: number;
  voiced_ratio: number;
  kind: "pitched" | "percussive";
  // Pitch Assistant metadata
  pitch_original: number;
  assisted: boolean;
  candidates: number[];
  source: "raw" | "assistant" | "user";
  in_key: boolean;
  correction_cents: number;
  // Drum timbre classification (backend drums.py) — populated for every note.
  drum: number | null;          // GM percussion note 36/38/42
  drum_name: string | null;     // "Kick" | "Snare" | "HiHat"
  drum_centroid: number;        // spectral centroid (Hz)
  drum_low_ratio: number;       // energy fraction < 150Hz (debug only — phone-stripped)
  drum_high_ratio: number;      // energy fraction > 5kHz
  drum_zcr: number;             // zero-crossing rate (0-1)
  drum_rolloff: number;         // spectral rolloff 85% (Hz)
  drum_flatness: number;        // spectral flatness 0-1 (kick↔snare axis)
  onset_strength: number;       // spectral-flux onset envelope at the hit
}

export interface DetectedKey {
  tonic: string | null;
  scale: string | null;
  confidence: number;
  key_tier: "high" | "mid" | "low" | null;
  key_applied: boolean;
}

export interface KeyCandidate {
  tonic: string;
  scale: string;
  correlation: number;
}

export interface Waveform {
  sample_rate: number;
  duration: number;
  peaks: number[];
}

export interface EnvelopeInfo {
  times: number[];
  rms: number[];
  noise_floor: number;
  peak_level: number;
  enter_threshold: number;
  exit_threshold: number;
}

export interface Chunk {
  start: number;
  end: number;
  peak_rms: number;
}

export interface PitchTrack {
  times: number[];
  hz: number[];
  midi: number[];
  voiced_prob: number[];
}

export interface AnalyzeResponse {
  notes: Note[];
  chunks: Chunk[];
  envelope: EnvelopeInfo;
  pitch_track: PitchTrack;
  waveform: Waveform;
  options: AnalyzeOptions;
  audio_id: string;
  detected_key: DetectedKey | null;
  assist_applied_count: number;
  key_candidates: KeyCandidate[];
}

export interface AssistResponse {
  notes: Note[];
  detected_key: DetectedKey;
  assist_applied_count: number;
  key_candidates: KeyCandidate[];
}

export interface SoundfontPreset {
  bank: number;
  program: number;
  name: string;
}

export interface RenderCapabilities {
  soundfont_available: boolean;
  sf2_path: string | null;
  error: string | null;
  available_programs: { id: number; name: string }[];
}
