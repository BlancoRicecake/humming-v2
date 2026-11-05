# Docker 복구 및 로컬 서버 후보 검증

2026-11-01 KST. **Docker 복구·로컬 이미지 검증 완료, 운영 배포 미실행.**
작업/증거는 `C:/src/humming-v2/artifacts/docker-recovery-2026-11-01/`에 보존했다.

## Docker 시작 오류 복구

Docker Desktop4.85.0이 오래된 `dockerInference` AF_UNIX 소켓을 제거하지 못해
엔진 시작 전 종료됐다. Windows build26200, 해당 파일은0바이트/ReparsePoint,
마지막 기록은8월12일이었다. 이는 현지 파일 관찰과 backend 로그로 확인한 사실이다.
원인이 단순한 URI 문법 오류라고 확정하지 않는다. 같은 증상의
[Docker 이슈 보고](https://github.com/docker/desktop-feedback/issues/531)가 있다.

1. Docker Desktop이 종료됐고 backend/Desktop 프로세스가 없음을 확인했다.
2. 각 디렉터리의 실제 절대 경로·정상 부모·0바이트 소켓만 포함됨을 확인했다.
3. 아래 두 폴더를 **같은 부모 아래 이름만 변경해 보존**했다. 삭제하지 않았다.
   - `C:/Users/jlion/AppData/Local/Docker/run` → `run.before-humtrack-20261101`
   - `C:/Users/jlion/AppData/Local/docker-secrets-engine` → `docker-secrets-engine.before-humtrack-20261101`
4. Docker가 새 런타임 소켓을 만들도록 시작했다. Engine29.6.2/linux/amd64 응답 확인.
   이후 실제 로컬 빌드와 컨테이너 실행까지 성공했다.

공장 초기화, 이미지/컨테이너/볼륨/WSL 데이터 삭제, 다른 WSL 배포판 종료,
Docker 설정 변경·업그레이드·진단 업로드는 하지 않았다. 로그인 안내는 Skip으로 넘길 수 있다.
증거: `runtime-backups.json`, `engine-check.json`, 실행문 `preserve-runtime.ps1`.
복원은 Docker가 완전히 종료된 때 새 런타임 폴더도 별도로 보존한 뒤 원래 이름으로 돌려야 한다.
잠긴 예전 소켓을 복원하면 오류가 재발할 수 있으므로 현재 정상 런타임에 자동 복원하지 않는다.
오래된 소켓 백업은 삭제하지 않고 남긴다. 재시작/절전 후 재발까지 해결됐다고 주장하지 않는다.

## 서버 빌드 경계 보강

`backend/.dockerignore`에 secrets 폴더, 중첩 secrets, Android 키 속성·키 저장소,
Apple 키/인증서·Play 서비스 계정 및 추가 `.venv*`를 제외했다.
기존 원본 자격 증명과 `.env.secrets`는 바꾸지 않았다. 실제 완성 이미지에도
`/app/secrets`, `.env.secrets`, `.env`, key.properties, 로컬 venv가 없음을 확인했다.

현재 `backend/`에서 실제 음원11개를 포함해 로컬 Docker 이미지를 만들었다.

- 로컬 태그: `humtrack-backend:qa-20261101`
- 이미지 ID: `sha256:034b3d5d5e687e8a34d6f29424f4b872cbff1ea2f9e59a1816e2cf45fadd7a29`
- 기준 HEAD: `4f5f34d97901acaa863f6784406bbbb7aa0b34b9` + 미커밋 수정본.
- 빌드 표기: `4f5f34d9-dirty-20261101`. 파일별 해시·이미지 ID는 `backend-build-receipt.json`.
- 실제 Linux 설치 패키지 목록은 `linux-dependencies.txt`에 별도 기록했다.
- 필수8개 음원 누락/손상0, 실제 제공11/카탈로그 선언23, 나머지12개는 목록에서 제외.
- BuildKit 로그의 `docker.io/library/…` 이름은 로컬 태그일 뿐이다. registry push·Fly 배포는 하지 않았다.

## 실제 컨테이너 검증

외부 포트 없이 `--network none`,1CPU/1GiB로 실행했다. Supabase/R2/IAP/Sentry 운영 키는
주입하지 않았고 합성 음성만 사용했다. 실제 main.py/uvicorn 시작과 health를 확인했다.
클라우드와 주기적 정리는 OFF이며, 이 실행은 실제 삭제 작업자 검증을 대체하지 않는다.

| 검사 | 결과 |
|---|---|
| 현재 후보 health200, uid1000 실행 | 통과 |
| 비밀 파일·로컬 venv 미포함 | 통과 |
| 실제 음원11개와 크기/해시 제공 | 통과 |
| 부분 다운로드206, 전체 다운로드SHA-256, 범위 초과416 | 통과 |
| 미포함 선택 음원404, 클라우드 OFF 경로404 | 통과 |
| 합성 A4 WAV 분석, 같은 신호의 Opus 분석 | 통과 |
| 실제 MIDI 생성과 mido 파싱/노트 확인 | 통과 |

총12개 통과. 실제 음원 하나(가장 작은3993772바이트)를 전체 해시 비교했다.
나머지 음원의 전체 다운로드·재시작 이어받기·저장 공간 부족·소리 판단은 따로 남아 있다.
QA 컨테이너는 라벨 소유권을 확인한 뒤 종료했고 `--rm`으로 제거됐다.
검증 이미지는 후속 로컬 작업을 위해 유지했다. 증거는 `container-probe.json`,
`container-runtime.log`, `backend-image-build.log`다.

## 아직 남은 경계

- **운영 음원0개 문제는 아직 운영에서 해결된 것이 아니다.** 음원 포함 이미지가 로컬에서
  동작함을 확인했으며, 공개 배포 보류 지시에 따라 현 운영 이미지는 교체하지 않았다.
- Linux 컨테이너 전체 회귀316개를 실행한 것은 아니다. 백엔드 전체316/11skip은 로컬
  PostgreSQL/Windows 결과, 이번12개는 새 Linux 이미지의 핵심 경로 결과다.
- 스테이징의 실제 Auth/Supabase/R2 통합29절차와 이번 네트워크 차단 컨테이너 검증은
  서로 다른 범위다. 최종 이미지·스키마·작업자·클라우드 ON 조합은 별도 검증해야 한다.
- 사용자 폰·실제 로그인/구매·청취·Windows 서명·정책 결정과 최종 공개 결정은 남겨뒀다.
- Git push·PR·운영 배포·고객 공지·메일은 하지 않았다. Android44 internal 업로드만
  별도 사용자 요청에 따라 완료했다.
