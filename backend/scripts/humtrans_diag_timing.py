#!/usr/bin/env python3
"""타이밍 실패 분해 — 리듬(IOI) 정확도가 무엇에 막혀 있는지.

연속 정렬쌍의 IOI 비율(템포 정규화)을 모아:
  - 허용배수 1.5/1.75/2.0 별 통과율 (관대화하면 얼마나 오르나)
  - '깨끗한' 쌍(사이에 누락 ref 없음) vs '갭 포함' 쌍 통과율 분리
    → 누락 노트가 원인인지, 본질적 루바토 분산인지 구분
"""
from __future__ import annotations
import os, sys, json, argparse
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
BACKEND = os.path.dirname(HERE)
DATA = os.path.join(BACKEND, ".eval_data")
sys.path.insert(0, BACKEND)

from app.analyze import analyze_audio  # noqa: E402
from app.schemas import AnalyzeOptions  # noqa: E402
from scripts.humtrans_eval import (  # noqa: E402
    ref_notes_from_midi, est_notes_from_response, align_sequences)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--keysfile", default=os.path.join(DATA, "rep_keys.txt"))
    ap.add_argument("--limit", type=int, default=120)
    ap.add_argument("--split", default="test")
    args = ap.parse_args()
    gtdir = os.path.join(DATA, "HumTrans-main", "midis", "gt", "GroundTruth", args.split)
    keys = [l.strip() for l in open(args.keysfile) if l.strip()][:args.limit]
    opts = AnalyzeOptions()

    ratios_clean, ratios_gap = [], []
    for key in keys:
        wav = os.path.join(DATA, "wav", key + ".wav")
        gt = os.path.join(gtdir, key + ".mid")
        if not (os.path.exists(wav) and os.path.exists(gt)):
            continue
        resp = analyze_audio(open(wav, "rb").read(), opts)
        ron, roff, rp = ref_notes_from_midi(gt)
        eon, eoff, ep = est_notes_from_response(resp, "final")
        m = (eon >= ron[0]) & (eon <= ron[-1])
        eon, eoff, ep = eon[m], eoff[m], ep[m]
        pairs, o = align_sequences(ron, eon, rp, ep)
        if len(pairs) < 2:
            continue
        rio = np.array([ron[pairs[k+1][0]] - ron[pairs[k][0]] for k in range(len(pairs)-1)])
        eio = np.array([eon[pairs[k+1][1]] - eon[pairs[k][1]] for k in range(len(pairs)-1)])
        valid = (rio > 1e-3) & (eio > 1e-3)
        if valid.sum() == 0:
            continue
        scale = float(np.sum(eio[valid]) / np.sum(rio[valid]))
        for k in range(len(pairs)-1):
            if not valid[k]:
                continue
            r = (eio[k]/scale)/rio[k]
            # 사이에 누락된 ref 노트가 있나? (ref 인덱스 연속이면 깨끗)
            clean = (pairs[k+1][0] - pairs[k][0] == 1) and (pairs[k+1][1] - pairs[k][1] == 1)
            (ratios_clean if clean else ratios_gap).append(r)

    rc = np.array(ratios_clean); rg = np.array(ratios_gap)
    allr = np.concatenate([rc, rg]) if len(rg) else rc
    def passrate(a, t): return float(np.mean((a >= 1/t) & (a <= t))) if len(a) else 0.0
    print(f"연속 정렬쌍 IOI: 깨끗 {len(rc)} / 갭포함 {len(rg)}")
    for t in [1.5, 1.75, 2.0, 2.5]:
        print(f"  tol×{t}: 전체 {passrate(allr,t):.3f} | 깨끗 {passrate(rc,t):.3f} | 갭 {passrate(rg,t):.3f}")
    print(f"IOI비 분포(전체): median {np.median(allr):.2f} "
          f"p10 {np.percentile(allr,10):.2f} p90 {np.percentile(allr,90):.2f}")
    print(f"깨끗 쌍만: median {np.median(rc):.2f} p10 {np.percentile(rc,10):.2f} p90 {np.percentile(rc,90):.2f}")


if __name__ == "__main__":
    main()
