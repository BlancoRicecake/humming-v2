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
    ref_notes_from_midi, est_notes_from_response, estimate_offset,
    _intervals, _hz, _match_at, OCTAVE_RADIUS,
)


def best_octave(ref_pit, ref_int, est_int, est_pit):
    est_hz = _hz(est_pit)
    best = (-1, 0)
    for o in range(-OCTAVE_RADIUS, OCTAVE_RADIUS + 1):
        m = _match_at(ref_int, _hz(ref_pit + 12 * o), est_int, est_hz, 100.0)
        if len(m) > best[0]:
            best = (len(m), o)
    return best[1]


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

    ref_int = _intervals(ref_on, ref_off)
    delta = estimate_offset(ref_on, est_on)
    # 옥타브는 반드시 오프셋 보정 후 인터벌로 선택 (보정 전엔 onset 불일치로
    # 매칭이 0 → 옥타브가 의미 없는 기본값으로 떨어진다)
    est_int_aln = _intervals(est_on + delta, est_off + delta)
    o = best_octave(ref_pit, ref_int, est_int_aln, est_pit)
    ref_pit_s = ref_pit + 12 * o          # 옥타브 정합된 GT

    fig, axes = plt.subplots(3, 1, figsize=(14, 9), sharex=True)
    fig.suptitle(f"{key}   octave-shift={o:+d}   est_offset={delta*1000:+.0f}ms "
                 f"(GT n={len(ref_on)}, est n={len(est_on)})", fontsize=12)

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

    # (3) 피아노롤 (상수 오프셋 보정 후)
    ax = axes[2]
    draw_notes(ax, ref_on, ref_off, ref_pit_s, "#1f77b4", "GT")
    draw_notes(ax, est_on + delta, est_off + delta, est_pit, "#2ca02c",
               f"est (offset {delta*1000:+.0f}ms)")
    ax.set_ylim(allp.min() - 2, allp.max() + 2)
    ax.set_ylabel("MIDI pitch\n(offset-corrected)")
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
