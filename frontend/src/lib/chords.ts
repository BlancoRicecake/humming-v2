/**
 * Chord mode — expand a monophonic melody into diatonic triads using the
 * detected key. Pure client-side; the render/MIDI backends already handle
 * simultaneous notes, so we just emit extra Note objects sharing start/end.
 *
 * Scale intervals mirror backend/app/scales.py (major/minor are the only Auto
 * Key outputs; others included for manual keys).
 */
import type { DetectedKey, Note } from "../types";

const NOTE_TO_PC: Record<string, number> = {
  C: 0, "C#": 1, DB: 1, D: 2, "D#": 3, EB: 3, E: 4, F: 5, "F#": 6, GB: 6,
  G: 7, "G#": 8, AB: 8, A: 9, "A#": 10, BB: 10, B: 11,
};

const SCALE_INTERVALS: Record<string, number[]> = {
  major: [0, 2, 4, 5, 7, 9, 11],
  minor: [0, 2, 3, 5, 7, 8, 10],
  harmonic_minor: [0, 2, 3, 5, 7, 8, 11],
  melodic_minor: [0, 2, 3, 5, 7, 9, 11],
  dorian: [0, 2, 3, 5, 7, 9, 10],
  phrygian: [0, 1, 3, 5, 7, 8, 10],
  lydian: [0, 2, 4, 6, 7, 9, 11],
  mixolydian: [0, 2, 4, 5, 7, 9, 10],
  locrian: [0, 1, 3, 5, 6, 8, 10],
  major_pentatonic: [0, 2, 4, 7, 9],
  minor_pentatonic: [0, 3, 5, 7, 10],
  blues: [0, 3, 5, 6, 7, 10],
  chromatic: [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11],
};

function tonicToPc(tonic: string): number | null {
  const k = tonic.trim().toUpperCase().replace("♯", "#").replace("♭", "B");
  return k in NOTE_TO_PC ? NOTE_TO_PC[k] : null;
}

/** Build a diatonic triad (root + 3rd + 5th) for `rootMidi` within the key. */
export function buildDiatonicTriad(rootMidi: number, tonic: string, scale: string): number[] {
  const rootPc = tonicToPc(tonic);
  const intervals = SCALE_INTERVALS[scale];
  if (rootPc == null || !intervals) {
    // no usable key → plain major triad
    return [rootMidi, rootMidi + 4, rootMidi + 7];
  }
  // ascending list of in-key MIDI pitches across the relevant range
  const pcs = intervals.map((iv) => (rootPc + iv) % 12);
  const pcSet = new Set(pcs);
  const ladder: number[] = [];
  for (let m = rootMidi - 12; m <= rootMidi + 24; m++) {
    if (pcSet.has(((m % 12) + 12) % 12)) ladder.push(m);
  }
  // find the ladder index at/above rootMidi (snap up if root off-scale)
  let i = ladder.findIndex((m) => m >= rootMidi);
  if (i < 0) return [rootMidi, rootMidi + 4, rootMidi + 7];
  const root = ladder[i];
  const third = ladder[i + 2] ?? root + 4;   // skip one scale step = a third
  const fifth = ladder[i + 4] ?? root + 7;
  return [root, third, fifth];
}

/**
 * Expand pitched notes into chord tones when in chord mode. Percussive notes
 * pass through unchanged. Chord (non-root) tones get slightly lower velocity.
 */
export function expandChords(notes: Note[], key: DetectedKey | null): Note[] {
  const tonic = key?.tonic;
  const scale = key?.scale;
  const out: Note[] = [];
  for (const n of notes) {
    if (n.kind !== "pitched" || !tonic || !scale) {
      out.push(n);
      continue;
    }
    const chord = buildDiatonicTriad(n.pitch, tonic, scale);
    chord.forEach((p, idx) => {
      out.push({
        ...n,
        pitch: p,
        pitch_hz: 440 * Math.pow(2, (p - 69) / 12),
        velocity: idx === 0 ? n.velocity : Math.max(1, Math.round(n.velocity * 0.82)),
      });
    });
  }
  return out;
}
