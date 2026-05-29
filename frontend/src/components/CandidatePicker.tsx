import type { Note } from "../types";

interface Props {
  note: Note;
  index: number;
  onSelect: (pitch: number) => void;
  onClose: () => void;
}

const NOTE_NAMES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"];
function midiToName(p: number) {
  return `${NOTE_NAMES[((p % 12) + 12) % 12]}${Math.floor(p / 12) - 1}`;
}

export function CandidatePicker({ note, index, onSelect, onClose }: Props) {
  // candidates from backend always include pitch_original; show original explicitly too.
  const options = Array.from(new Set([note.pitch_original, ...note.candidates])).sort((a, b) => a - b);

  return (
    <div className="candidate-picker">
      <div className="cp-head">
        <strong>노트 #{index + 1}</strong> 수정
        <button className="cp-close" onClick={onClose}>✕</button>
      </div>
      <div className="cp-row">
        <span className="meta">현재: <strong>{midiToName(note.pitch)}</strong>
          {note.source === "assistant" && " (어시스턴트)"}
          {note.source === "user" && " (수정됨)"}
        </span>
      </div>
      <div className="cp-options">
        {options.map((p) => {
          const isCurrent = p === note.pitch;
          const isOriginal = p === note.pitch_original;
          return (
            <button
              key={p}
              className={`cp-opt ${isCurrent ? "current" : ""}`}
              onClick={() => onSelect(p)}
              title={isOriginal ? "원본 유지" : undefined}
            >
              {midiToName(p)}
              {isOriginal && <span className="cp-tag">원본</span>}
            </button>
          );
        })}
      </div>
    </div>
  );
}
