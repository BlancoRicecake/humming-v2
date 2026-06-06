#!/usr/bin/env python3
"""분절기 파라미터 A/B — 메인 코드 불변(monkeypatch)로 누락/과소분절 개선 탐색.

내부 분절 상수( app.analyze 네임스페이스에 import 된 값/함수 )를 런타임에만
교체해 평가한다. 채택된 값만 나중에 메인에 반영.

패치 가능 키(--patch JSON):
  subdiv_min        : SUBDIVISION_MIN_CHUNK_DUR_SEC (기본 0.30)
  pitch_min_change  : split_chunk_by_pitch.min_change_semitones (1.0)
  pitch_min_hold    : .min_hold_sec (0.12)
  pitch_min_gap     : .min_split_gap_sec (0.10)
  dip_ratio         : split_chunk_by_rms_dip.dip_ratio (0.40)
  dip_min_sub       : .min_sub_chunk_sec (0.12)
또한 --opts 로 AnalyzeOptions 오버라이드 가능.

사용:
  python scripts/humtrans_ab.py --limit 60 --tag base
  python scripts/humtrans_ab.py --limit 60 --tag subdiv20 \
      --patch '{"subdiv_min":0.20,"pitch_min_hold":0.08,"pitch_min_gap":0.07}'
"""
from __future__ import annotations
import argparse
import json
import os
import sys
from functools import partial

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
BACKEND = os.path.dirname(HERE)
DATA = os.path.join(BACKEND, ".eval_data")
sys.path.insert(0, BACKEND)

import app.analyze as A  # noqa: E402
from app.schemas import AnalyzeOptions  # noqa: E402
from scripts.humtrans_eval import (  # noqa: E402
    ref_notes_from_midi, est_notes_from_response, evaluate_segment, load_keys,
)

_ORIG_PITCH = A.split_chunk_by_pitch
_ORIG_DIP = A.split_chunk_by_rms_dip
_ORIG_SUBDIV = A.SUBDIVISION_MIN_CHUNK_DUR_SEC


def apply_patch(p: dict):
    A.SUBDIVISION_MIN_CHUNK_DUR_SEC = p.get("subdiv_min", _ORIG_SUBDIV)
    pk = {}
    if "pitch_min_change" in p: pk["min_change_semitones"] = p["pitch_min_change"]
    if "pitch_min_hold" in p:   pk["min_hold_sec"] = p["pitch_min_hold"]
    if "pitch_min_gap" in p:    pk["min_split_gap_sec"] = p["pitch_min_gap"]
    A.split_chunk_by_pitch = partial(_ORIG_PITCH, **pk) if pk else _ORIG_PITCH
    dk = {}
    if "dip_ratio" in p:   dk["dip_ratio"] = p["dip_ratio"]
    if "dip_min_sub" in p: dk["min_sub_chunk_sec"] = p["dip_min_sub"]
    A.split_chunk_by_rms_dip = partial(_ORIG_DIP, **dk) if dk else _ORIG_DIP


def run(keys, opts, gtdir):
    res = []
    for key in keys:
        wav = os.path.join(DATA, "wav", key + ".wav")
        gt = os.path.join(gtdir, key + ".mid")
        if not (os.path.exists(wav) and os.path.exists(gt)):
            continue
        try:
            resp = A.analyze_audio(open(wav, "rb").read(), opts)
        except Exception as e:  # noqa: BLE001
            print(f"  !! {key}: {e}", file=sys.stderr); continue
        ref = ref_notes_from_midi(gt)
        est = est_notes_from_response(resp, "final")
        res.append(evaluate_segment(key, ref, est))
    return res


def summarize(res):
    g = lambda f: float(np.mean([getattr(r, f) for r in res]))
    return {
        "n": len(res),
        "note_count": round(g("note_count_acc"), 4),
        "timing": round(g("timing_acc"), 4),
        "pitch": round(g("pitch_acc"), 4),
        "melody": round(g("melody_acc"), 4),
        "coverage": round(g("align_coverage"), 4),
        "est_mean": round(float(np.mean([r.n_est for r in res])), 1),
        "ref_mean": round(float(np.mean([r.n_ref for r in res])), 1),
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--split", default="test")
    ap.add_argument("--limit", type=int, default=60)
    ap.add_argument("--keysfile", default=None, help="평가 키 목록 파일")
    ap.add_argument("--patch", default="{}")
    ap.add_argument("--opts", default="{}")
    ap.add_argument("--tag", default="ab")
    args = ap.parse_args()
    gtdir = os.path.join(DATA, "HumTrans-main", "midis", "gt", "GroundTruth", args.split)
    if args.keysfile:
        keys = [l.strip() for l in open(args.keysfile) if l.strip()]
        if args.limit:
            keys = keys[:args.limit]
    else:
        keys = load_keys(args.split, args.limit)
    opts = AnalyzeOptions(**json.loads(args.opts))

    apply_patch(json.loads(args.patch))
    res = run(keys, opts, gtdir)
    out = {"tag": args.tag, "patch": json.loads(args.patch),
           "opts": json.loads(args.opts), **summarize(res)}
    print(json.dumps(out, ensure_ascii=False))


if __name__ == "__main__":
    main()
