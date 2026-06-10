// Read-only reuse of the main SoundLab frontend's editor components.
// We import their .tsx source directly — nothing in frontend/ is modified.
// Depth: web/src → web → ace-fusion → labs → (Humming V2 root) → frontend/src
export { PianoRoll } from "../../../../frontend/src/components/PianoRoll";
export { NoteTable } from "../../../../frontend/src/components/NoteTable";
export { CandidatePicker } from "../../../../frontend/src/components/CandidatePicker";
export type { Note, DetectedKey } from "../../../../frontend/src/types";
