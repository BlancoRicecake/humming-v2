# 드럼(음성 비트박스) 정확도 작업 — 세션 요약 (2026-06-06)

목표: **사람이 입으로 낸 드럼(보이스 비트박스) 인식 정확도를 90%로** 끌어올리기.
지표: `eval_drums.py`의 `drum_f1` (온셋이 허용오차 내 매칭 **그리고** kick/snare/hihat 클래스 일치).

---

## 1. 한 일 (시간순)

1. **작업 폴더 정정** — 정식 경로는 `Documents\Humtrack\Humming V2` (Desktop 사본 아님).
2. **평가 하네스 버그 수정** — IDMT 단일악기 `.svl`은 드럼 종류를 *파일명*(#KD/#SD/#HH)에 담는데
   파서가 못 읽어 모노포닉 점수가 **조용히 0점**이었음 → `eval_drums.py`에 `read_svl_events` 추가.
3. **베이스라인 측정** (어쿠스틱 IDMT, 프록시):
   - 모노포닉(한 번에 한 드럼) `drum_f1` **0.916** ✅ — 엔진 자체는 이미 90%+.
   - 폴리포닉 MIX(겹침) 0.505 — 제품 범위 밖.
4. **AVP 데이터셋 다운로드** — 일반인 28명의 *실제 음성* 비트박스, CC-BY-4.0. 제품 조건과 일치.
   - **AVP 즉흥(진짜 제품 조건) `drum_f1` 0.484** ← 진짜 격차.
   - Fixed(표준 음절) 0.554 vs Personal(자유) 0.412.
5. **근본 원인 진단** — 음성 **스네어 ≈ 하이햇**(현재 특징으로 ~70%만 분리), 킥은 분리되나
   임계값이 폰 1대(S10) 기준이라 음성 킥 절반 탈락(recall 0.39).
6. **로컬 소형 모델 구축** (사용자가 "no training" 제약 예외 승인):
   - 순수 numpy OVR 로지스틱, sklearn 서빙 의존성 0 (기존 `train_*.py`+`models/*.npz` 패턴).
   - v1(고립 정답 온셋 학습): **회귀** — train/serve 시프트로 improv 스네어 0.01 붕괴, 어쿠스틱 0.92→0.28.
   - **v1.1(검출된 온셋 학습)**: 건강해짐 — 화자분리 분류 0.735, improv 0.750, 스네어 붕괴 해결.
   - 단 엔드투엔드 improv는 0.484→**0.509** (소폭).
   - **모델 기본 OFF** (`HUMTRACK_DRUM_MODEL=1`로만 활성) — 회귀 방지, 인프라는 유지.
7. **온셋이 진짜 천장임을 규명** — improv onset_f1 0.83. 진폭 게이트를 낮추면 recall 0.83→0.94+
   회복되나 precision 급락(유령 타격). 순수 recall↔precision 트레이드.
8. **"천장" 주장 정정 + 정확도 레버 측정** (`diag_accuracy_levers.py`, `diag_enrollment.py`):
   - 분류 정확도: 선형 0.692 → **GBT 0.730** → 등록(enrollment) 0.74~0.75.
   - 사용자별 등록: 효과 **작음**(+0.01~0.02), 단 **3개씩만** 등록하면 충분, 일관된 사용자는 본인 천장(최고 0.926)까지.
9. **(진행 중) B: GBT를 서빙에 도입** — 트리 앙상블을 순수 numpy로 익스포트.
10. **v2 RF 모델 도입** — v1 feature contract는 유지하고, narrow-band energy/body-air ratio/
    early-body-tail shape 특징을 추가한 `drum_classifier_v2.npz`를 학습.
    - speaker-held-out 분류 정확도 **0.818**, held-out improv **0.822**.
    - AVP Improvisation end-to-end `drum_f1` **0.656**.
    - Fixed macro **0.745**, Personal macro **0.562**.

---

## 2. 핵심 결론

- **엔진(온셋+분류)은 어쿠스틱에서 이미 0.916** — 알고리즘 원리는 건전함.
- **자유로운 일반인 음성 비트박스의 0.90은 도달 불가에 가까움** — 연구 SOTA 수준.
  두 천장이 곱해짐: 온셋 ~0.83 × 음성 분류 ~0.70~0.75.
- **현실적 엔드투엔드 목표**: 일반 사용자 ~0.65~0.70, 일관된 사용자 ~0.85, GBT/RF+등록+온셋지점 선택 결합 시.
- 점수는 결국 **사용자가 얼마나 일관되게 비트박스하느냐**의 함수 (화자내 0.435~0.926).

## 3. 레버 ROI 순위 (측정 기반)

1. **풍부한 특징 + RF 분류기** (+0.03 end-to-end, 사용자 노력 0) ← v2 반영.
2. **온셋 false-positive pruning** — 현재 gate lowering은 recall만 올리고 precision을 크게 깎음.
3. **사용자별 등록** — 작은 보너스, 일관된 사용자용 옵션.
4. **표준 음절 UX 유도** — Fixed vs Personal +14점(제품 결정).
5. **온셋 recall 지점 선택** + 기존 노트 편집기 활용.

## 4. 코드 변경/추가 (이번 세션, 아직 커밋 안 함)

수정: `eval_drums.py`(svl), `app/drum_onset.py`(모델 연결, 기본 OFF).
추가: `app/drum_features.py`, `app/drum_classifier.py`, `train_drum_classifier_model.py`,
`models/drum_classifier_v1.npz`, 진단도구 `diag_avp_features.py`·`diag_avp_probe.py`·
`diag_onset_sweep.py`·`diag_accuracy_levers.py`·`diag_enrollment.py`,
결과 `docs/experiments/drum_*`.
프로덕션 동작은 변경 없음(모델 OFF, 휴리스틱 유지). 백엔드 분석 스모크 정상.

## 5. 데이터셋

- `Documents\Humtrack\datasets\IDMT-SMT-DRUMS-V2` — 어쿠스틱, CC-BY-NC-ND(평가전용).
- `Documents\Humtrack\datasets\AVP_Dataset\AVP_Dataset` — **음성 비트박스, CC-BY-4.0(상업 가능)**. 제품 타깃.
  바깥 unzip 폴더의 `__MACOSX`/`._*` 메타데이터는 평가·학습에서 제외.

전체 측정 상세는 `docs/experiments/drum_pipeline_90_plan.md` 참고.
