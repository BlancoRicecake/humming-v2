/**
 * Role-based instrument palette, built dynamically from the loaded SF2's
 * preset list. Each instrument carries both `bank` and `program` (so non-GM
 * banks — ukulele, variation pianos, drum kits — render correctly) plus a
 * stable per-category `code` (P01, AG03, D05…) assigned in SF2 upload order.
 *
 * Selection rules (per user spec):
 *  - 피아노(P)        : name contains "piano", excluding GM bank-0 prog 5/6/7
 *  - 어쿠스틱 기타(AG): GM 24–28 + Ukulele
 *  - 일렉 기타(LG)    : GM 29, 30
 *  - 신스(SM)         : GM 90 (Polysynth)
 *  - 베이스 기타(BG)  : GM 33 (Finger Bass)
 *  - 신스 베이스(SB)  : GM 39 (Synth Bass 2)
 *  - 드럼 키트(D)     : bank 128 prog 0,1,2,8,16,24,25,26,32,40
 */
import type { SoundfontPreset } from "../types";

export interface Instrument {
  code: string;            // category code, e.g. "P01", "AG03", "D05"
  label: string;           // SF2 preset name
  bank: number;
  program: number;
  chordCapable?: boolean;  // keyboard/guitar/synth support single/chord mode
}

export interface InstrumentRole {
  role: string;
  label: string;
  instruments: Instrument[];
}

interface CategorySpec {
  role: string;
  label: string;
  prefix: string;          // unique-id prefix (P, AG, LG, SM, BG, SB, D)
  chordCapable?: boolean;
  match: (p: SoundfontPreset) => boolean;
}

const DRUM_KITS = new Set([0, 1, 2, 8, 16, 24, 25, 26, 32, 40]);

const CATEGORIES: CategorySpec[] = [
  {
    role: "piano", label: "피아노", prefix: "P", chordCapable: true,
    match: (p) =>
      p.name.toLowerCase().includes("piano") &&
      !(p.bank === 0 && (p.program === 5 || p.program === 6 || p.program === 7)),
  },
  {
    role: "acoustic_guitar", label: "어쿠스틱 기타", prefix: "AG", chordCapable: true,
    match: (p) =>
      (p.bank === 0 && p.program >= 24 && p.program <= 28) ||
      p.name.toLowerCase().includes("ukulele"),
  },
  {
    role: "electric_guitar", label: "일렉 기타", prefix: "LG", chordCapable: true,
    match: (p) => p.bank === 0 && (p.program === 29 || p.program === 30),
  },
  {
    role: "synth", label: "신스", prefix: "SM", chordCapable: true,
    match: (p) => p.bank === 0 && p.program === 90,
  },
  {
    role: "bass_guitar", label: "베이스 기타", prefix: "BG",
    match: (p) => p.bank === 0 && p.program === 33,
  },
  {
    role: "synth_bass", label: "신스 베이스", prefix: "SB",
    match: (p) => p.bank === 0 && p.program === 39,
  },
  {
    role: "drums", label: "드럼 키트", prefix: "D",
    match: (p) => p.bank === 128 && DRUM_KITS.has(p.program),
  },
];

export function instrumentKey(bank: number, program: number): string {
  return `${bank}:${program}`;
}

/**
 * Build the categorized palette from the SF2 preset list. `presets` is assumed
 * sorted by (bank, program) — i.e. SF2 upload order — which fixes the code
 * numbering (P01, P02, … in that order). Empty categories are dropped.
 */
export function buildInstrumentPalette(presets: SoundfontPreset[]): InstrumentRole[] {
  return CATEGORIES.map((cat) => {
    const items: Instrument[] = presets
      .filter(cat.match)
      .map((p, i) => ({
        code: `${cat.prefix}${String(i + 1).padStart(2, "0")}`,
        label: p.name,
        bank: p.bank,
        program: p.program,
        chordCapable: cat.chordCapable,
      }));
    return { role: cat.role, label: cat.label, instruments: items };
  }).filter((r) => r.instruments.length > 0);
}
