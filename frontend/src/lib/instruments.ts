/**
 * Role-based instrument palette (single-instrument selection).
 * `program` = GM bank-0 program number (all present in the bundled SoundFont).
 * Drums are handled automatically for percussive takes (kick/snare/hi-hat),
 * so they are not a selectable melodic program here.
 */
export interface Instrument {
  label: string;
  program: number;
  chordCapable?: boolean; // keyboard/guitar support single/chord mode
}

export interface InstrumentRole {
  role: string;
  label: string;
  instruments: Instrument[];
}

export const INSTRUMENT_ROLES: InstrumentRole[] = [
  {
    role: "bass",
    label: "베이스",
    instruments: [
      { label: "베이스 기타", program: 33 }, // Finger Bass
      { label: "신스 베이스", program: 39 }, // Synth Bass 2
    ],
  },
  {
    role: "keyboard",
    label: "키보드",
    instruments: [
      { label: "피아노", program: 0, chordCapable: true },
      { label: "신스", program: 90, chordCapable: true }, // Polysynth
    ],
  },
  {
    role: "guitar",
    label: "기타",
    instruments: [
      { label: "어쿠스틱 기타", program: 25, chordCapable: true }, // Steel Guitar
      { label: "일렉 기타", program: 27, chordCapable: true },     // Clean Guitar
    ],
  },
];

const BY_PROGRAM: Record<number, Instrument> = {};
for (const r of INSTRUMENT_ROLES) for (const i of r.instruments) BY_PROGRAM[i.program] = i;

export function instrumentByProgram(program: number): Instrument | undefined {
  return BY_PROGRAM[program];
}

export function isChordCapable(program: number): boolean {
  return !!BY_PROGRAM[program]?.chordCapable;
}
