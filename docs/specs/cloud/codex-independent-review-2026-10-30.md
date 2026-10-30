# Codex 독립 검증 2차 — 2026-10-30

## 결과
- 기존 서버 24개 테스트는 독립 실행에서도 통과.
- 새 안전성 검증 5개는 실패: 서버 3개 + 앱 2개. 아래 실제 재현 근거를 먼저 해결해야 한다.
- 테스트 R2는 대역이지만 서버의 DB 변경은 저장소 내부 실제 PostgreSQL에서 일어난다. 운영 DB/버킷/고객 데이터는 쓰지 않았다.
- 로그: artifacts/cloud-backup-2026-10-30/codex/server-initial.log, app-initial.log.

## C1 [P1] RPC 응답 유실 시 정상 커밋 파일 삭제
- 위치 backend/app/routes/projects.py, commit RPC 예외 처리의 delete_objects([final_key]).
- RPC.execute()가 실제 DB 커밋을 마친 뒤 TimeoutError를 내도록 주입했다. API는 500, DB는 새 bk key를 가리키지만 그 파일은 예외 처리에서 삭제된다.
- HTTP 오류만으로 커밋이 안 됐다고 판단하면 안 된다. 결과 불명 상태에서 파일 보존, 재조회/동일 요청 재시도/멱등 커밋으로 확정해야 한다. 실패가 확정되지 않은 bk 파일을 지우지 말 것.
- 수용: test_committed_backup_survives_rpc_response_loss (실제 RPC 수행 후 응답 유실).

## C2 [P1] DELETE 후 prefix 정리가 새 백업을 삭제
- DELETE RPC로 행 삭제 → R2 delete_prefix 직전 중단 → 다른 기기가 같은 곡으로 새 업로드/첫 커밋 성공 → DELETE 정리 재개 순서.
- DB에는 새 사본이 있는데 파일이 없어졌다.
- prefix 전체를 뒤늦게 삭제하지 말고 삭제 대상 세대/객체 집합이 확정돼야 한다. 새 커밋과 객체 정리의 동시성도 테스트할 것.
- 수용: test_delete_cleanup_cannot_remove_a_newly_committed_backup. 삭제를 세대 단위로 바꾸면 이 독립 테스트의 중단 지점은 실제 수정된 경계로 이동해도 되나, 사건 순서와 기존 검증은 유지한다.

## C3 [P1] 저장소 삭제 실패인데 성공 반환, 녹음은 남음
- FakeR2.delete_objects가 각 객체에 Errors/AccessDenied를 반환하도록 했다. API는204, 목록 행은 없어지고 녹음 파일은 남는다. 사용자는 재시도할 화면도 잃는다.
- 부분 실패를 감지하고 재시도 가능한 상태를 보존하거나 확실한 삭제 작업 상태를 노출한다. 새 백업을 건드리지 않아야 하며 '삭제 완료'라고 잘못 표시하지 않는다.
- 수용: test_delete_partial_r2_failure_does_not_claim_everything_removed + 실패 해제 후 재시도 시 원래 녹음 제거 확인 추가.

## C4 [P2] 동시 링크 저장 파일 경쟁
- mobile/test/qa_cloud_independent_test.dart: CloudLinks.put 20개를 Future.wait로 동시에 실행했다. 공유 cloud_links.json.tmp 접근 충돌로19개 PathAccessException 발생.
- 링크 read-modify-write를 직렬화하고 원자적 파일 교체를 보장해야 한다. 병렬 곡 백업의 성공 링크를 잃지 않는다.

## C5 [P2] 클라우드 링크가 계정별로 분리되지 않음
- 같은 기기/로컬 곡에서 계정A API(FakeCloud A)로 백업한 뒤 빈 계정B API(FakeCloud B)로 백업하면 A의 expected_updated_at을 B에 보내 CloudConflict 발생. CloudLinks는 전역 파일이며 user ID가 없다.
- 독립 테스트는 실제 인증 서버가 아닌 분리된 API 대역으로 이 상태 오염을 재현한다. 실제 AuthService 계정 교체까지 검증 범위를 넓혀야 한다.
- API 작업 시작 시 계정 ID를 고정해 링크와 캐시를 UID별로 분리하고, 작업 중 계정이 바뀌면 다른 계정 요청/링크 갱신을 중단한다. 진행 중 다운로드 후 다른 사용자 저장소에 자동 복원되지 않도록 한다.
- 테스트가 새 owner 파라미터를 받게 바뀌면 계정 A/B를 명시해 수정 가능하다. 계정 분리 검증을 없애거나 같은 계정으로 바꾸지 말 것.

## 실행 자료
- 서버 독립 테스트: artifacts/cloud-backup-2026-10-30/codex/test_server_safety.py
- 실행기: 같은 폴더 run_server.py. stdout cp949 인코딩 문제로 마지막 print만 실패했으나 server-initial.log에 실제 pytest 결과(3 failed,24 passed)가 있다. UTF-8 출력을 사용해 이후 로그를 별도 이름으로 저장한다.
- 앱 독립 테스트: mobile/test/qa_cloud_independent_test.dart (임시 자료는 저장소 artifacts 내부, 실제 고객 파일 아님).

## 작업 범위
기존 미커밋 코드가 최신이다. 브랜치/commit/push/PR/운영 배포/DB 변경/고객 파일 업로드 금지 유지. 이 5개를 수정하고 실제 사건을 유지하는 회귀 테스트를 정식 테스트에 넣어라. Codex 원본 initial 로그는 보존하고 수정 후 자료는 별도 results 경로에 남긴다. 기존 live 테스트를 무조건 skip한 부분도 차기 운영 테스트로 대체하기 전 완료라고 하지 않는다.
## C6 [P2] 좁은 화면 버튼 넘침 — 추가 확인
- mobile/test/qa_cloud_layout_test.dart: 320px에서 복원·삭제 버튼 Row가 넘친다.
- 위젯 기본 Ahem뿐 아니라 실제 Windows Segoe UI + 맑은 고딕을 FontLoader로 로드해 재확인했다. 실제 글꼴: en 1.0은18px, en 1.5는121px, ko 1.0은1.2px overflow. 960px ko1.5는 통과.
- 근거 artifacts/cloud-backup-2026-10-30/codex/layout-real-fonts.log. 실제 폰을 검사한 것은 아니며 PC headless 렌더다.
- 버튼을 줄바꿈/세로 배치 등으로 접근 가능하게 하고 실제 문구/동작은 유지한다. 시험 글꼴에서도 실패하지 않아야 한다.

## 별도 실제 통신 검증 (Codex)
- qa_cloud_wire_test.dart + artifacts/.../codex/run_wire.py는 실제 Dart Dio→Python 실제 라우트→로컬 PostgreSQL 왕복을 확인한다. R2만 HTTP로 노출한 대역이다.
- 기본 왕복은 통과: MIDI 속성, 녹음2개 총128088바이트 일치, 기존 로컬 곡 보존, 재백업시 같은 클라우드곡 유지, 삭제후로컬유지, 스토리지로 토큰 전달0건.
- http-roundtrip-evidence.json, http-roundtrip.log 참고.
- 이 HTTP 테스트는 --dart-define=QA_CLOUD_WIRE=true 를 준 로컬 전용 실행기에서만 켜고 일반 전체테스트에서는 skip한다. 운영을 테스트한 것이 아니다. 기본 플래그 유지.

## C5 추가 경계 재현 (수정 후 확인 중)
- 계정별 링크와 동시 쓰기 2개는 Codex 재실행에서 통과했다.
- 그러나 qa_cloud_independent_test.dart에 추가한 경계2개는 실패:
  1. API presign onResponse에서 signedIn을 account-b로 바꾼 뒤, 저장 PUT이1회 실행됨. commit 직전에만 막히므로 이미 private bytes는 전송됨. presign 응답 이후와 실제 bytes 전송 직전에도 계정 확인 필요.
  2. GET /projects onResponse에서 signedIn을 바꾸면 list()가 account A 사본을 그대로 반환함. 이전 계정 응답은 UI로 전달되지 않아야 한다.
- 근거 codex/account-boundaries-initial.log. 기존 테스트는 보존했고2개 추가됨. 모든 비동기 요청의 응답 수신 후와 저장/복원 적용 직전 경계를 점검한다. auth interceptor가 토큰을 가져오는 동안 계정이 바뀌는 것도 고려한다.
- 추가 C5 테스트는 API 대역으로 경계 재현한 것이며 실제 로그인 서버 전환은 미검증이다.

## 출시 전 운영 보완으로 반드시 남길 점
- 미커밋 young bk 객체는 삭제시 COMMIT_WINDOW 동안 남겨 두는데, 행 삭제 후 이 곡에 다른 작업이 없으면 자동 정리 작업이 없어서 남은 객체가 계속 남을 수 있다(기존 test_delete_removes_leftover_uploads_but_not_a_commit_in_progress가 young bk 잔존을 명시적으로 확인함).
- 따라서 '클라우드 파일 전체 삭제 완료'라고 해석될 수 있는 안내와 정리 완료 보장은 구분해야 한다. 안전한 주기적 고아 정리/삭제 재시도 설계는 실제 운영 전 남은 일에 명시한다. 현재 운영 기능은 켜지 않는다.

### C5 기존 화면의 목록 캐시 추가 확인
- qa_cloud_layout_test.dart의 `cached cloud list disappears when signed in account changes` 실패.
- A 계정 목록이 로드된 뒤 currentOwner를 B로 바꾸고 LoopStore 알림으로 rebuild하면 A의 곡 제목이 여전히 표시된다. API 응답 시점이 아닌, 이미 받은 캐시를 표시하는 build 경계도 차단해야 한다.
- 근거 codex/cached-account-initial.log. 계정 변경 시 목록/상태를 숨기고 새 계정으로 재진입·재조회하도록 한다. A 데이터가 보이는 상태로 복원/삭제를 누를 수 없게 한다.

### C4 최종 전체 실행에서 파일 교체 거부 추가 재현
- Codex flutter-full-final.log의 `C4: parallel backups of different songs keep every link`가 실제 PathAccessException(errno5)로 실패했다.
- cloud_links/user-a.json.<pid>-<seq>.tmp → user-a.json rename이 거부됨. tmp 충돌은 고쳤지만 Windows의 일시적인 교체 실패를 처리하지 못한다. root 임시 경로라 다른 테스트 기기의 파일과 같지 않다.
- 최초 증거는 codex/flutter-full-final.log이며 덮어쓰지 않는다. CloudLinks._write는 목적 파일/기존 링크를 보존하면서 일시적인 OS 잠금 실패를 제한된 재시도로 처리해야 한다(기존 저장/내보내기 구현의 Windows 대응 참고). 무한 재시도나 기존 파일 선삭제는 금지.
- 단독 core19/독립4에서는 통과했으나 전체 실행에서 재현됐으므로 전체 통과라고 하지 않는다. 수정 후 결과는 별도 로그에 저장한다.

## Codex ffmpeg 환경 보완 결과
- 초기 backend-full-final.log는269통과/11skip/1실패(기존 ffmpeg 없음)를 보존했다.
- 공식 PyPI imageio-ffmpeg==0.6.0을 artifacts/cloud-backup-2026-10-30/pgenv에만 준비하고 codex/tools/ffmpeg.exe를 검증 명령의 PATH에만 넣었다. 전역 PATH, 시스템 설치, backend requirements, 운영 이미지는 변경하지 않았다.
- codex/backend-full-with-ffmpeg.log:270 passed,11 skipped,실패0. ffmpeg-tool.json에 도구의 버전·출처·해시와 재현 경로를 남겼다. 재실행기 run_backend_with_ffmpeg.py.
- 정상 서버 이미지의 Dockerfile도 ffmpeg를 설치하도록 되어 있으나, 실제 운영 이미지에서 실행한 검증은 아니다.
