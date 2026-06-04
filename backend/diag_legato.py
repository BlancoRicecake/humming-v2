"""연음(legato) 청크 분할 진단 — standalone, 앱 불변.

각 WAV에 대해 envelope 청크 → pitch/rms 서브분할 단계를 그대로 재현하며,
'연음' 분리가 어디서 일어나거나 막히는지 출력한다.

사용:
    .venv\\Scripts\\python diag_legato.py "C:\\path\\a.wav" "C:\\path\\b.wav" ...
    인자 없으면 soundsample 의 연음 샘플 + _debug_uploads/*.wav 전부.
"""
from __future__ import annotations
import os, sys, warnings, logging
from pathlib import Path
warnings.filterwarnings("ignore"); logging.disable(logging.WARNING)

import numpy as np
from app.analyze import _load_audio, HOP
from app.schemas import AnalyzeOptions
from app.envelope import (
    SUBDIVISION_MIN_CHUNK_DUR_SEC, compute_rms_envelope, compute_thresholds,
    post_process_chunks, segment_chunks_streaming, split_chunk_by_pitch, split_chunk_by_rms_dip,
)
from app.pitch import extract_pitch_pyin, extract_pitch_crepe, hz_to_midi_float
from app.analyze import analyze_audio

# Pick the pitch tracker for both the standalone trace and analyze_audio below.
PITCH_MODEL = os.environ.get("HUMMING_PITCH_MODEL", "pyin")

PC = ["C","C#","D","D#","E","F","F#","G","G#","A","A#","B"]
def nm(m):
    import math
    if m is None or (isinstance(m,float) and not math.isfinite(m)): return "--"
    mi=int(round(m)); return f"{PC[mi%12]}{mi//12-1}"


def diag(path: Path):
    o = AnalyzeOptions(pitch_model=PITCH_MODEL)
    raw = path.read_bytes()
    y, sr = _load_audio(raw)
    dur = len(y)/sr
    env_t, rms = compute_rms_envelope(y, sr, hop=HOP)
    th = compute_thresholds(rms, enter_ratio=o.enter_ratio, exit_ratio=o.exit_ratio)
    raw_chunks = post_process_chunks(
        segment_chunks_streaming(rms, env_t, th["enter"], th["exit"], exit_hold_sec=o.exit_hold_sec),
        min_chunk_dur_sec=o.min_chunk_dur_sec, merge_gap_sec=o.merge_gap_sec)
    if o.pitch_model == "crepe":
        p_t, p_hz, _v, _p = extract_pitch_crepe(
            y, sr, o.fmin_hz, o.fmax_hz, hop_length=HOP,
            conf_threshold=o.voiced_prob_threshold)
    else:
        p_t, p_hz, _v, _p = extract_pitch_pyin(y, sr, o.fmin_hz, o.fmax_hz, hop_length=HOP)
    p_m = hz_to_midi_float(p_hz)

    print("="*72)
    print(f"{path.name}   dur={dur:.2f}s  sr={sr}  model={o.pitch_model}  peakRMS={float(rms.max()):.4f}  envChunks={len(raw_chunks)}")
    print(f"  subdivide gate: chunk>{SUBDIVISION_MIN_CHUNK_DUR_SEC}s")
    total_after = 0
    for c in raw_chunks:
        cdur = c["end"]-c["start"]
        long = cdur >= SUBDIVISION_MIN_CHUNK_DUR_SEC
        pieces = [c]
        if long:
            pieces = [p for q in pieces for p in split_chunk_by_rms_dip(q, env_t, rms)]
            after_rms = len(pieces)
            pieces = [p for q in pieces for p in split_chunk_by_pitch(q, p_t, p_m)]
            after_pitch = len(pieces)
        else:
            after_rms = after_pitch = 1
        total_after += len(pieces)
        # 청크 내부 피치 윤곽 요약(글라이드 vs 홀드 판단)
        idx = np.where((p_t>=c["start"])&(p_t<=c["end"]))[0]
        seg = p_m[idx]; fin = seg[np.isfinite(seg)]
        contour = f"{nm(fin.min())}~{nm(fin.max())} span={float(fin.max()-fin.min()):.1f}st" if fin.size else "unvoiced"
        flag = " <== long, no split" if (long and after_pitch==1 and after_rms==1) else ""
        print(f"  chunk {c['start']:.2f}-{c['end']:.2f} ({cdur:.2f}s) {'LONG' if long else 'short'} "
              f"rms->{after_rms} pitch->{after_pitch}  contour[{contour}]{flag}")
    res = analyze_audio(raw, o)
    pit = [n for n in res.notes if n.kind=='pitched']
    print(f"  => final chunks={total_after}  notes={len(res.notes)} (pitched={len(pit)})  "
          f"key={res.detected_key.tonic if res.detected_key else None}{res.detected_key.scale if res.detected_key else ''}")
    print(f"     pitched notes: {[nm(n.pitch) for n in pit]}")


def main():
    args = sys.argv[1:]
    paths = [Path(a) for a in args]
    if not paths:
        ss = Path(os.environ.get("HUMMING_SAMPLES_DIR", r"C:\Users\jlion\Downloads\soundsample"))
        for cand in ["2. 연음.wav", "2번 연음.m4a"]:
            if (ss/cand).is_file(): paths.append(ss/cand)
        dbg = Path(__file__).resolve().parent / "_debug_uploads"
        if dbg.is_dir():
            paths += sorted(dbg.glob("*.wav"))
    for p in paths:
        if p.is_file(): diag(p)
        else: print(f"(missing) {p}")


if __name__ == "__main__":
    main()
