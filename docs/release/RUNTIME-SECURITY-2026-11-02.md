# setuptools · 서버 OS 보안 점검 결과

최신 후속: [OS25종 서비스 영향 검토](OS-IMPACT-REVIEW-2026-11-02.md).
`qa-20261102-osimpact1`에서 터미널 라이브러리 제외·dash 빌드 설정 수정·DNS/로케일
완화를 추가했다. 아래 osfinal2 수치와25종 미검토 상태는 이전 단계의 이력이다.

2026-11-02 KST. 범위는 **서버 Docker 실행 이미지**다.
setuptools 제거, 불필요한 OS 도구 제외, SQLite·zlib 수정과 최종 후보 검증을 마쳤다.
필요한 라이브러리에 남은 공식 미수정 경고는 아래 추적 목록으로 보존했다.
**전체 보안/출시 게이트는 계속 미완료**다.

push·PR·공개 배포·운영 설정 변경 없음. Android 내부 테스트44와 Windows 설치본도
변경하지 않았다. 기존 미커밋 작업은 유지했다.

## 수정한 내용

### setuptools

pyworld 0.3.5의 `pkg_resources` 사용은 버전 문자열 조회뿐이었다. 이 부분을
upstream과 같은 `importlib.metadata.version()`으로 바꾸고 setuptools를 제거했다.
원본 파일 SHA-256을 고정해 다른 코드에는 패치를 적용하지 않으며, 수정 전/후 해시와
installed RECORD를 갱신해 변경 사실을 기록한다. DSP 연산 소스·확장 모듈은 이
메타데이터 패치에서 수정하지 않았다. 전체 실제 합성도 검증했다.

공식 0.3.6에는 Linux/Python3.11용 배포 파일이 없었다. 따라서 0.3.5를 명시적으로
고정하고 좁은 호환 패치를 사용했다. 런타임의 pip·wheel·setuptools·ensurepip·
pkg_resources 부재를 검사한다. Python 설치 목록 **82개**는 최종 목록과 취약점 조회
결과가 정확히 일치하며, pip-audit/Trivy 모두 알려진 Python 경고 **0건**이다.

### 최소 실행 이미지

고정된 공식 Python 빌드 이미지에서 Python·필요한 ELF 의존성·패치한 네이티브
라이브러리·CA·NSS·시간대 데이터를 골라 별도 rootfs를 만들었다. 음성 처리에 필요
없는 apt/curl/mount/nsenter/infocmp/perl 등은 실행 이미지에 넣지 않는다.
운영 SSH 명령과 ctypes 호환용 dash·ldconfig는 유지한다.

원래도 공유 라이브러리가 없어 사용할 수 없던 Numba TBB 플러그인과 Tk GUI 모듈은
제외했다. NumPy/SciPy의 private 라이브러리는 부모 로더의 검색 경로를 고려해
포함했고, 실제 전체 회귀로 확인했다. DB 클라이언트가 동적으로 사용하는 glibc
resolver ABI도 보존했다.

**패키지 버전이나 스캐너 결과를 숨겨 경고를 줄이지 않았다.** 실제 포함한 Debian
파일은 원래 설치 패키지·버전·SHA-256, partial-package 표시와 함께 보존했다.
원본 빌드 status도 남겼다. Debian 식별 파일 누락으로 OS를 인식하지 못했던 초기
결과는 통과로 세지 않았다. 최종 검사는 **Debian13.7 / 실제26개 패키지**로 인식하며
manifest의 이름·개수와 일치한다.

공식 저장소와 비교해 남긴 OS 패키지 **26/26개가 현재 지원 후보 버전과 일치**한다.
비교에서 발견한 tzdata 2026e→2026f 갱신도 반영했다. 호스트 시간대는 변경하지 않았다.

### SQLite와 zlib

- SQLite는 공식 SHA3로 검증한 **3.54.1** 공유 라이브러리를 사용한다.
  FTS5 메모리 오류 공지의 수정 버전을 충족하며, 실제 Python 로드 버전·바이너리
  해시·음수 rowid/prefix/detail=none 검색을 검사했다. `.recover`가 있는 CLI는
  포함하지 않는다. 고객 DB를 열거나 수정한 검사가 아니다.
- zlib **1.3.1**에 공식 commit `ba829a458576d1ff0f26fc7230c6de816d1f6a77`의
  CRC 음수 길이 방어를 역이식했다. 버전을 임의로 바꾸지 않고 패치·원본·해시를
  별도 기록한다. 수정 전 두 함수는 각각 1초 제한에 걸렸고, 소유한 시험 자식
  프로세스를 종료했다. 수정 후 두 함수는 즉시0을 반환했다. gzip 왕복도 통과했다.
- 이후 버전의 `gz_vacate()` 문제를 도입하지 않도록 원본1.3.1에 그 구현이 없음을
  확인했다. Python의 실제 zlib 매핑 경로와 이름 기반 로드도 패치된 바이너리임을
  확인했다. 이는 버전 문자열만 확인한 결과가 아니다.

관련 소스는 `backend/Dockerfile`, `backend/requirements.txt`, `backend/runtime/`다.
대응 소스·패치·빌드 도구·라이선스와 manifest는 최종 이미지의
`/usr/local/share/humtrack-runtime/`에 포함한다. 앞서 수정한 FFmpeg/libsndfile과
음원11개도 유지했다.

## 검증

| 검사 | 결과 |
|---|---|
| 최종 Linux 이미지 전체 백엔드 + 실제 일회성 로컬 PostgreSQL | **335 통과 / 11 skip / 실패0**. skip은 기존 실서비스 시험이며 성공으로 세지 않음 |
| 실제 API·네이티브/런타임 경계 | **30개 통과**, 1GiB/1CPU. WAV/Opus/CAF/M4A/MP3/FLAC/AIFF/AU/WebM, 오토튠·MIDI·Range/해시 포함 |
| Docker healthcheck | Python 표준 라이브러리 방식으로 변경, 실제 **healthy** 확인 |
| DNS·HTTPS | 실제 공개 PyPI endpoint에 stdlib와 httpx 모두 인증서 검증을 켜고200. 운영 키/고객 데이터 사용 없음 |
| 운영 점검 CLI | 같은 `/bin/sh -c 'python -m app.cloud_monitor'` 호출 가능. 키 없는 로컬 환경의 예상 unavailable 결과 확인. 실제 Fly 배포/원격 검증은 별도 |
| 권한·미포함 도구 | UID1000, effective capabilities0. 아래 제외 판정 도구의 실제 부재 확인 |
| 소스/이미지 무결성 | 현재 backend 파일의 SHA-256을 고정·비교. OCI index→manifest→config/layer와 TAR SHA-256 검증 |

API 시험은 기본 10/min 제한을 유지하며 429 후 만료를 기다려 진행했다. DNS/TLS
시험만 자격 증명 없는 공개 endpoint에 연결했고, DB/백엔드 전체 시험은 외부 연결
없는 내부 network와 임시 PostgreSQL을 사용한 후 정리했다. 사람의 소리 판단과
실기기 앱 시험은 여기에 포함하지 않는다.

## 원시 경고와 판정

| 항목 | 직전 native 후보 | 최종 OS 후보 |
|---|---:|---:|
| Debian 패키지 |115|26|
| OS 패키지-공지 행 |298|63|
| 고유 OS CVE |144|35|
| raw Critical / High / Medium / Low |0 / 50 / 95 / 145|0 / 6 / 36 / 21|
| Python 공지 행 |4|0|

한 CVE가 여러 패키지에 반복된다. 63행이 63개의 독립 공격 재현을 뜻하지 않는다.
스캐너 원본은 보존했으며 ignore 목록으로 숨기지 않았다.

### 현재 후보에 해당 실행 도구가 없는 10종

| CVE | 결함이 있는 구성요소 / 확인 |
|---|---|
| CVE-2025-69720 | infocmp의 progs/infocmp.c. infocmp 미포함. raw High가 ncurses 라이브러리2행에 반복됨 |
| CVE-2026-76642 / 78409 / 78410 | mount helper/hook 처리. mount 미포함 |
| CVE-2026-78408 | nsenter의 cgroup 처리. nsenter 미포함 |
| CVE-2026-42250 | bzip2recover 도구 미포함 |
| CVE-2019-1010023 | ldd로 악성 ELF를 조사하는 경로. 실행 이미지에 ldd 미포함. 빌드 단계의 조사 입력은 설치된 신뢰 소스 파일로 제한 |
| CVE-2026-89092 | nscd daemon 미포함 |
| CVE-2022-0563 | chfn/chsh 미포함 |
| CVE-2026-3184 | login -h/PAM 처리. login 미포함 |

**raw High6행(고유5종)은 위의 제외 구성요소에 해당한다.** 라이브러리 버전을
고쳤다고 표현하지 않는다. 실제 파일 부재와 공식 공지의 결함 위치를 대조한
이 후보의 판정이며, 다른 도구를 추가하는 이미지에는 그대로 적용할 수 없다.

### 필요한 라이브러리에 남은 25종

glibc·libstdc++·libtinfo·dash 등에 남은 경고는 공식 Debian trixie 상태와 대조했다.
현재 지원 버전에 제공된 수정이 없으며, `no-dsa/minor` 또는 `unimportant` 등은
벤더 우선순위 정보로 기록했다. 그것만으로 안전하거나 호출 불가능하다고 판정하지
않았다. **앱 입력에서의 도달성을 배제하지 못한 라이브러리 경고는 열린 상태**로 둔다.

개별 CVE·패키지·버전·심각도·벤더 상태·공식 링크는
`artifacts/runtime-security-2026-11-02/os-advisory-disposition.json`의25개
`pending_library_review_or_supported_vendor_fix` 항목에 전부 기록했다.
예를 들어 glibc DNS 공지 중 일부는 일반 resolver 경로가 아닌 deprecated debugging
함수에 대한 공지임도 확인했다. 모든 DNS 호출이 취약하다고 확대 해석하지 않으며,
필요한 libc 전체를 검증 완료로 표시하지도 않는다.

후속은 지원 계열 패치·새 버전과 이 목록의 재대조, 필요한 함수의 앱 실행 경로
검토, 변경 시 동일 이미지 회귀다. 배포 전에 이 잔여 목록과 기타 보안 범위를
검토해야 한다. 전체 A10 체크는 계속 미완료다.

## 최종 후보 / 남은 사용자 확인

- 태그: `humtrack-backend:qa-20261102-osfinal2`.
- 이미지 index digest: `sha256:c4c1d5186844b9017da0d8cceec70c346d74ee3f5174a373f4c1f56af488ae26`.
- TAR: `artifacts/releases/backend-candidate-20261102-osfinal2/humtrack-backend-qa-20261102-osfinal2.tar`.
- 크기: **991,212,032 bytes**.
- SHA-256: `b52371a4035b3e714dc5df0138ab71a52d08143b8f26b9197e23f2157262bbba`.
- 미커밋 파일 포함. `backend-build-receipt.json`의 소스 해시와 함께 관리한다.
  중간 후보와 이전 native 후보는 이번 최종 후보와 구분해 보존했다.

증빙: `artifacts/runtime-security-2026-11-02/`의 `backend-linux-tests.json`,
`container-probe.json`, `runtime-verification.json`, `docker-health.json`,
`dns-tls-smoke.json`, `zlib-loader-proof.json`, `excluded-component-proof.json`,
`supported-os-version-comparison.json`, `python-audit-final-list-match.json`,
`image-vulnerabilities.json`, `debian-vendor-triage.json`.

최종 `verification-receipt.json`에서 현재 백엔드 소스98개와 빌드 시점 해시·파일 목록,
TAR 해시·테스트 이미지 일치를 다시 확인했다. 갱신한 출시 게이트는14/43 완료,
29개 미완료·종료 코드2다(`release-gate.json`). A10은 열린 상태다.

이번 작업에서 사용자가 새로 로그인하거나 키를 등록할 일은 없다. 기존 실제 기기
테스트·청취·로그인/구매·업데이트 보존 확인은 사용자 항목으로 유지했다.
운영 Fly 부팅·원격 CLI·실서비스 왕복은 승인된 배포 단계에서 동일 후보로 확인해야
한다. 현재 요청대로 push·PR·공개 배포는 진행하지 않는다.

공식 근거:

- [pyworld upstream 메타데이터 API](https://github.com/JeremyCCHsu/Python-Wrapper-for-World-Vocoder/blob/master/pyworld/__init__.py), [공식 배포 파일](https://pypi.org/project/pyworld/)
- [SQLite3.54.1 및 공식 SHA3](https://sqlite.org/download.html)
- [zlib CRC 공지·공식 수정](https://security-tracker.debian.org/tracker/CVE-2026-27171), [zlib 공식 변경 내역](https://zlib.net/)
- [infocmp 결함 위치](https://security-tracker.debian.org/tracker/CVE-2025-69720), [mount hook 공지](https://security-tracker.debian.org/tracker/CVE-2026-76642)
- [glibc DNS debugging 함수 공지](https://security-tracker.debian.org/tracker/CVE-2026-6238), [Debian 공개 보안 상태](https://security-tracker.debian.org/tracker/)
