"""pYIN vs CREPE A/B 비교 (standalone, 앱 불변, 읽기 전용).

각 샘플을 두 피치 백엔드로 analyze_audio 돌려 정확도 대용 지표를 나란히 덤프한다:

  1) pitched 노트 수
  2) 옥타브 에러: 시간상 겹치는 pyin/crepe 노트 쌍 중 |Δpitch| 가 12의 배수(±1반음)인 비율
  3) onset 평균 절대차(ms): 매칭된 노트 시작 시각 차
  4) confidence(voiced_prob) 평균/중앙값

통과 기준(플랜): pitched 수 동일 ±1, 옥타브 에러 미증가, onset 평균차 < 30ms.

사용:
    .\.venv\Scripts\python diag_crepe_ab.py                 # samples/ 전부
    .\.venv\Scripts\python diag_crepe_ab.py "1. 왈츠.wav"    # 하나만
"""
from __future__ import annotations

import sys
import warnings
import logging
from pathlib import Path

warnings.filterwarnings("ignore")
logging.disable(logging.WARNING)

import numpy as np
from app.analyze import analyze_audio
from app.schemas import AnalyzeOptions

PC = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
SAMPLES_DIR = Path(__file__).resolve().parent / "samples"


def _nm(m: int) -> str:
    return f"{PC[m % 12]}{m // 12 - 1}"


def _pitched(res):
    return [n for n in res.notes if n.kind == "pitched"]


def _match_pairs(a, b, tol=0.12):
    """Greedy match notes between two runs by nearest start time (≤ tol s)."""
    pairs = []
    used = set()
    for na in a:
        best, bd = None, tol
        for j, nb in enumerate(b):
            if j in used:
                continue
            d = abs(na.start - nb.start)
            if d <= bd:
                best, bd = j, d
        if best is not None:
            used.add(best)
            pairs.append((na, b[best]))
    return pairs


def compare(path: Path) -> None:
    raw = path.read_bytes()
    res_p = analyze_audio(raw, AnalyzeOptions(pitch_model="pyin"))
    res_c = analyze_audio(raw, AnalyzeOptions(pitch_model="crepe"))
    pp, cc = _pitched(res_p), _pitched(res_c)

    pairs = _match_pairs(pp, cc)
    if pairs:
        onset_ms = float(np.mean([abs(a.start - b.start) for a, b in pairs]) * 1000.0)
        oct_err = sum(
            1 for a, b in pairs
            if a.pitch != b.pitch and abs(a.pitch - b.pitch) % 12 == 0
        )
        oct_pct = 100.0 * oct_err / len(pairs)
        semitone_diffs = [abs(a.pitch - b.pitch) for a, b in pairs]
        mismatch = sum(1 for d in semitone_diffs if d != 0)
    else:
        onset_ms = oct_pct = mismatch = 0

    def conf_stats(res):
        c = np.array([n.confidence for n in _pitched(res)], dtype=float)
        return (float(np.mean(c)), float(np.median(c))) if c.size else (0.0, 0.0)

    pm, pmd = conf_stats(res_p)
    cm, cmd = conf_stats(res_c)

    keyp = f"{res_p.detected_key.tonic}{res_p.detected_key.scale}" if res_p.detected_key else "-"
    keyc = f"{res_c.detected_key.tonic}{res_c.detected_key.scale}" if res_c.detected_key else "-"

    print("=" * 78)
    print(f"{path.name}")
    print(f"  pitched notes : pyin={len(pp):3d}   crepe={len(cc):3d}   "
          f"(Δ={len(cc)-len(pp):+d})")
    print(f"  key           : pyin={keyp:<10s} crepe={keyc}")
    print(f"  matched pairs : {len(pairs)}  | mismatched pitch: {mismatch}  | "
          f"octave-jumps: {oct_pct:.0f}%")
    print(f"  onset mean Δ  : {onset_ms:.1f} ms")
    print(f"  confidence    : pyin mean={pm:.3f}/med={pmd:.3f}   "
          f"crepe mean={cm:.3f}/med={cmd:.3f}")
    print(f"  pyin  notes   : {[_nm(n.pitch) for n in pp]}")
    print(f"  crepe notes   : {[_nm(n.pitch) for n in cc]}")


def main():
    args = sys.argv[1:]
    paths = [SAMPLES_DIR / a for a in args] if args else sorted(SAMPLES_DIR.glob("*.wav"))
    for p in paths:
        if p.is_file():
            compare(p)
        else:
            print(f"(missing) {p}")


if __name__ == "__main__":
    main()
