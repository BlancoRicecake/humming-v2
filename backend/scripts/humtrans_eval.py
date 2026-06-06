#!/usr/bin/env python3
"""HumTrans 정확도 평가 하니스 (메인 앱 불변, 평가 전용).

각 세그먼트에 대해:
  wav → analyze_audio() → est 노트  vs  GT MIDI(ref) 노트
공식 metric(calc_transcription_eval_metric.py)과 동일한 매칭 규칙을 재사용한다:
  - onset_tolerance = 0.05s
  - 옥타브 불변: ref 피치를 -16..+16 옥타브 시프트하며 best 매칭 선택
  - offset 무시 (offset_ratio=None)
  - trim: est 노트를 ref 첫/마지막 onset 구간으로 자른 뒤 비교

리포트 지표:
  1) 노트 수 정확도   = max(0, 1 - |est-ref|/ref)
  2) 피치 정확도      = 매칭쌍 중 |Δpitch| ≤ 0.5반음(=정확한 반음) 비율
  3) 타이밍 정확도    = 매칭쌍 수 / ref 노트 수 (onset recall) + 평균 절대 onset 편차
  4) 공식 note-F1     = mir_eval P/R/F1 (참고용, 엄격 결합)

매칭 pitch_tolerance: 축별 지표는 1.0반음(100 cents)으로 느슨하게 매칭한 뒤
피치 축에서 0.5반음으로 평가. 공식 F1은 1 cent(=정확 반음)로 따로 계산.

사용:
  python scripts/humtrans_eval.py --split test --limit 100
  python scripts/humtrans_eval.py --split test --limit 100 --pitch raw \
      --opts '{"pitch_assistant": false}' --tag no_assist
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
from dataclasses import dataclass, field
from typing import Optional

import numpy as np
import pretty_midi
import mir_eval

HERE = os.path.dirname(os.path.abspath(__file__))
BACKEND = os.path.dirname(HERE)
DATA = os.path.join(BACKEND, ".eval_data")
sys.path.insert(0, BACKEND)

from app.analyze import analyze_audio  # noqa: E402
from app.schemas import AnalyzeOptions  # noqa: E402

ONSET_TOL = 0.05
OCTAVE_RADIUS = 16


# ---------------------------------------------------------------------------
# 노트 추출
# ---------------------------------------------------------------------------
def ref_notes_from_midi(path: str):
    """(onsets, offsets, pitches) — 드럼 제외, onset 정렬."""
    pm = pretty_midi.PrettyMIDI(path)
    notes = [n for inst in pm.instruments if not inst.is_drum for n in inst.notes]
    notes.sort(key=lambda n: n.start)
    onsets = np.array([n.start for n in notes], dtype=np.float64)
    offsets = np.array([n.end for n in notes], dtype=np.float64)
    pitches = np.array([n.pitch for n in notes], dtype=np.float64)
    return onsets, offsets, pitches


def est_notes_from_response(resp, pitch_field: str):
    """analyze_audio 응답 → (onsets, offsets, pitches).

    pitch_field='final' → 어시스턴트 적용 후 정수 pitch
    pitch_field='raw'   → 트래커 원본 round(pitch_raw)
    """
    on, off, pit = [], [], []
    for n in resp.notes:
        s = float(n.start)
        e = float(n.end)
        if e <= s:
            e = s + 1e-3
        if pitch_field == "raw":
            p = round(float(n.pitch_raw)) if np.isfinite(n.pitch_raw) else float(n.pitch)
        else:
            p = float(n.pitch)
        on.append(s)
        off.append(e)
        pit.append(float(p))
    order = np.argsort(on) if on else np.array([], dtype=int)
    on = np.array(on, dtype=np.float64)[order] if on else np.zeros(0)
    off = np.array(off, dtype=np.float64)[order] if off else np.zeros(0)
    pit = np.array(pit, dtype=np.float64)[order] if pit else np.zeros(0)
    return on, off, pit


def _intervals(onsets, offsets):
    if len(onsets) == 0:
        return np.zeros((0, 2), dtype=np.float64)
    return np.stack([onsets, offsets], axis=1).astype(np.float64)


def _hz(midi: np.ndarray) -> np.ndarray:
    return 440.0 * np.power(2.0, (midi - 69.0) / 12.0)


# ---------------------------------------------------------------------------
# 매칭 (옥타브 불변)
# ---------------------------------------------------------------------------
@dataclass
class SegResult:
    key: str
    n_ref: int
    n_est: int
    note_count_acc: float
    pitch_acc: float          # 매칭쌍 중 정확 반음 비율 (≤0.5반음)
    timing_acc_raw: float     # 오프셋 보정 전 매칭 / ref
    timing_acc: float         # 세그먼트 상수 오프셋 제거 후 매칭 / ref
    onset_mae_ms: float       # 매칭쌍 평균 절대 onset 편차(보정 후)
    offset_ms: float          # 추정한 wav↔midi 상수 오프셋 (ref-est, +면 est가 빠름)
    best_octave: int
    # 공식 mir_eval (오프셋 보정 전 = 데이터셋 그대로)
    f1: float
    precision: float
    recall: float


def _match_at(ref_int, ref_pit_hz, est_int, est_pit_hz, pitch_tol_cents):
    """mir_eval.match_notes 래퍼 → 매칭 인덱스쌍 리스트."""
    if len(ref_int) == 0 or len(est_int) == 0:
        return []
    return mir_eval.transcription.match_notes(
        ref_int, ref_pit_hz, est_int, est_pit_hz,
        onset_tolerance=ONSET_TOL,
        pitch_tolerance=pitch_tol_cents,
        offset_ratio=None,
    )


def estimate_offset(ref_on, est_on, band=0.30, bin_w=0.01):
    """피치-블라인드 상수 오프셋 δ 추정 (쌍별 delta 투표).

    HumTrans wav↔midi 는 녹음별 상수 레이턴시(실측 ±0.25s)를 가진다. 모든
    (ref_i - est_j) 쌍 delta 를 |δ|≤band 범위에서 모아 10ms 빈 히스토그램의
    최빈값을 잡으면, 누락/추가 노트가 있어도 '진짜' 상수 오프셋이 최다 득표로
    드러난다(그리디 매칭보다 견고 — 경계 스퓨리어스에 빠지지 않음). 5ms 단위로
    국소 가중평균 보정. 반환 δ: est_on + δ 가 ref_on 에 정렬되는 값."""
    if len(ref_on) == 0 or len(est_on) == 0:
        return 0.0
    deltas = (ref_on[:, None] - est_on[None, :]).ravel()
    deltas = deltas[np.abs(deltas) <= band]
    if deltas.size == 0:
        return 0.0
    edges = np.arange(-band, band + bin_w, bin_w)
    hist, _ = np.histogram(deltas, bins=edges)
    # 3-탭 평활 후 최빈 빈
    sm = np.convolve(hist, np.array([1.0, 2.0, 1.0]), mode="same")
    k = int(np.argmax(sm))
    center = 0.5 * (edges[k] + edges[k + 1])
    # 최빈 빈 ±15ms 내 delta 들의 가중평균으로 미세 보정
    near = deltas[np.abs(deltas - center) <= 0.015]
    return float(near.mean()) if near.size else float(center)


def evaluate_segment(key, ref, est) -> SegResult:
    ref_on, ref_off, ref_pit = ref
    est_on, est_off, est_pit = est
    n_ref = len(ref_on)
    n_est = len(est_on)

    if n_ref == 0:
        return SegResult(key, 0, n_est, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0,
                         0.0, 0.0, 0.0)

    # trim: est 를 ref onset 구간 [first, last] 로 자름 (공식과 동일)
    seg_start, seg_end = ref_on[0], ref_on[-1]
    if n_est:
        mask = (est_on >= seg_start) & (est_on <= seg_end)
        est_on, est_off, est_pit = est_on[mask], est_off[mask], est_pit[mask]
        n_est = len(est_on)

    note_count_acc = max(0.0, 1.0 - abs(n_est - n_ref) / n_ref)

    if n_est == 0:
        return SegResult(key, n_ref, 0, note_count_acc, 0.0, 0.0, 0.0, 0.0,
                         0.0, 0, 0.0, 0.0, 0.0)

    # 세그먼트 상수 오프셋 추정(피치-블라인드) → est 시간축 보정
    delta = estimate_offset(ref_on, est_on)
    est_on_aln = est_on + delta

    ref_int = _intervals(ref_on, ref_off)
    est_int_raw = _intervals(est_on, est_off)
    est_int_aln = _intervals(est_on_aln, est_off + delta)
    est_hz = _hz(est_pit)

    def best_octave_match(eint):
        best = None  # (n_match, o, matching, ref_pit_shift)
        for o in range(-OCTAVE_RADIUS, OCTAVE_RADIUS + 1):
            ref_pit_s = ref_pit + 12 * o
            matching = _match_at(ref_int, _hz(ref_pit_s), eint, est_hz, 100.0)
            if best is None or len(matching) > best[0]:
                best = (len(matching), o, matching, ref_pit_s)
        return best

    # 보정 전/후 onset recall (피치 1반음 허용 매칭)
    raw_match = best_octave_match(est_int_raw)
    aln_n, best_o, matching, ref_pit_s = best_octave_match(est_int_aln)
    timing_acc_raw = raw_match[0] / n_ref
    timing_acc = aln_n / n_ref

    # 피치 정확도: 보정 후 매칭쌍 중 |Δpitch| ≤ 0.5반음
    pitch_ok = 0
    onset_abs = []
    for ri, ei in matching:
        if abs(ref_pit_s[ri] - est_pit[ei]) <= 0.5:
            pitch_ok += 1
        onset_abs.append(abs(ref_on[ri] - est_on_aln[ei]))
    pitch_acc = pitch_ok / aln_n if aln_n else 0.0
    onset_mae_ms = float(np.mean(onset_abs) * 1000.0) if onset_abs else 0.0

    # --- 공식 note-F1 (octave-invariant, pitch_tol=1 cent, 오프셋 보정 X) ---
    bestf1 = (0.0, 0.0, 0.0)
    for o in range(-OCTAVE_RADIUS, OCTAVE_RADIUS + 1):
        ref_hz = _hz(ref_pit + 12 * o)
        p, r, f1, _ = mir_eval.transcription.precision_recall_f1_overlap(
            ref_int, ref_hz, est_int_raw, est_hz,
            onset_tolerance=ONSET_TOL, pitch_tolerance=1.0, offset_ratio=None,
        )
        if f1 > bestf1[2]:
            bestf1 = (p, r, f1)

    return SegResult(
        key, n_ref, n_est, note_count_acc, pitch_acc, timing_acc_raw,
        timing_acc, onset_mae_ms, delta * 1000.0, best_o,
        bestf1[2], bestf1[0], bestf1[1],
    )


# ---------------------------------------------------------------------------
# 러너
# ---------------------------------------------------------------------------
def load_keys(split: str, limit: Optional[int]):
    fn = os.path.join(DATA, "HumTrans-main", f"{split}_keys.txt")
    keys = [l.strip() for l in open(fn) if l.strip()]
    if limit:
        keys = keys[:limit]
    return keys


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--split", default="test", choices=["test", "valid"])
    ap.add_argument("--limit", type=int, default=100)
    ap.add_argument("--wavdir", default=os.path.join(DATA, "wav"))
    ap.add_argument("--gtdir", default=None)
    ap.add_argument("--pitch", default="final", choices=["final", "raw"])
    ap.add_argument("--opts", default="{}", help="AnalyzeOptions override JSON")
    ap.add_argument("--tag", default="baseline")
    ap.add_argument("--out", default=None, help="세그먼트별 CSV 경로")
    args = ap.parse_args()

    gtdir = args.gtdir or os.path.join(
        DATA, "HumTrans-main", "midis", "gt", "GroundTruth", args.split)
    opts_over = json.loads(args.opts)
    opts = AnalyzeOptions(**opts_over)

    keys = load_keys(args.split, args.limit)
    results = []
    skipped = []
    t0 = time.time()
    for i, key in enumerate(keys):
        wav = os.path.join(args.wavdir, key + ".wav")
        gt = os.path.join(gtdir, key + ".mid")
        if not os.path.exists(wav) or not os.path.exists(gt):
            skipped.append(key)
            continue
        try:
            resp = analyze_audio(open(wav, "rb").read(), opts)
        except Exception as e:  # noqa: BLE001
            print(f"  !! analyze 실패 {key}: {e}", file=sys.stderr)
            skipped.append(key)
            continue
        ref = ref_notes_from_midi(gt)
        est = est_notes_from_response(resp, args.pitch)
        results.append(evaluate_segment(key, ref, est))
        if (i + 1) % 20 == 0:
            print(f"  {i+1}/{len(keys)} ({time.time()-t0:.0f}s)", file=sys.stderr)

    if not results:
        print("평가 가능한 세그먼트 없음 (wav/gt 확인)", file=sys.stderr)
        sys.exit(1)

    arr = lambda f: np.array([getattr(r, f) for r in results], dtype=np.float64)
    nc = arr("note_count_acc")
    pa = arr("pitch_acc")
    ta = arr("timing_acc")
    tar = arr("timing_acc_raw")
    mae = arr("onset_mae_ms")
    off = arr("offset_ms")
    f1 = arr("f1")
    pr = arr("precision")
    rc = arr("recall")

    summary = {
        "tag": args.tag,
        "split": args.split,
        "pitch": args.pitch,
        "opts": opts_over,
        "n_eval": len(results),
        "n_skipped": len(skipped),
        "axis": {
            "note_count_acc": round(float(nc.mean()), 4),
            "pitch_acc": round(float(pa.mean()), 4),
            "timing_acc": round(float(ta.mean()), 4),          # 오프셋 보정 후
            "timing_acc_raw": round(float(tar.mean()), 4),     # 보정 전(데이터셋 오프셋 포함)
            "onset_mae_ms": round(float(mae.mean()), 2),
        },
        "offset_ms": {
            "median": round(float(np.median(off)), 1),
            "mean_abs": round(float(np.mean(np.abs(off))), 1),
            "p90_abs": round(float(np.percentile(np.abs(off), 90)), 1),
        },
        "official": {
            "note_f1": round(float(f1.mean()), 4),
            "precision": round(float(pr.mean()), 4),
            "recall": round(float(rc.mean()), 4),
        },
        "note_count": {
            "ref_mean": round(float(np.mean([r.n_ref for r in results])), 1),
            "est_mean": round(float(np.mean([r.n_est for r in results])), 1),
        },
    }
    print(json.dumps(summary, ensure_ascii=False, indent=2))

    if args.out:
        import csv
        with open(args.out, "w", newline="") as f:
            w = csv.writer(f)
            w.writerow(["key", "n_ref", "n_est", "note_count_acc", "pitch_acc",
                        "timing_acc", "timing_acc_raw", "onset_mae_ms",
                        "offset_ms", "best_octave", "f1", "precision", "recall"])
            for r in results:
                w.writerow([r.key, r.n_ref, r.n_est, f"{r.note_count_acc:.4f}",
                            f"{r.pitch_acc:.4f}", f"{r.timing_acc:.4f}",
                            f"{r.timing_acc_raw:.4f}", f"{r.onset_mae_ms:.2f}",
                            f"{r.offset_ms:.1f}", r.best_octave,
                            f"{r.f1:.4f}", f"{r.precision:.4f}", f"{r.recall:.4f}"])
        print(f"\n세그먼트별 CSV → {args.out}", file=sys.stderr)


if __name__ == "__main__":
    main()
