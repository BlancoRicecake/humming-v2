# HumTrans 정확도 개선 루프 — 인수인계 노트

> 새 세션이 이 작업을 이어받기 위한 컨텍스트. 작업 브랜치: `claude/hopeful-shannon-1lgqb`.

## 목표
humtrans 데이터셋으로 음성 분석(휴밍→노트) 퀄리티 개선. **축별 관대 지표**로
**노트 수 정확도 / 피치 정확도 / 노트 타이밍 정확도 각각 90% 이상**.
루프: 로컬서빙(FastAPI `/analyze`) → 테스트셋 정확도 검증 → 미달 시 부족점 분석 → 개선 → 반복.

## 사용자와 합의된 결정
1. **정확도 정의 = 축별 관대 지표** (엄격 결합 note-F1 아님).
   - 노트 수 정확도 = `1 - |est-ref|/ref`
   - 피치 정확도 = 매칭된 노트 중 ±0.5반음 이내 비율
   - 타이밍 정확도 = onset 50ms 이내 매칭 비율 (+ 평균 절대편차 보조)
   - 참고로 공식 mir_eval note-F1도 함께 리포트(엄격 결합 90%는 SOTA ~6%라 비현실적이므로 판단 기준 아님).
2. **테스트 오디오 = 실제 HumTrans `.wav`** (사용자가 HF를 네트워크 허용목록에 추가:
   `huggingface.co`, `*.huggingface.co`, `*.hf.co`). 새 세션에서 HF 접근 가능해야 함.
   - HF 접근 안 되면 폴백: 받아둔 GT MIDI를 휴밍풍으로 렌더한 **합성 벤치**.

## 데이터셋 사실관계
- 공식 repo: `github.com/shansongliu/HumTrans` (codeload로 tar.gz 받기 가능).
  - `midis/GroundTruth.zip` → 정답 MIDI (valid 765 + test 769 = 1534 세그먼트).
  - `calc_transcription_eval_metric.py` → **공식 평가 스크립트**.
  - `valid_keys.txt` / `test_keys.txt` / `train_valid_test_keys.json` → 공식 split.
  - 베이스라인 4모델 예측: `midis/{VOCANO,SheetSage,MIR-ST500,JDC-STP}.zip`.
- 오디오 `.wav`(44.1kHz)는 **HF에만**: `huggingface.co/datasets/dadinghh2/HumTrans`
  (`all_wav.zip`, `all_midi.zip`). 파일명 규칙 `personID_musicID_segmentID_repetitionID`.
- 세그먼트 노트 수 통계(test GT): 세그먼트당 평균 다수 노트(짧은 멜로디 조각).

## 공식 metric 핵심 (calc_transcription_eval_metric.py)
- `mir_eval.transcription.precision_recall_f1_overlap`
- onset_tolerance=**0.05s**, pitch_tolerance=**1.0 반음**, offset_ratio=**None**(오프셋 무시).
- **옥타브 불변**: ref 피치를 -16..+16 옥타브 시프트하며 best-F1 선택 (휴밍 옥타브 모호성).
- `trim_midi`: est 노트를 ref 첫/마지막 onset 구간으로 자른 뒤 비교.
- 우리 축별 지표도 동일한 매칭(옥타브 정합 후 onset 50ms + pitch 1반음)을 재사용할 것.

## 현 파이프라인 (개선 레버)
- `backend/app/analyze.py` : load→onset(HPSS)→pyin→voiced 게이팅→세그먼트→quantize→articulation
- `backend/app/onset.py`(=onset detection), `backend/app/pitch.py`(pYIN, opt CREPE)
- 튜닝 후보: onset 민감도/HPSS, voiced_prob_threshold, 어택 스킵·median 필터창,
  노트 과·미분할 병합, 옥타브 정합, pYIN↔CREPE.
- **메인 앱/엔드포인트는 불변 유지**, 평가·진단은 별도 스크립트로.

## 환경 (클라우드)
- 허용: PyPI, GitHub, (사용자 설정 후) HF. 차단됐던 것: HF/zenodo(기존).
- 시스템 setuptools가 `install_layout` 없어서 pretty_midi 빌드 실패 → **venv 필수**.
- eval venv 재구성:
  ```bash
  cd backend && python3 -m venv .venv_eval && . .venv_eval/bin/activate
  pip install -U pip setuptools wheel
  pip install "numpy<2.1" scipy "librosa>=0.10.1" soundfile mido pretty_midi mir_eval tqdm numba
  ```
  (`.venv_eval/`는 .gitignore 처리됨.)

## 새 세션 할 일 (순서)
1. eval venv 재구성(위) + HumTrans repo(GT/split/공식스크립트) codeload로 재취득.
2. HF에서 `all_wav.zip`(+필요시 `all_midi.zip`) 다운로드. 안 되면 합성 벤치 폴백.
3. 평가 하니스 작성: `/analyze` 결과(또는 analyze_audio 직접 호출)→노트→GT와
   옥타브 정합 매칭→축별 3지표 + 공식 note-F1, 세그먼트별·평균 리포트.
   서브셋(예: test 100개)으로 빠른 루프, 전체로 최종 검증.
4. 베이스라인 측정 → 축별 90% 미달 축 분석(과/미분할, 옥타브, voiced 게이팅 등) →
   가설 1개씩 A/B → 채택/롤백, `docs/experiments/`에 라운드 로그.
5. 90% 도달까지 반복. 메인 앱 불변, 최종 파라미터만 반영.
