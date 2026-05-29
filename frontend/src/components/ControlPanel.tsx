import type { AnalyzeOptions } from "../types";
import type { OscType } from "../lib/playback";

interface Props {
  options: AnalyzeOptions;
  onChange: (o: AnalyzeOptions) => void;
  osc: OscType;
  onOscChange: (o: OscType) => void;
  disabled?: boolean;
}

const OSCS: OscType[] = ["sine", "triangle", "sawtooth", "square"];

export function ControlPanel({ options, onChange, osc, onOscChange, disabled }: Props) {
  const set = <K extends keyof AnalyzeOptions>(k: K, v: AnalyzeOptions[K]) =>
    onChange({ ...options, [k]: v });

  return (
    <div className="panel">
      <h3 className="panel-h">Stage 3-4 — voice region & chunk segmentation</h3>
      <div className="grid">
        <label>enter ratio {options.enter_ratio.toFixed(2)}
          <input type="range" min={0.05} max={0.6} step={0.01}
            value={options.enter_ratio} disabled={disabled}
            onChange={(e) => set("enter_ratio", parseFloat(e.target.value))} />
        </label>
        <label>exit ratio {options.exit_ratio.toFixed(2)}
          <input type="range" min={0.03} max={0.4} step={0.01}
            value={options.exit_ratio} disabled={disabled}
            onChange={(e) => set("exit_ratio", parseFloat(e.target.value))} />
        </label>
        <label>exit hold {options.exit_hold_sec.toFixed(3)}s
          <input type="range" min={0.01} max={0.15} step={0.005}
            value={options.exit_hold_sec} disabled={disabled}
            onChange={(e) => set("exit_hold_sec", parseFloat(e.target.value))} />
        </label>
        <label>min chunk dur {options.min_chunk_dur_sec.toFixed(3)}s
          <input type="range" min={0.03} max={0.3} step={0.005}
            value={options.min_chunk_dur_sec} disabled={disabled}
            onChange={(e) => set("min_chunk_dur_sec", parseFloat(e.target.value))} />
        </label>
        <label>merge gap {options.merge_gap_sec.toFixed(3)}s
          <input type="range" min={0.01} max={0.2} step={0.005}
            value={options.merge_gap_sec} disabled={disabled}
            onChange={(e) => set("merge_gap_sec", parseFloat(e.target.value))} />
        </label>
        <label className="checkbox">
          <input type="checkbox" checked={options.rms_dip_split} disabled={disabled}
            onChange={(e) => set("rms_dip_split", e.target.checked)} />
          RMS-dip split (same-note repeats)
        </label>
        <label className="checkbox">
          <input type="checkbox" checked={options.pitch_split} disabled={disabled}
            onChange={(e) => set("pitch_split", e.target.checked)} />
          Pitch-transition split (different-note legato)
        </label>
      </div>

      <h3 className="panel-h">Stage 5 — pitch analysis</h3>
      <div className="grid">
        <label>voiced threshold {options.voiced_prob_threshold.toFixed(2)}
          <input type="range" min={0.1} max={0.9} step={0.05}
            value={options.voiced_prob_threshold} disabled={disabled}
            onChange={(e) => set("voiced_prob_threshold", parseFloat(e.target.value))} />
        </label>
        <label>fmin (Hz) {options.fmin_hz.toFixed(0)}
          <input type="range" min={40} max={300} step={5}
            value={options.fmin_hz} disabled={disabled}
            onChange={(e) => set("fmin_hz", parseFloat(e.target.value))} />
        </label>
        <label>fmax (Hz) {options.fmax_hz.toFixed(0)}
          <input type="range" min={300} max={2000} step={10}
            value={options.fmax_hz} disabled={disabled}
            onChange={(e) => set("fmax_hz", parseFloat(e.target.value))} />
        </label>
      </div>

      <h3 className="panel-h">Stage 8 — preview instrument</h3>
      <div className="grid">
        <label>instrument (oscillator)
          <select value={osc} onChange={(e) => onOscChange(e.target.value as OscType)} disabled={disabled}>
            {OSCS.map((o) => <option key={o} value={o}>{o}</option>)}
          </select>
        </label>
        <span className="meta">Key / Pitch Assistant 는 결과(Step 4) 바에서 조정합니다.</span>
      </div>
    </div>
  );
}
