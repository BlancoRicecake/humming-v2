# 작업 규칙 — 사본·브랜치·출시

사람이든 AI 에이전트(Claude Code, Codex)든 이 규칙을 따른다. 새 세션은 이 문서와 [`PLAN.md`](PLAN.md)부터 읽는다.

## 1. 저장소 사본

| 기기 | 기준 사본 | 추가 작업 공간 |
|---|---|---|
| Windows PC | `C:\src\humming-v2` | `C:\src\humming-v2\.worktrees\<이름>` |
| Mac | `~/src/humming-v2` | `~/src/humming-v2/.worktrees/<이름>` |

- `C:\dev\Handy_code\...`, `~/.codex/worktrees/...` 같은 다른 위치에 새 사본을 만들지 않는다. Codex를 쓸 때도 작업 폴더를 `.worktrees/` 아래로 지정한다.
- 작업 공간은 일이 끝나면 push한 뒤 `git worktree remove`로 지운다.

## 2. 하루 흐름

```bash
git switch main && git pull --ff-only
python infra/scripts/dev_doctor.py --fetch    # FAIL이 있으면 고치고 시작
git switch -c feat/<짧은-이름>                 # 또는 fix/, chore/, docs/
# ... 작업 · 의미 단위 커밋 ...
git push -u origin HEAD                        # 당일 push. 로컬에만 있는 커밋을 남기지 않는다
gh pr create --fill                            # CI 통과 후 main에 병합
```

브랜치는 짧게(며칠) 유지한다. 오래 갈 작업(데스크톱 등)도 중간 단계마다 main에 병합한다.

## 3. 출시

- 출시 후보는 **main**에서만 만든다. 기능 브랜치에서 스토어로 올리지 않는다.
- 서명 빌드·업로드는 **GitHub Actions `Mobile Store Release`만** 쓴다. 로컬 `flutter build appbundle --release`나 Xcode Archive로 만든 파일을 스토어에 올리지 않는다.
- 버전은 두 플랫폼이 **같은 `pubspec.yaml` 버전**을 쓴다. 빌드 번호는 두 스토어의 최신 번호 중 큰 값 + 1.
- 출시한 커밋에 태그를 단다: `git tag v1.0.12+42 && git push origin v1.0.12+42`.
- 핫픽스: 태그에서 `fix/...` 브랜치 → Actions로 출시 → **같은 날 main에 병합**.

순서: main 최신화 → doctor 통과 → 버전·릴리스 노트 커밋 → Actions `destination=internal` → [`DEVICE-TEST.md`](DEVICE-TEST.md) 스모크 → 통과하면 `production` → 태그 → 출시 후 확인.

백엔드가 바뀐 출시는 **마이그레이션 → 백엔드 → 앱** 순서를 지킨다 (`DEPLOY-RUNBOOK-2026-09.md`). Fly 시크릿 `SUPABASE_JWT_SECRET`이 빠지면 유료 사용자 전원이 Pro를 잃는다.

## 4. 설정 파일

- 원본 위치: `backend/.env.secrets`, `backend/secrets/humtrack-transfer/` (plist, Play 서비스 계정, 서명 키). git에 넣지 않는다. 이 폴더의 plist는 2026-10-12 현재 옛 파일이므로 Mac의 병합본으로 교체해야 한다 ([`MAC-REMOTE-SETUP.md`](MAC-REMOTE-SETUP.md)).
- 다른 기기로 옮긴 뒤에는 반드시 doctor를 돌려 지문이 맞는지 확인한다.
- 값을 **의도적으로 바꿀 때만** 신뢰하는 기기에서 `python infra/scripts/dev_doctor.py --write-fingerprints` → `infra/dev-config-fingerprints.json` 커밋 → 다른 기기와 GitHub Secrets(`HUMTRACK_DART_DEFINES_JSON`, `GOOGLE_SERVICE_INFO_PLIST_BASE64`)도 같은 날 갱신한다.

## 5. AI 에이전트 인계

- 세션이 끝날 때: 커밋·push, 그리고 남은 일과 결정을 `docs/` 아래 해당 문서(예: `docs/vision/context-notes.md`)에 적는다.
- 인계 문서에 다른 PC의 절대경로(예: `C:/Users/jlion/.codex/...`)를 "작업 위치"로 남기지 않는다. 브랜치 이름으로 남긴다.
- 커밋하면 안 되는 자동 변경: `mobile/pubspec.lock`(의존성 변경이 아닌 경우), `mobile/analysis_options.yaml`.
