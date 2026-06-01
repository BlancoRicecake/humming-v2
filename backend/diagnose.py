"""Auto Key + Pitch Assistant 진단 덤프 (standalone).

메인 앱 불변. 각 샘플을 analyze_audio로 돌려 raw 노트를 얻은 뒤, /analyze와
동일한 run_key_and_assistant 경로로 키/어시스턴트를 재현하며 내부 신호를 덤프한다:

  - pitch-class 히스토그램(가중 후)
  - top-3 키 후보 + correlation + 1·2위 margin
  - pitched 수 / unique PC / 총 duration / 최종 confidence + tier
  - 노트별 raw float / in_key / 후보 / 후보 cost / 선택 / cents / source / suppressed_reason

사용:
    .\.venv\Scripts\python diagnose.py                # 5개 wav 전부
    .\.venv\Scripts\python diagnose.py "2. 연음.wav"   # 하나만
출력은 콘솔 + docs/experiments/keyassist_diag.txt 저장.
"""
from __future__ import annotations

import os
import sys
import io
import warnings
import logging
from pathlib import Path

warnings.filterwarnings("ignore")
logging.disable(logging.WARNING)

from app.analyze import analyze_audio
from app.schemas import AnalyzeOptions
from app.assistant import run_key_and_assistant
from app.key_detect import score_keys, KEY_CONF_HIGH, KEY_CONF_LOW

SAMPLES_DIR = Path(os.environ.get("HUMMING_SAMPLES_DIR", str(Path(__file__).resolve().parent / "samples")))
OUT = Path(__file__).resolve().parent.parent / "docs" / "experiments" / "keyassist_diag.txt"
PC = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]


def nm(m) -> str:
    import math
    if m is None or (isinstance(m, float) and not math.isfinite(m)):
        return "--"
    mi = int(round(m))
    return f"{PC[mi % 12]}{mi // 12 - 1}"


def tier_of(conf: float) -> str:
    if conf >= KEY_CONF_HIGH:
        return "high"
    if conf >= KEY_CONF_LOW:
        return "mid"
    return "low"


def diagnose(path: Path, w) -> None:
    raw = path.read_bytes()
    res = analyze_audio(raw, AnalyzeOptions())          # notes carry pitch_raw
    notes = [n.model_copy() for n in res.notes]         # fresh copy for debug re-run
    dbg: list = []
    info = run_key_and_assistant(notes, True, True, None, None, debug_out=dbg)

    p = lambda s="": print(s, file=w)
    p("=" * 78)
    p(f"SAMPLE: {path.name}")
    p("=" * 78)

    if info["hist"] is None:
        p("(no pitched notes — percussive or empty)")
        p("")
        return

    hist = info["hist"]
    p("pitch-class histogram (weighted):")
    p("  " + "  ".join(f"{PC[i]:>3}" for i in range(12)))
    p("  " + "  ".join(f"{hist[i]:>3.1f}" for i in range(12)))

    top = score_keys(hist)[:3]
    margin = top[0][0] - top[1][0] if len(top) > 1 else top[0][0]
    p("")
    p("top-3 key candidates:")
    for corr, tonic, mode in top:
        p(f"  {tonic:>2} {mode:<5}  corr={corr:+.3f}")
    p(f"  margin(1st-2nd) = {margin:.3f}")

    unique_pc = int((hist > 0).sum())
    total_dur = sum(float(n.duration) for n in notes if n.kind == "pitched")
    conf = info["confidence"]
    p("")
    p(f"n_pitched={info['n_pitched']}  unique_pc={unique_pc}  total_dur={total_dur:.2f}s")
    p(f"detected: {info['tonic']} {info['scale']}  confidence={conf:.3f}  tier={tier_of(conf)}")
    p(f"assist_applied={info['applied']}")

    p("")
    p("per-note:")
    p(f"  {'#':>2} {'rawF':>7} {'raw':>4} {'inK':>3} {'sel':>4} {'cents':>6} {'src':>9}  cand(cost)  reason")
    for d in dbg:
        if d.get("kind") == "percussive":
            p(f"  {d['idx']:>2}  (percussive)")
            continue
        cand = " ".join(
            f"{nm(c)}:{d['candidate_costs'][c]:.2f}" if c in d["candidate_costs"]
            else f"{nm(c)}:keep"
            for c in d["candidates"]
        )
        p(f"  {d['idx']:>2} {d['raw_float']:>7.2f} {nm(d['raw_note']):>4} "
          f"{str(d['in_key']):>3} {nm(d['selected']):>4} {d['correction_cents']:>6.0f} "
          f"{d['source']:>9}  {cand}  {d['suppressed_reason']}")
    p("")


def main():
    if len(sys.argv) > 1:
        targets = [SAMPLES_DIR / sys.argv[1]]
    else:
        targets = sorted(SAMPLES_DIR.glob("*.wav"))
    OUT.parent.mkdir(parents=True, exist_ok=True)
    buf = io.StringIO()

    class Tee:
        def write(self, s):
            sys.stdout.write(s); buf.write(s)
        def flush(self):
            sys.stdout.flush()

    tee = Tee()
    for pth in targets:
        if not pth.is_file():
            print(f"missing: {pth}"); continue
        diagnose(pth, tee)
    OUT.write_text(buf.getvalue(), encoding="utf-8")
    print(f"\n[saved] {OUT}")


if __name__ == "__main__":
    # UTF-8 console
    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except Exception:
        pass
    main()
