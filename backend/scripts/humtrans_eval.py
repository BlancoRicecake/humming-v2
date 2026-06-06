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
# 시퀀스 정렬 기반 지표 (GT가 양자화된 악보 타이밍이므로 절대-onset 매칭 대신
# 노트열을 순서 정렬한 뒤 피치/리듬을 평가)
# ---------------------------------------------------------------------------
@dataclass
class SegResult:
    key: str
    n_ref: int
    n_est: int
    note_count_acc: float     # 1 - |est-ref|/ref
    pitch_acc: float          # 정렬쌍 중 정확 반음(≤0.5) 비율, 옥타브 정합
    timing_acc: float         # 연속 정렬쌍 IOI 비율(템포 정규화) 1.5배 이내 비율
    melody_acc: float         # 피치+리듬 동시 정답 / n_ref (종합)
    align_coverage: float     # 정렬쌍 / n_ref (recall)
    onset_resid_mae_ms: float # affine 정합 후 onset 잔차(루바토 진단)
    best_octave: int
    # 공식 mir_eval (참고용, 절대-onset → 항상 낮음)
    f1: float
    precision: float
    recall: float


def _match_at(ref_int, ref_pit_hz, est_int, est_pit_hz, pitch_tol_cents):
    """mir_eval.match_notes 래퍼 → 매칭 인덱스쌍 리스트 (공식 F1 계산용)."""
    if len(ref_int) == 0 or len(est_int) == 0:
        return []
    return mir_eval.transcription.match_notes(
        ref_int, ref_pit_hz, est_int, est_pit_hz,
        onset_tolerance=ONSET_TOL,
        pitch_tolerance=pitch_tol_cents,
        offset_ratio=None,
    )


def _nw_align(rp, ep, ref_pit, est_pit, o, gap, lam):
    """정규화 위치(rp,ep) + 가벼운 피치항으로 순서보존(NW) 정렬. 옥타브 o 고정.
    반환 (pairs, total_cost)."""
    n, m = len(rp), len(ep)
    INF = 1e9
    D = np.full((n + 1, m + 1), INF)
    bt = np.zeros((n + 1, m + 1), dtype=np.int8)  # 0 diag,1 up(del ref),2 left(ins est)
    D[0, 0] = 0.0
    for i in range(1, n + 1):
        D[i, 0] = i * gap; bt[i, 0] = 1
    for j in range(1, m + 1):
        D[0, j] = j * gap; bt[0, j] = 2
    for i in range(1, n + 1):
        for j in range(1, m + 1):
            # 위치 거리 + 피치 패널티(반음차/12, 최대 1). lam 작게 → 위치 우세,
            # 피치는 같은 위치의 후보 중 올바른 대응을 고르는 타이브레이커.
            pp = min(abs(ref_pit[i - 1] + 12 * o - est_pit[j - 1]), 12.0) / 12.0
            diag = D[i - 1, j - 1] + abs(rp[i - 1] - ep[j - 1]) + lam * pp
            up = D[i - 1, j] + gap
            left = D[i, j - 1] + gap
            if diag <= up and diag <= left:
                D[i, j], bt[i, j] = diag, 0
            elif up <= left:
                D[i, j], bt[i, j] = up, 1
            else:
                D[i, j], bt[i, j] = left, 2
    pairs = []
    i, j = n, m
    while i > 0 or j > 0:
        b = bt[i, j]
        if b == 0:
            pairs.append((i - 1, j - 1)); i -= 1; j -= 1
        elif b == 1:
            i -= 1
        else:
            j -= 1
    pairs.reverse()
    return pairs, float(D[n, m])


def align_sequences(ref_on, est_on, ref_pit, est_pit, gap=0.10, lam=0.05):
    """노트열 순서 정렬 + 옥타브 합동 선택.

    GT가 양자화 격자라 절대-onset 매칭은 무의미. 세그먼트 내 상대 위치(0~1)로
    정규화한 뒤 순서를 보존하며 전역 정렬한다. 위치가 지배하고 가벼운 피치항
    (lam)이 '어느 ref에 대응되는지'만 골라준다 → 분절/누락 오류가 피치 오류로
    잘못 귀속되지 않게 함(대응은 음악적으로 맞추되, 대응된 쌍의 피치오류는 그대로
    카운트). 옥타브는 정렬 총비용 최소로 선택. 반환 (pairs, best_octave)."""
    n, m = len(ref_on), len(est_on)
    if n == 0 or m == 0:
        return [], 0

    def norm(on):
        span = on[-1] - on[0]
        return (on - on[0]) / span if span > 1e-9 else np.zeros(len(on))

    rp, ep = norm(ref_on), norm(est_on)
    best = None  # (cost, o, pairs)
    for o in range(-OCTAVE_RADIUS, OCTAVE_RADIUS + 1):
        pairs, cost = _nw_align(rp, ep, ref_pit, est_pit, o, gap, lam)
        if best is None or cost < best[0]:
            best = (cost, o, pairs)
    return best[2], best[1]


def estimate_grid_base(onsets):
    """GT onset 들의 격자 단위(초) 추정. HumTrans GT 는 양자화되어 onset 들이
    어떤 base 의 정수배. 굵은→가는 base 를 훑어, onset 들이 격자에 잘 맞는
    '가장 큰' base 를 채택(작은 base 는 항상 맞으므로 큰 쪽 우선). 삼잇단음 등
    혼합으로 단일 격자가 없으면 최소 IOI 로 폴백."""
    if len(onsets) < 2:
        return None
    offs = np.asarray(onsets) - onsets[0]
    b = 0.50
    while b >= 0.08:
        frac = offs / b
        resid = np.abs(frac - np.round(frac))
        if resid.mean() < 0.06 and np.percentile(resid, 90) < 0.12:
            return float(b)
        b -= 0.005
    d = np.diff(np.sort(onsets)); d = d[d > 0.03]
    return float(np.min(d)) if d.size else None


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

    # 공식 note-F1 (참고용) — 절대 onset, 옥타브 불변
    est_hz = _hz(est_pit)
    ref_int = _intervals(ref_on, ref_off)
    est_int = _intervals(est_on, est_off)
    bestf1 = (0.0, 0.0, 0.0)
    if n_est:
        for o in range(-OCTAVE_RADIUS, OCTAVE_RADIUS + 1):
            p, r, f1, _ = mir_eval.transcription.precision_recall_f1_overlap(
                ref_int, _hz(ref_pit + 12 * o), est_int, est_hz,
                onset_tolerance=ONSET_TOL, pitch_tolerance=1.0, offset_ratio=None,
            )
            if f1 > bestf1[2]:
                bestf1 = (p, r, f1)

    if n_est == 0:
        return SegResult(key, n_ref, 0, note_count_acc, 0.0, 0.0, 0.0, 0.0,
                         0.0, 0, bestf1[2], bestf1[0], bestf1[1])

    # --- 순서 정렬 (위치 + 가벼운 피치항, 옥타브 합동 선택) ---
    pairs, best_o = align_sequences(ref_on, est_on, ref_pit, est_pit)
    n_pair = len(pairs)
    align_coverage = n_pair / n_ref
    if n_pair == 0:
        return SegResult(key, n_ref, n_est, note_count_acc, 0.0, 0.0, 0.0, 0.0,
                         0.0, 0, bestf1[2], bestf1[0], bestf1[1])

    # --- 피치 정확도 (정렬쌍 기준, 옥타브 정합) ---
    pitch_ok = np.array([abs(ref_pit[ri] + 12 * best_o - est_pit[ej]) <= 0.5
                         for ri, ej in pairs])
    pitch_acc = float(pitch_ok.mean())

    # --- 타이밍=리듬: 격자 양자화 비교 ---
    # GT 격자 base 를 구하고, 연속 정렬쌍의 IOI 를 (템포 정규화 후) 격자 스텝
    # 정수로 반올림 → ref 의 격자 스텝과 일치하면 정답. "노트가 올바른 박자
    # 칸에 들어갔나"를 재며 ±½격자(루바토)를 흡수.
    rio = np.array([ref_on[pairs[k + 1][0]] - ref_on[pairs[k][0]]
                    for k in range(n_pair - 1)])
    eio = np.array([est_on[pairs[k + 1][1]] - est_on[pairs[k][1]]
                    for k in range(n_pair - 1)])
    valid = (rio > 1e-3) & (eio > 1e-3)
    rhythm_ok = np.zeros(n_pair - 1, dtype=bool)
    base = estimate_grid_base(ref_on)
    if valid.sum() > 0 and base:
        scale = float(np.sum(eio[valid]) / np.sum(rio[valid]))  # 전역 템포 비
        ref_steps = np.round(rio / base)
        est_steps = np.round((eio / max(scale, 1e-9)) / base)
        rhythm_ok = valid & (ref_steps >= 1) & (est_steps == ref_steps)
    elif valid.sum() > 0:
        # 격자 추정 실패 시 ±50% 비율 폴백
        scale = float(np.sum(eio[valid]) / np.sum(rio[valid]))
        ratio = np.where(valid, (eio / max(scale, 1e-9)) / rio, 0.0)
        rhythm_ok = valid & (ratio >= 1 / 1.5) & (ratio <= 1.5)
    timing_acc = float(rhythm_ok.sum() / max(valid.sum(), 1))

    # --- onset 잔차(affine 정합 후) — 루바토/지터 진단용 ---
    X = np.array([est_on[ej] for _, ej in pairs])
    Y = np.array([ref_on[ri] for ri, _ in pairs])
    if n_pair >= 2 and X.std() > 1e-6:
        a, b = np.polyfit(X, Y, 1)
    else:
        a, b = 1.0, float(Y.mean() - X.mean())
    resid = Y - (a * X + b)
    onset_resid_mae_ms = float(np.mean(np.abs(resid)) * 1000.0)

    # --- 종합: 피치 정답 AND 리듬 정답 / n_ref ---
    # 리듬 정답을 노트 단위로 환산: k번째와 k+1번째 쌍을 잇는 IOI가 맞으면
    # 양 끝 노트에 부분 크레딧. 간단히 '피치 맞고 IOI 양옆 중 1개 이상 맞음'.
    rhythm_note = np.zeros(n_pair, dtype=bool)
    for k in range(n_pair - 1):
        if rhythm_ok[k]:
            rhythm_note[k] = True
            rhythm_note[k + 1] = True
    if n_pair == 1:
        rhythm_note[0] = True
    melody_acc = float(np.sum(pitch_ok & rhythm_note) / n_ref)

    return SegResult(
        key, n_ref, n_est, note_count_acc, pitch_acc, timing_acc, melody_acc,
        align_coverage, onset_resid_mae_ms, best_o,
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
    ap.add_argument("--keysfile", default=None, help="평가 키 목록 파일(있으면 split 무시)")
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

    if args.keysfile:
        keys = [l.strip() for l in open(args.keysfile) if l.strip()]
        if args.limit:
            keys = keys[:args.limit]
    else:
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

    summary = {
        "tag": args.tag,
        "split": args.split,
        "pitch": args.pitch,
        "opts": opts_over,
        "n_eval": len(results),
        "n_skipped": len(skipped),
        "axis": {
            "note_count_acc": round(float(arr("note_count_acc").mean()), 4),
            "pitch_acc": round(float(arr("pitch_acc").mean()), 4),
            "timing_acc": round(float(arr("timing_acc").mean()), 4),   # 리듬(IOI)
            "melody_acc": round(float(arr("melody_acc").mean()), 4),   # 피치+리듬 종합
        },
        "diag": {
            "align_coverage": round(float(arr("align_coverage").mean()), 4),
            "onset_resid_mae_ms": round(float(arr("onset_resid_mae_ms").mean()), 2),
        },
        "official": {
            "note_f1": round(float(arr("f1").mean()), 4),
            "precision": round(float(arr("precision").mean()), 4),
            "recall": round(float(arr("recall").mean()), 4),
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
                        "timing_acc", "melody_acc", "align_coverage",
                        "onset_resid_mae_ms", "best_octave",
                        "f1", "precision", "recall"])
            for r in results:
                w.writerow([r.key, r.n_ref, r.n_est, f"{r.note_count_acc:.4f}",
                            f"{r.pitch_acc:.4f}", f"{r.timing_acc:.4f}",
                            f"{r.melody_acc:.4f}", f"{r.align_coverage:.4f}",
                            f"{r.onset_resid_mae_ms:.2f}", r.best_octave,
                            f"{r.f1:.4f}", f"{r.precision:.4f}", f"{r.recall:.4f}"])
        print(f"\n세그먼트별 CSV → {args.out}", file=sys.stderr)


if __name__ == "__main__":
    main()
