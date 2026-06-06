# HumTrans 평가 — 라운드 1 (지표 재정의 + 베이스라인 확정)

> 브랜치 `claude/intelligent-lamport-PWIP3`. 데이터/venv 는 `backend/.eval_data`(gitignore).
> 평가: `python backend/scripts/humtrans_eval.py --split test --limit 150 [--opts '{...}']`

## 지표 재정의 (라운드0 발견 반영 — GT 가 양자화 격자)
절대-onset 50ms 매칭은 GT 가 양자화 악보 타이밍이라 무의미 → **시퀀스 정렬 기반**으로 전환.
- 노트열을 세그먼트 내 **정규화 위치(0~1) + 가벼운 피치항**으로 순서보존 정렬(NW),
  옥타브는 정렬 총비용 최소로 합동 선택.
- **노트 수 정확도** = 1 − |est−ref|/ref
- **타이밍(리듬) 정확도** = 연속 정렬쌍 IOI 비율(전역 템포 정규화)이 **1.5배 이내**인 비율
- **피치 정확도** = 정렬쌍 중 |Δpitch|≤0.5반음 (옥타브 정합). 전체 노트 커버(편향 제거)
- 보조: melody_acc(피치+리듬 종합/n_ref), align_coverage(=recall), onset_resid_mae(루바토 진단)

## 사용자 우선순위
> **노트 타이밍·개수 > 피치.** → 개수/타이밍 90% 를 먼저 달성. 피치는 후순위.

## 베이스라인 (test 150, 기본 옵션, pYIN)
| 축 | FINAL | RAW(assistant 전) |
|---|---|---|
| 노트 수 정확도 | **0.869** | 0.869 |
| 타이밍(리듬) | **0.811** | 0.811 |
| 피치 | 0.569 | 0.563 |
| melody 종합 | 0.486 | 0.481 |
| align_coverage | 0.864 | — |
| onset_resid_mae | 124 ms | — |
| 공식 note-F1 | 0.026 | (참고, 절대-onset → 항상 낮음) |

- est_mean **22.7** vs ref_mean **25.9** → **세그먼트당 ~3노트 미생성(누락)**.
- FINAL≈RAW → pitch_assistant 는 GT 일치에 거의 영향 없음(검출 키가 GT와 무관).

## 진단 — 1순위 레버 = 누락/과소분절 복구
- est < ref (약 −12%) + coverage 0.86 → **노트를 덜 만든다**. 이 누락이
  노트수·타이밍·coverage 를 동시에 깎음(빠진 노트가 IOI 사슬을 끊어 리듬도 손해).
- 가설 후보(다음 라운드에서 1개씩 A/B):
  1. 레가토 같은-음 반복이 한 덩어리로 병합 → `rms_dip_split` 민감도/`rms_dip_max_pitch_span_st`.
  2. 짧은/여린 노트가 게이트에 잘림 → `min_chunk_dur_sec`, `enter_ratio`/`exit_ratio`.
  3. 같은 음 연속(피치 일정) 전이 미검출 → onset/`pitch_split`.

## 다음
1. 누락 노트 성격 진단(짧은가/여린가/같은음 반복인가) — `humtrans_diag_missing.py`.
2. 가설 1개씩 `--opts` A/B (빠른 서브셋) → 채택/롤백, 본 로그에 라운드별 기록.
3. 노트수·타이밍 90% 달성 후 피치 손대기. 메인 앱 불변, 최종 파라미터만 반영.
