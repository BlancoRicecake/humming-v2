import type { Note } from "../types";

interface Props {
  notes: Note[];
  highlight?: number | null;
  selected?: number | null;
  onHover?: (i: number | null) => void;
  onSelect?: (i: number) => void;
}

const NOTE_NAMES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"];
const DRUM_NAMES: Record<number, string> = { 36: "Kick", 38: "Snare", 42: "HiHat" };

function midiToName(p: number) {
  return `${NOTE_NAMES[((p % 12) + 12) % 12]}${Math.floor(p / 12) - 1}`;
}

function noteLabel(n: { pitch: number; kind: string }) {
  return n.kind === "percussive" ? (DRUM_NAMES[n.pitch] ?? `Drum ${n.pitch}`) : midiToName(n.pitch);
}

const SRC_LABEL: Record<Note["source"], string> = {
  raw: "raw", assistant: "보정", user: "수정",
};

export function NoteTable({ notes, highlight, selected, onHover, onSelect }: Props) {
  if (!notes.length) return null;
  return (
    <div className="table-wrap">
      <table className="notes-table">
        <thead>
          <tr>
            <th>#</th><th>start</th><th>dur</th><th>pitch</th><th>orig</th><th>src</th>
            <th>cents</th><th>raw</th><th>Hz</th><th>vel</th><th>conf</th><th>voiced</th>
            <th>drum</th><th>cntr</th><th>roll</th><th>flat</th><th>zcr</th><th>onset</th><th>lo%</th><th>hi%</th>
            <th>lm%</th><th>md%</th><th>vh%</th><th>sus</th>
          </tr>
        </thead>
        <tbody>
          {notes.map((n, i) => {
            const cls = [
              i === highlight ? "hi" : "",
              i === selected ? "sel" : "",
              n.source === "assistant" ? "assisted" : "",
              n.source === "user" ? "edited" : "",
            ].filter(Boolean).join(" ");
            return (
              <tr key={i} className={cls}
                  onMouseEnter={() => onHover?.(i)} onMouseLeave={() => onHover?.(null)}
                  onClick={() => onSelect?.(i)}
                  style={{ cursor: onSelect ? "pointer" : undefined }}>
                <td>{i + 1}</td>
                <td>{n.start.toFixed(3)}</td>
                <td>{n.duration.toFixed(3)}</td>
                <td>{noteLabel(n)} ({n.pitch})</td>
                <td>{n.kind === "pitched" ? midiToName(n.pitch_original) : "—"}</td>
                <td>{SRC_LABEL[n.source]}</td>
                <td>{n.correction_cents ? n.correction_cents.toFixed(0) : "—"}</td>
                <td>{n.pitch_raw.toFixed(2)}</td>
                <td>{n.pitch_hz.toFixed(1)}</td>
                <td>{n.velocity}</td>
                <td>{n.confidence.toFixed(2)}</td>
                <td>{(n.voiced_ratio * 100).toFixed(0)}%</td>
                <td>{n.drum != null ? `${n.drum_name ?? DRUM_NAMES[n.drum] ?? n.drum}` : "—"}</td>
                <td>{n.drum_centroid ? n.drum_centroid.toFixed(0) : "—"}</td>
                <td>{n.drum_rolloff ? n.drum_rolloff.toFixed(0) : "—"}</td>
                <td>{n.drum_flatness ? n.drum_flatness.toFixed(3) : "—"}</td>
                <td>{n.drum_zcr ? n.drum_zcr.toFixed(2) : "—"}</td>
                <td>{n.onset_strength ? n.onset_strength.toFixed(2) : "—"}</td>
                <td>{n.drum_low_ratio ? (n.drum_low_ratio * 100).toFixed(0) : "—"}</td>
                <td>{n.drum_high_ratio ? (n.drum_high_ratio * 100).toFixed(0) : "—"}</td>
                <td>{n.drum_lowmid_ratio ? (n.drum_lowmid_ratio * 100).toFixed(0) : "—"}</td>
                <td>{n.drum_mid_ratio ? (n.drum_mid_ratio * 100).toFixed(0) : "—"}</td>
                <td>{n.drum_vhigh_ratio ? (n.drum_vhigh_ratio * 100).toFixed(0) : "—"}</td>
                <td>{n.drum_sustain_ratio ? n.drum_sustain_ratio.toFixed(2) : "—"}</td>
              </tr>
            );
          })}
        </tbody>
      </table>
    </div>
  );
}
