/**
 * Stage 8 — sound synthesis via Tone.js. Minimal: one PolySynth, the user
 * picks an oscillator type. Real instrument sounds (SoundFont) are out of
 * scope for the MVP — add later if needed.
 */
import * as Tone from "tone";
import type { Note } from "../types";

export type OscType = "sine" | "triangle" | "sawtooth" | "square";

let synth: Tone.PolySynth | null = null;
let drum: Tone.NoiseSynth | null = null;
let currentOsc: OscType = "triangle";

function ensureSynth(osc: OscType): Tone.PolySynth {
  if (!synth || osc !== currentOsc) {
    if (synth) { synth.releaseAll(); synth.dispose(); }
    synth = new Tone.PolySynth(Tone.Synth, {
      oscillator: { type: osc },
      envelope: { attack: 0.005, decay: 0.1, sustain: 0.6, release: 0.2 },
    }).toDestination();
    synth.volume.value = -8;
    currentOsc = osc;
  }
  return synth;
}

function ensureDrum(): Tone.NoiseSynth {
  if (!drum) {
    drum = new Tone.NoiseSynth({
      noise: { type: "white" },
      envelope: { attack: 0.001, decay: 0.12, sustain: 0, release: 0.05 },
    }).toDestination();
    drum.volume.value = -10;
  }
  return drum;
}

export async function playNotes(notes: Note[], osc: OscType = "triangle"): Promise<void> {
  await Tone.start();
  const s = ensureSynth(osc);
  const d = ensureDrum();
  s.releaseAll();
  const now = Tone.now() + 0.05;
  for (const n of notes) {
    if (n.kind === "percussive") {
      d.triggerAttackRelease(Math.max(0.05, n.duration), now + n.start, n.velocity / 127);
    } else {
      const freq = Tone.Frequency(n.pitch, "midi").toFrequency();
      s.triggerAttackRelease(freq, Math.max(0.03, n.duration), now + n.start, n.velocity / 127);
    }
  }
}

export function stopPlayback() {
  if (synth) synth.releaseAll();
}

export async function playAudioBlob(blob: Blob): Promise<HTMLAudioElement> {
  const url = URL.createObjectURL(blob);
  const audio = new Audio(url);
  await audio.play();
  audio.addEventListener("ended", () => URL.revokeObjectURL(url));
  return audio;
}

// Sequential audition: play a blob and resolve only when it finishes (or is
// stopped via stopAudition). Used by the "audition all presets" button so we
// can chain hundreds of demos one after another.
let auditionAudio: HTMLAudioElement | null = null;

export function playAudioBlobToEnd(blob: Blob): Promise<void> {
  return new Promise((resolve) => {
    const url = URL.createObjectURL(blob);
    const audio = new Audio(url);
    auditionAudio = audio;
    const done = () => {
      URL.revokeObjectURL(url);
      if (auditionAudio === audio) auditionAudio = null;
      resolve();
    };
    audio.addEventListener("ended", done);
    audio.addEventListener("error", done);
    audio.play().catch(done);
  });
}

export function stopAudition() {
  if (auditionAudio) {
    auditionAudio.pause();
    auditionAudio.dispatchEvent(new Event("ended"));
  }
}
