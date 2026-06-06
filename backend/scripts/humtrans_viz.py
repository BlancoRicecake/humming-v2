#!/usr/bin/env python3
"""HumTrans 세그먼트 시각화 — 파형 + GT/추정 노트 타이밍 정렬 점검.

3단 플롯:
  (1) 파형 + GT onset(파랑) / 추정 onset(주황) 수직선
  (2) 피아노롤: GT 노트(파랑 막대) vs 추정 노트(주황 막대) — 옥타브 정합 적용
  (3) 상수 오프셋 보정 후 피아노롤 (잔차 타이밍 확인)

사용:
  python scripts/humtrans_viz.py F01_0024_0001_1 F01_0036_0001_1
  python scripts/humtrans_viz.py --split test --n 4   # 앞 n개 자동
"""
from __future__ import annotations
import argparse
import os
import sys

import numpy as np
import soundfile as sf
import pretty_midi
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
from matplotlib.patches import Rectangle  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
BACKEND = os.path.dirname(HERE)
DATA = os.path.join(BACKEND, ".eval_data")
sys.path.insert(0, BACKEND)

from app.analyze import analyze_audio  # noqa: E402
from app.schemas import AnalyzeOptions  # noqa: E402
from scripts.humtrans_eval import (  # noqa: E402
    ref_notes_from_midi, est_notes_from_response, align_sequences,
)


def draw_notes(ax, on, off, pit, color, label, alpha=0.6):
    for i, (s, e, p) in enumerate(zip(on, off, pit)):
        ax.add_patch(Rectangle((s, p - 0.4), max(e - s, 0.02), 0.8,
                               color=color, alpha=alpha,
                               label=label if i == 0 else None))


def viz_segment(key, split, opts, outdir):
    wav = os.path.join(DATA, "wav", key + ".wav")
    gt = os.path.join(DATA, "HumTrans-main", "midis", "gt", "GroundTruth",
                      split, key + ".mid")
    if not (os.path.exists(wav) and os.path.exists(gt)):
        print(f"  스킵 {key}: 파일 없음", file=sys.stderr)
        return None

    y, sr = sf.read(wav)
    if y.ndim > 1:
        y = y.mean(1)
    y = y.astype(np.float32)
    t = np.arange(len(y)) / sr

    resp = analyze_audio(open(wav, "rb").read(), opts)
    ref_on, ref_off, ref_pit = ref_notes_from_midi(gt)
    est_on, est_off, est_pit = est_notes_from_response(resp, "final")

    # 순서 정렬(위치+피치, 옥타브 합동) → affine 시간 매핑(est→ref 타임라인)
    pairs, o = align_sequences(ref_on, est_on, ref_pit, est_pit)
    ref_pit_s = ref_pit + 12 * o          # 옥타브 정합된 GT
    if len(pairs) >= 2:
        X = np.array([est_on[j] for _, j in pairs])
        Y = np.array([ref_on[i] for i, _ in pairs])
        a, b = np.polyfit(X, Y, 1) if X.std() > 1e-6 else (1.0, Y.mean() - X.mean())
    else:
        a, b = 1.0, 0.0
    est_on_map = a * est_on + b           # ref 타임라인으로 워프된 est onset
    est_off_map = a * est_off + b

    fig, axes = plt.subplots(3, 1, figsize=(14, 9), sharex=True)
    fig.suptitle(f"{key}   octave-shift={o:+d}   tempo×{a:.2f}  "
                 f"({len(pairs)} aligned / GT n={len(ref_on)}, est n={len(est_on)})",
                 fontsize=12)

    # (1) 파형 + onset
    ax = axes[0]
    ax.plot(t, y, lw=0.4, color="#888")
    for x in ref_on:
        ax.axvline(x, color="#1f77b4", lw=0.8, alpha=0.7)
    for x in est_on:
        ax.axvline(x, color="#ff7f0e", lw=0.8, alpha=0.7, ls="--")
    ax.set_ylabel("waveform")
    ax.legend(handles=[
        plt.Line2D([], [], color="#1f77b4", label="GT onset"),
        plt.Line2D([], [], color="#ff7f0e", ls="--", label="est onset"),
    ], loc="upper right", fontsize=8)

    # (2) 피아노롤 (보정 전)
    ax = axes[1]
    draw_notes(ax, ref_on, ref_off, ref_pit_s, "#1f77b4", "GT (octave-aligned)")
    draw_notes(ax, est_on, est_off, est_pit, "#ff7f0e", "est")
    allp = np.concatenate([ref_pit_s, est_pit]) if len(est_pit) else ref_pit_s
    ax.set_ylim(allp.min() - 2, allp.max() + 2)
    ax.set_ylabel("MIDI pitch\n(raw timing)")
    ax.legend(loc="upper right", fontsize=8)

    # (3) 피아노롤 (순서정렬 + affine 템포 매핑으로 ref 타임라인에 워프)
    ax = axes[2]
    draw_notes(ax, ref_on, ref_off, ref_pit_s, "#1f77b4", "GT")
    draw_notes(ax, est_on_map, est_off_map, est_pit, "#2ca02c",
               f"est → ref timeline (tempo×{a:.2f})")
    # 정렬쌍 연결선
    for ri, ej in pairs:
        ax.plot([ref_on[ri], est_on_map[ej]],
                [ref_pit_s[ri], est_pit[ej]], color="#999", lw=0.4, alpha=0.5)
    ax.set_ylim(allp.min() - 2, allp.max() + 2)
    ax.set_ylabel("MIDI pitch\n(seq-aligned)")
    ax.set_xlabel("time (s)")
    ax.legend(loc="upper right", fontsize=8)

    fig.tight_layout(rect=[0, 0, 1, 0.97])
    out = os.path.join(outdir, f"{key}.png")
    fig.savefig(out, dpi=110)
    plt.close(fig)
    print(f"  → {out}")
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("keys", nargs="*", help="세그먼트 키 (없으면 --n 으로 자동)")
    ap.add_argument("--split", default="test")
    ap.add_argument("--n", type=int, default=4)
    ap.add_argument("--opts", default="{}")
    ap.add_argument("--outdir", default=os.path.join(DATA, "viz"))
    args = ap.parse_args()
    import json
    opts = AnalyzeOptions(**json.loads(args.opts))
    os.makedirs(args.outdir, exist_ok=True)

    keys = args.keys
    if not keys:
        kf = os.path.join(DATA, "HumTrans-main", f"{args.split}_keys.txt")
        keys = [l.strip() for l in open(kf) if l.strip()][:args.n]

    outs = []
    for k in keys:
        r = viz_segment(k, args.split, opts, args.outdir)
        if r:
            outs.append(r)
    print(f"\n{len(outs)}개 생성 → {args.outdir}")


if __name__ == "__main__":
    main()
