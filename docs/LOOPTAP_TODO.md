# LoopTap (HumTrack) — Followup Tasks

UI 상에서 잠시 가려둔 / 주석 처리한 기능들. 출시 후 작업 우선순위 순서.

## 미구현 → UI 노출 해제 대기

### 1. Cloud backup (account sheet)

- 위치: `mobile/lib/looptap/widgets/sheets/account_sheet.dart:188`
- 주석: `// TODO: Cloud backup 기능 미구현 — 백엔드 sync 연결 후 노출.`
- 내용: Account sheet 의 signed-in 뷰에서 "Cloud backup · Loops synced across devices" row 가 주석 처리됨. 구현되면 주석 해제만 하면 됨.
- 의존성: backend 의 R2 + projects 동기화 (이미 backend 에 `/projects`, `/storage/presign`, `/storage/usage` 라우트는 살아있음) → LoopTap 의 노래/세션 모델을 그쪽에 매핑하는 작업이 남음.

### 2. Audio (WAV) export

- 위치: `mobile/lib/looptap/widgets/sheets/export_drawer.dart:153`
- 주석: `// TODO: WAV / Stems 는 backend 렌더링 서버 구현 후 노출.` — row 자체가 주석 처리됨.
- 내용: SoundFont 기반 곡 전체 믹스 렌더 → WAV. 사용자는 단일 파일 다운로드.
- 의존성: backend 에 렌더링 endpoint 필요 (예: `POST /render/wav` — payload = `{sections, bpm, instruments}` → WAV bytes).

### 3. Stems export

- 위치: `mobile/lib/looptap/widgets/sheets/export_drawer.dart:153`
- 주석: 동일.
- 내용: 트랙별 분리 WAV (melody / bass / drums / vocal). zip 으로 한 번에 다운로드.
- 의존성: 위의 WAV 렌더와 같은 백엔드 인프라 + per-track 솔로 렌더 옵션.

## 잠금 해제 완료 (참고)

| 기능 | 상태 |
|---|---|
| MIDI export | ✅ MIDI 파일 저장 + iOS share sheet |
| Share | ✅ MIDI 와 동일 동작 (파일 저장 + share) — `_doMidi` 재사용 |

## 코드에서 찾기

```
grep -rn "TODO" mobile/lib/looptap --include="*.dart"
```
