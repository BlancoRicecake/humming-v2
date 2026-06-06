#!/usr/bin/env python3
"""피치 오류 성격 진단 — 정렬쌍의 Δpitch 분포/편향 분석.

각 정렬쌍에서 (옥타브 정합된) ref - est 를:
  - 정수 반올림 Δ 히스토그램 (0, ±1, ±2, ≥3)
  - pitch_raw(float) 기준 부호있는 편향 → 체계적 flat/sharp(튜닝/반올림) 여부
  - off-by-≥2 비율(정렬오류/옥타브 추정)
"""
from __future__ import annotations
import os, sys, argparse, json
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
BACKEND = os.path.dirname(HERE)
DATA = os.path.join(BACKEND, ".eval_data")
sys.path.insert(0, BACKEND)

from app.analyze import analyze_audio  # noqa: E402
from app.schemas import AnalyzeOptions  # noqa: E402
from scripts.humtrans_eval import ref_notes_from_midi, align_sequences  # noqa: E402


def est_with_raw(resp):
    on, off, pit, raw = [], [], [], []
    for n in resp.notes:
        s, e = float(n.start), float(n.end)
        on.append(s); off.append(e if e > s else s + 1e-3)
        pit.append(float(n.pitch))
        raw.append(float(n.pitch_raw) if np.isfinite(n.pitch_raw) else float(n.pitch))
    order = np.argsort(on) if on else []
    f = lambda a: np.array(a, dtype=float)[order] if on else np.zeros(0)
    return f(on), f(off), f(pit), f(raw)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--keysfile", default=os.path.join(DATA, "rep_keys.txt"))
    ap.add_argument("--limit", type=int, default=120)
    ap.add_argument("--opts", default='{"enter_ratio":0.15}')
    ap.add_argument("--split", default="test")
    args = ap.parse_args()
    gtd = os.path.join(DATA, "HumTrans-main", "midis", "gt", "GroundTruth", args.split)
    keys = [l.strip() for l in open(args.keysfile) if l.strip()][:args.limit]
    opts = AnalyzeOptions(**json.loads(args.opts))

    dint, draw_signed = [], []
    for k in keys:
        w = f"{DATA}/wav/{k}.wav"; gt = f"{gtd}/{k}.mid"
        if not (os.path.exists(w) and os.path.exists(gt)):
            continue
        resp = analyze_audio(open(w, "rb").read(), opts)
        ron, roff, rp = ref_notes_from_midi(gt)
        eon, eoff, ep, eraw = est_with_raw(resp)
        m = (eon >= ron[0]) & (eon <= ron[-1])
        eon, eoff, ep, eraw = eon[m], eoff[m], ep[m], eraw[m]
        pairs, o = align_sequences(ron, eon, rp, ep)
        for ri, ej in pairs:
            dint.append((rp[ri] + 12 * o) - ep[ej])
            draw_signed.append((rp[ri] + 12 * o) - eraw[ej])
    di = np.array(dint); dr = np.array(draw_signed)
    n = len(di)
    print(f"정렬쌍 {n}개")
    print(f"Δpitch(int, ref-est) 분포:")
    for lab, lo, hi in [("정확(0)", -0.5, 0.5), ("+1(est flat)", 0.5, 1.5),
                        ("-1(est sharp)", -1.5, -0.5), ("+2", 1.5, 2.5),
                        ("-2", -2.5, -1.5)]:
        print(f"  {lab:14}: {100*np.mean((di>lo)&(di<=hi)):.1f}%")
    print(f"  |Δ|>=3 (정렬/옥타브 추정): {100*np.mean(np.abs(di)>=2.5):.1f}%")
    print(f"정확(±0.5) = pitch_acc: {100*np.mean(np.abs(di)<=0.5):.1f}%")
    print(f"±1 이내(반음 슬립 포함): {100*np.mean(np.abs(di)<=1.5):.1f}%")
    print(f"raw 부호편향(ref-est_raw): mean {dr.mean():+.3f}  median {np.median(dr):+.3f} 반음")
    print(f"  → +면 우리가 체계적으로 flat(낮게). |편향|>0.1이면 튜닝/반올림 의심")


if __name__ == "__main__":
    main()
