#!/usr/bin/env python3
"""누락 노트 진단 — 정렬 안 된 GT 노트(=우리가 못 만든 노트)의 성격 분석.

각 세그먼트를 정렬한 뒤, 짝이 없는 ref 노트를 모아:
  - 길이(짧은가?)
  - 이전 노트와 같은 음인가(반복음?)
  - 이전 노트와의 간격(빠른 연타?)
통계로 어떤 레버(분절/게이트/onset)가 효과적일지 가늠.
"""
from __future__ import annotations
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
BACKEND = os.path.dirname(HERE)
DATA = os.path.join(BACKEND, ".eval_data")
sys.path.insert(0, BACKEND)

from app.analyze import analyze_audio  # noqa: E402
from app.schemas import AnalyzeOptions  # noqa: E402
from scripts.humtrans_eval import (  # noqa: E402
    ref_notes_from_midi, est_notes_from_response, align_sequences, load_keys,
)


def main():
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--split", default="test")
    ap.add_argument("--limit", type=int, default=80)
    ap.add_argument("--opts", default="{}")
    args = ap.parse_args()
    import json
    opts = AnalyzeOptions(**json.loads(args.opts))
    gtdir = os.path.join(DATA, "HumTrans-main", "midis", "gt", "GroundTruth", args.split)
    keys = load_keys(args.split, args.limit)

    miss_dur, kept_dur = [], []
    miss_same, miss_total = 0, 0
    miss_gap = []
    n_ref_tot, n_est_tot, n_miss_tot, n_extra_tot = 0, 0, 0, 0
    for key in keys:
        wav = os.path.join(DATA, "wav", key + ".wav")
        gt = os.path.join(gtdir, key + ".mid")
        if not (os.path.exists(wav) and os.path.exists(gt)):
            continue
        resp = analyze_audio(open(wav, "rb").read(), opts)
        ron, roff, rp = ref_notes_from_midi(gt)
        eon, eoff, ep = est_notes_from_response(resp, "final")
        # trim est to ref span
        m = (eon >= ron[0]) & (eon <= ron[-1])
        eon, eoff, ep = eon[m], eoff[m], ep[m]
        pairs, o = align_sequences(ron, eon, rp, ep)
        matched_ref = {ri for ri, _ in pairs}
        matched_est = {ej for _, ej in pairs}
        n_ref_tot += len(ron); n_est_tot += len(eon)
        n_miss_tot += len(ron) - len(matched_ref)
        n_extra_tot += len(eon) - len(matched_est)
        for i in range(len(ron)):
            dur = roff[i] - ron[i]
            if i in matched_ref:
                kept_dur.append(dur)
            else:
                miss_total += 1
                miss_dur.append(dur)
                if i > 0:
                    if abs(rp[i] - rp[i - 1]) < 0.5:
                        miss_same += 1
                    miss_gap.append(ron[i] - ron[i - 1])

    md = np.array(miss_dur); kd = np.array(kept_dur)
    print(f"세그먼트 {len([k for k in keys])}개 기준")
    print(f"GT {n_ref_tot} / EST {n_est_tot} / 누락(ref無짝) {n_miss_tot} "
          f"({100*n_miss_tot/max(n_ref_tot,1):.1f}%) / 잉여(est無짝) {n_extra_tot}")
    print(f"누락 노트 길이: median {np.median(md)*1000:.0f}ms  mean {md.mean()*1000:.0f}ms")
    print(f"유지 노트 길이: median {np.median(kd)*1000:.0f}ms  mean {kd.mean()*1000:.0f}ms")
    print(f"누락 중 '이전과 같은 음(반복)' 비율: {100*miss_same/max(miss_total,1):.1f}%")
    if miss_gap:
        mg = np.array(miss_gap)
        print(f"누락 노트의 직전 간격(IOI): median {np.median(mg)*1000:.0f}ms")
    # 짧은 노트 분포
    for thr in [0.1, 0.15, 0.2, 0.3]:
        print(f"  누락 중 길이<{thr*1000:.0f}ms 비율: {100*np.mean(md<thr):.0f}%  "
              f"(유지: {100*np.mean(kd<thr):.0f}%)")


if __name__ == "__main__":
    main()
