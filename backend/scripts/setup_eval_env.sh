#!/usr/bin/env bash
# HumTrans 정확도 개선 루프 — 새 세션 부팅 스크립트 (idempotent)
#
# 하는 일:
#   1) eval venv 생성 + DSP/평가 의존성 설치 (시스템 setuptools 버그 회피)
#   2) HumTrans 공식 repo(GT MIDI / split / 공식 metric)를 GitHub에서 취득
#   3) HF에서 humming 오디오(all_wav.zip) 다운로드 → test/valid 서브셋만 추출
#
# 사용:
#   bash backend/scripts/setup_eval_env.sh            # 전체
#   SKIP_AUDIO=1 bash backend/scripts/setup_eval_env.sh   # 오디오 빼고
#
# 필요한 환경 변수(클라우드 환경 설정에서 미리 세팅 권장):
#   HF_HUB_DISABLE_XET=1   # Xet CDN(cas-bridge.xethub.hf.co) 회피 → *.huggingface.co로 다운로드
#   HF_TOKEN=hf_xxx        # (선택) HumTrans가 gated일 때만
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BE="$ROOT/backend"
DATA="$BE/.eval_data"          # gitignore 대상
VENV="$BE/.venv_eval"          # gitignore 대상
mkdir -p "$DATA"

echo "==> [1/3] eval venv"
if [ ! -x "$VENV/bin/python" ]; then
  python3 -m venv "$VENV"
fi
# shellcheck disable=SC1091
. "$VENV/bin/activate"
python -m pip install -q --upgrade pip setuptools wheel
python -m pip install -q "numpy<2.1" scipy "librosa>=0.10.1" soundfile mido \
  pretty_midi mir_eval tqdm numba
python - <<'PY'
import pretty_midi, mir_eval, librosa, numpy
print(f"    venv OK: numpy {numpy.__version__}, librosa {librosa.__version__}, mir_eval {mir_eval.__version__}")
PY

echo "==> [2/3] HumTrans GT + 공식 metric + split (GitHub)"
if [ ! -d "$DATA/HumTrans-main" ]; then
  curl -sL -o "$DATA/humtrans.tar.gz" \
    "https://codeload.github.com/shansongliu/HumTrans/tar.gz/refs/heads/main"
  tar xzf "$DATA/humtrans.tar.gz" -C "$DATA"
  rm -f "$DATA/humtrans.tar.gz"
fi
GT="$DATA/HumTrans-main/midis/gt"
if [ ! -d "$GT" ]; then
  unzip -oq "$DATA/HumTrans-main/midis/GroundTruth.zip" -d "$DATA/HumTrans-main/midis/gt_raw"
  mkdir -p "$GT" && mv "$DATA/HumTrans-main/midis/gt_raw/GroundTruth" "$GT/" 2>/dev/null || true
fi
echo "    GT test=$(ls "$GT"/GroundTruth/test 2>/dev/null | wc -l) valid=$(ls "$GT"/GroundTruth/valid 2>/dev/null | wc -l)"

echo "==> [3/3] HumTrans 오디오 (HuggingFace)"
if [ "${SKIP_AUDIO:-0}" = "1" ]; then
  echo "    SKIP_AUDIO=1 → 건너뜀"; exit 0
fi
WAV_DIR="$DATA/wav"
if [ -d "$WAV_DIR" ] && [ "$(ls "$WAV_DIR" 2>/dev/null | wc -l)" -gt 0 ]; then
  echo "    이미 존재: $(ls "$WAV_DIR" | wc -l) wav"; exit 0
fi
HF_BASE="https://huggingface.co/datasets/dadinghh2/HumTrans/resolve/main"
echo "    다운로드: all_wav.zip (대용량 — df -h 확인 권장)"
if ! curl -fL --retry 4 -H "Authorization: Bearer ${HF_TOKEN:-}" \
      -o "$DATA/all_wav.zip" "$HF_BASE/all_wav.zip"; then
  echo "    !! HF 다운로드 실패 — 도메인 허용(*.huggingface.co, *.xethub.hf.co) / HF_HUB_DISABLE_XET / HF_TOKEN(gated) 확인" >&2
  exit 1
fi
mkdir -p "$WAV_DIR"
# test+valid split 키만 추출 (전체 14k 중 일부) — 디스크 절약
keys="$DATA/HumTrans-main/test_keys.txt $DATA/HumTrans-main/valid_keys.txt"
python - "$DATA/all_wav.zip" "$WAV_DIR" $keys <<'PY'
import sys, zipfile, os
zpath, out = sys.argv[1], sys.argv[2]
wanted=set()
for kf in sys.argv[3:]:
    with open(kf) as f: wanted|={l.strip() for l in f if l.strip()}
z=zipfile.ZipFile(zpath); names=z.namelist()
got=0
for n in names:
    base=os.path.splitext(os.path.basename(n))[0]
    if base in wanted and n.lower().endswith('.wav'):
        with z.open(n) as src, open(os.path.join(out, base+'.wav'),'wb') as dst:
            dst.write(src.read()); got+=1
print(f"    추출 {got} wav (요청 키 {len(wanted)})")
PY
rm -f "$DATA/all_wav.zip"
echo "==> 완료. 데이터: $DATA  (venv: $VENV)"
