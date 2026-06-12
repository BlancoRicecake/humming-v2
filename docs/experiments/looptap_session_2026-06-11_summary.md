# LoopTap Hum-to-MIDI 정확도 작업 — 세션 요약 (2026-06-11)

목표: LoopTap **엔진→앱 노트 경로**의 정확도 개선.
지표: `eval_looptap.py`의 `app_note_f1` ±1스텝(`_t1`) — 실제 앱 대표 지표 (근거: EVAL_LOOPTAP.md).
시작점: dev 0.864 / test 0.870 (2026-06 베이스라인, 튜닝 중단 상태에서 재개).

---

## 1. 한 일 (시간순)

1. **잔여 오류 분해** — 신규 진단 `backend/diag_looptap_pitch.py`:
   ±1스텝 매칭된 노트의 피치 오류 81개(dev 30)를 분류 + 반사실(counterfactual) 스냅 측정.
   - **이중 양자화 가설 기각**: raw 연속 피치를 사다리에 직접 스냅해도 net +0.001
     (15개 고침 / 14개 깨뜨림). 어시스턴트의 크로마틱 결정은 net 양수
     (pre-assistant `pitch_original` 스냅은 −2.4%p).
   - **진범 발견**: 오류의 33%가 단 1개 샘플(F01_0032_0001_1) — `phraseOctaveShift`
     의 median이 ÷12 반올림 경계에 걸려 pred=0 vs oracle=+12로 프레이즈 전체(27노트)가
     옥타브째 어긋남. GT median이 정확히 경계값 0.5에 위치((71−65)/12).
2. **시프트 규칙 A/B** — 신규 진단 `backend/diag_looptap_octave.py`:
   pred/oracle 양쪽에 대칭 적용해 5개 규칙 비교 (dev 100, 분석 1회/샘플).
   | 규칙 | shift 일치율 | note_f1_t1 |
   |---|---|---|
   | median (현행) | 0.940 | 0.871 |
   | **mean** | **0.960** | **0.891** |
   | wmedian (duration 가중) | 0.940 | 0.876 |
   | cost (스냅왜곡 argmin) | 0.960 | 0.885 |
   | cost_w | 0.950 | 0.882 |
   - mean 채택: 전 지표 1위 + Dart 시그니처(`Iterable<int>`) 무변경 + 가장 단순.
3. **구현 (양쪽 동기 수정)**:
   - `mobile/lib/looptap/music/hum_map.dart` `phraseOctaveShift`: median → 산술평균.
   - `backend/app/looptap_map.py` `phrase_octave_shift`: 동일 변경 (1:1 미러 유지).
   - 골든 벡터 재생성 + 경계 회귀 케이스 `[60, 60, 65]` 추가 (median이면 +12로
     뒤집히는 케이스를 mean=0으로 고정).
   - 테스트: Python `tests/test_looptap_map.py` 11개 ✅, Dart
     `hum_map_parity_test.dart` 13개 ✅.
4. **정식 평가** (`eval_looptap.py`, 2-layer, dev/test 각 30):

   | metric | dev 전→후 | test 전→후 |
   |---|---|---|
   | **app_note_f1 (±1)** | 0.864 → **0.898** | 0.870 → **0.910** |
   | app_pitch_acc | 0.863 → **0.925** | 0.893 → **0.938** |
   | app_note_f1 (tol=0) | 0.454 → 0.487 | 0.628 → 0.660 |
   | app_step_f1 (±1) | 0.959 (불변) | 0.967 (불변) |

   test가 dev보다 더 크게 개선 → 일반화 확인. 매칭 노트의 옥타브 오류는 0이 됨
   (pc_acc == pitch_acc).

---

## 2. 결론

- **median은 옥타브 결정에 부적합** — knife-edge 통계라 경계 근처에서 엔진/정답의
  1 semitone 차이가 프레이즈 전체를 옥타브째 뒤집음 (dev100 기준 샘플의 6%).
  mean은 노트 구성 차이에 부드럽게 반응해 이 모드를 제거.
- **현 구조의 쉬운 개선은 재소진** — 잔여 ~7% 피치 오류는 대부분 raw 피치가 정답에서
  ≥2 st 먼 검출 오류(hard). 남은 레버: `learned_pitch_correction` HumTrans 재학습
  (기대 수익 작음), 온셋/세그먼테이션 (tol=0은 free-rhythm 아티팩트라 실익 낮음).
- 갱신된 베이스라인·이터레이션 로그: `backend/EVAL_LOOPTAP.md`.
  진단 도구 2종은 backend에 유지 (재실행 커맨드는 각 파일 docstring).

## 3. 변경 파일

| 파일 | 변경 |
|---|---|
| `mobile/lib/looptap/music/hum_map.dart` | phraseOctaveShift median→mean |
| `backend/app/looptap_map.py` | 동일 (Python 미러) |
| `backend/tests/test_looptap_map.py` | 경계 회귀 테스트 + 골든 케이스 추가 |
| `mobile/test/looptap/fixtures/hum_map_golden.json` | 재생성 |
| `backend/EVAL_LOOPTAP.md` | 베이스라인 표·이터레이션 로그 갱신 |
| `backend/looptap_{eval,summary}_{dev,test}.{csv,json}` | 새 베이스라인 출력 |
| `backend/diag_looptap_pitch.py` (신규) | 피치 오류 분류 + 반사실 스냅 |
| `backend/diag_looptap_octave.py` (신규) | 시프트 규칙 대칭 A/B |
