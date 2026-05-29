import { useEffect, useRef } from "react";
import type { Chunk, EnvelopeInfo, Waveform } from "../types";

interface Props {
  waveform: Waveform;
  pitchTrack?: { times: number[]; midi: number[] };
  envelope?: EnvelopeInfo | null;
  chunks?: Chunk[] | null;
  showEnvelope?: boolean;
  height?: number;
}

export function WaveformView({
  waveform,
  pitchTrack,
  envelope,
  chunks,
  showEnvelope = true,
  height = 180,
}: Props) {
  const canvasRef = useRef<HTMLCanvasElement | null>(null);

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

    // background
    ctx.fillStyle = "#0d1117";
    ctx.fillRect(0, 0, cssWidth, height);

    const duration = waveform.duration || 1;
    const peaks = waveform.peaks;

    // Layer 0: chunk boxes (drawn BEHIND everything so they read as background tint)
    if (showEnvelope && chunks && chunks.length) {
      ctx.fillStyle = "rgba(247, 201, 72, 0.16)";
      ctx.strokeStyle = "rgba(247, 201, 72, 0.85)";
      ctx.lineWidth = 1;
      for (const c of chunks) {
        const x0 = (c.start / duration) * cssWidth;
        const x1 = (c.end / duration) * cssWidth;
        const w = Math.max(1, x1 - x0);
        ctx.fillRect(x0, 0, w, height);
        ctx.beginPath();
        ctx.moveTo(x0, 0); ctx.lineTo(x0, height);
        ctx.moveTo(x1, 0); ctx.lineTo(x1, height);
        ctx.stroke();
      }
    }

    // Layer 1: waveform peaks (green bars, vertically centered)
    ctx.fillStyle = "#3fb950";
    if (peaks.length) {
      const colW = cssWidth / peaks.length;
      for (let i = 0; i < peaks.length; i++) {
        const h = peaks[i] * (height - 8);
        const y = (height - h) / 2;
        ctx.fillRect(i * colW, y, Math.max(1, colW - 0.5), h);
      }
    }

    // Layer 2: RMS envelope curve (drawn near the bottom so it doesn't fight
    // with the waveform peaks). Normalized to fit in bottom 60% of the canvas.
    if (showEnvelope && envelope && envelope.times.length) {
      const rmsMax = Math.max(envelope.peak_level, 0.001);
      const baseY = height - 6;            // bottom margin
      const rmsScale = (height * 0.55);    // vertical room
      ctx.strokeStyle = "rgba(255, 215, 0, 0.85)";
      ctx.lineWidth = 1.4;
      ctx.beginPath();
      let started = false;
      for (let i = 0; i < envelope.times.length; i++) {
        const t = envelope.times[i];
        const v = envelope.rms[i];
        const x = (t / duration) * cssWidth;
        const y = baseY - Math.min(v / rmsMax, 1.2) * rmsScale;
        if (!started) {
          ctx.moveTo(x, y);
          started = true;
        } else {
          ctx.lineTo(x, y);
        }
      }
      ctx.stroke();

      // Layer 3: enter/exit threshold horizontal lines
      const enterY = baseY - Math.min(envelope.enter_threshold / rmsMax, 1.2) * rmsScale;
      const exitY  = baseY - Math.min(envelope.exit_threshold  / rmsMax, 1.2) * rmsScale;
      ctx.setLineDash([4, 3]);
      ctx.strokeStyle = "rgba(86, 212, 221, 0.85)"; // cyan
      ctx.beginPath();
      ctx.moveTo(0, enterY); ctx.lineTo(cssWidth, enterY); ctx.stroke();
      ctx.fillStyle = "rgba(86, 212, 221, 0.85)";
      ctx.font = "10px ui-monospace, monospace";
      ctx.fillText(`enter ${envelope.enter_threshold.toFixed(4)}`, 4, enterY - 2);

      ctx.strokeStyle = "rgba(247, 129, 102, 0.85)"; // orange
      ctx.beginPath();
      ctx.moveTo(0, exitY); ctx.lineTo(cssWidth, exitY); ctx.stroke();
      ctx.fillStyle = "rgba(247, 129, 102, 0.85)";
      ctx.fillText(`exit  ${envelope.exit_threshold.toFixed(4)}`, 4, exitY + 10);
      ctx.setLineDash([]);
    }

    // Layer 4: pitch contour overlay (normalized to visible MIDI range)
    if (pitchTrack && pitchTrack.times.length) {
      const validMidi = pitchTrack.midi.filter((m) => Number.isFinite(m));
      if (validMidi.length) {
        let minM = Math.min(...validMidi);
        let maxM = Math.max(...validMidi);
        if (maxM - minM < 6) {
          const c = (maxM + minM) / 2;
          minM = c - 6;
          maxM = c + 6;
        }
        ctx.strokeStyle = "#58a6ff";
        ctx.lineWidth = 1.4;
        ctx.beginPath();
        let drawing = false;
        for (let i = 0; i < pitchTrack.times.length; i++) {
          const t = pitchTrack.times[i];
          const m = pitchTrack.midi[i];
          if (!Number.isFinite(m)) {
            drawing = false;
            continue;
          }
          const x = (t / duration) * cssWidth;
          const y = height - ((m - minM) / (maxM - minM)) * (height - 8) - 4;
          if (!drawing) {
            ctx.moveTo(x, y);
            drawing = true;
          } else {
            ctx.lineTo(x, y);
          }
        }
        ctx.stroke();
      }
    }

  }, [waveform, pitchTrack, envelope, chunks, showEnvelope, height]);

  return (
    <canvas
      ref={canvasRef}
      style={{ width: "100%", height, display: "block", borderRadius: 6 }}
    />
  );
}
