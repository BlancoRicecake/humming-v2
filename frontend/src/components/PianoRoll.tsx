import { useEffect, useRef, type MouseEvent } from "react";
import type { Note } from "../types";

interface Props {
  notes: Note[];
  duration: number;
  height?: number;
  highlightNoteIndex?: number | null;
  selectedIndex?: number | null;
  onNoteClick?: (i: number) => void;
}

const NOTE_NAMES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"];
const DRUM_NAMES: Record<number, string> = { 36: "Kick", 38: "Snare", 42: "HiHat" };

// note fill by provenance — assistant-corrected / user-edited stand out.
function noteColor(n: Note): string {
  if (n.kind === "percussive") return "#a371f7";
  if (n.source === "user") return "#3fb950";       // green — user edited
  if (n.source === "assistant") return "#f0883e";  // orange — assistant corrected
  return "#58a6ff";                                 // blue — raw
}

export function PianoRoll({
  notes, duration, height = 240, highlightNoteIndex, selectedIndex, onNoteClick,
}: Props) {
  const canvasRef = useRef<HTMLCanvasElement | null>(null);
  // geometry captured each render so the click handler can hit-test.
  const geomRef = useRef<{ minP: number; rowH: number; dur: number; cssWidth: number } | null>(null);

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    const dpr = window.devicePixelRatio || 1;
    const cssWidth = canvas.clientWidth;
    canvas.width = cssWidth * dpr;
    canvas.height = height * dpr;
    const ctx = canvas.getContext("2d")!;
    ctx.scale(dpr, dpr);
    ctx.clearRect(0, 0, cssWidth, height);

    ctx.fillStyle = "#0d1117";
    ctx.fillRect(0, 0, cssWidth, height);

    if (!notes.length) {
      ctx.fillStyle = "#8b949e";
      ctx.font = "12px system-ui, sans-serif";
      ctx.fillText("(no notes yet — record and analyze)", 12, 24);
      return;
    }

    const pitches = notes.map((n) => n.pitch);
    let minP = Math.min(...pitches) - 2;
    let maxP = Math.max(...pitches) + 2;
    if (maxP - minP < 12) {
      const c = (maxP + minP) / 2;
      minP = Math.floor(c - 6);
      maxP = Math.ceil(c + 6);
    }
    const pitchRange = maxP - minP + 1;
    const rowH = (height - 24) / pitchRange;
    const dur = Math.max(duration, notes[notes.length - 1].end + 0.1, 0.5);
    geomRef.current = { minP, rowH, dur, cssWidth };

    // row striping + labels
    for (let p = minP; p <= maxP; p++) {
      const y = height - 24 - (p - minP + 1) * rowH;
      const isBlack = [1, 3, 6, 8, 10].includes(((p % 12) + 12) % 12);
      ctx.fillStyle = isBlack ? "#161b22" : "#1c2128";
      ctx.fillRect(36, y, cssWidth - 36, rowH);
      if (p % 12 === 0) {
        ctx.fillStyle = "#8b949e";
        ctx.font = "10px system-ui, sans-serif";
        const oct = Math.floor(p / 12) - 1;
        ctx.fillText(`C${oct}`, 4, y + rowH * 0.75);
      }
    }

    // time axis
    ctx.strokeStyle = "#30363d";
    ctx.lineWidth = 1;
    const ticks = 8;
    for (let i = 0; i <= ticks; i++) {
      const t = (dur / ticks) * i;
      const x = 36 + (t / dur) * (cssWidth - 36);
      ctx.beginPath();
      ctx.moveTo(x, 0);
      ctx.lineTo(x, height - 24);
      ctx.stroke();
      ctx.fillStyle = "#6e7681";
      ctx.font = "10px system-ui, sans-serif";
      ctx.fillText(t.toFixed(2) + "s", x + 2, height - 8);
    }

    // notes
    notes.forEach((n, i) => {
      const x = 36 + (n.start / dur) * (cssWidth - 36);
      const w = Math.max(2, ((n.end - n.start) / dur) * (cssWidth - 36));
      const y = height - 24 - (n.pitch - minP + 1) * rowH;
      const isHi = i === highlightNoteIndex;
      const isSel = i === selectedIndex;
      ctx.fillStyle = isHi ? "#f7c948" : noteColor(n);
      ctx.fillRect(x, y + 1, w, Math.max(2, rowH - 2));
      if (isSel) {
        ctx.strokeStyle = "#ffffff";
        ctx.lineWidth = 2;
        ctx.strokeRect(x, y + 1, w, Math.max(2, rowH - 2));
      }
      ctx.fillStyle = "#0d1117";
      ctx.font = "10px system-ui, sans-serif";
      const label = n.kind === "percussive"
        ? (DRUM_NAMES[n.pitch] ?? `D${n.pitch}`)
        : `${NOTE_NAMES[((n.pitch % 12) + 12) % 12]}${Math.floor(n.pitch / 12) - 1}`;
      if (w > 22) ctx.fillText(label, x + 2, y + rowH - 3);
    });
  }, [notes, duration, height, highlightNoteIndex, selectedIndex]);

  const handleClick = (e: MouseEvent<HTMLCanvasElement>) => {
    if (!onNoteClick) return;
    const g = geomRef.current;
    const canvas = canvasRef.current;
    if (!g || !canvas) return;
    const rect = canvas.getBoundingClientRect();
    const px = e.clientX - rect.left;
    const py = e.clientY - rect.top;
    const t = ((px - 36) / (g.cssWidth - 36)) * g.dur;
    // pitch row under the cursor
    const pitchAtY = g.minP + (height - 24 - py) / g.rowH;
    // pick the note whose time span contains t and whose pitch row is closest
    let best = -1;
    let bestDist = Infinity;
    notes.forEach((n, i) => {
      if (t >= n.start && t <= n.end) {
        const d = Math.abs(n.pitch + 0.5 - pitchAtY);
        if (d < bestDist) { bestDist = d; best = i; }
      }
    });
    if (best >= 0 && bestDist <= 1.5) onNoteClick(best);
  };

  return (
    <canvas
      ref={canvasRef}
      onClick={handleClick}
      style={{
        width: "100%", height, display: "block", borderRadius: 6,
        cursor: onNoteClick ? "pointer" : "default",
      }}
    />
  );
}
