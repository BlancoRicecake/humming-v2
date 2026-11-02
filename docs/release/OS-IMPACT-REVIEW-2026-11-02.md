# 남은 OS 경고25종 — 서비스 영향 검토와 로컬 수정

2026-11-02 KST. 이전 `qa-20261102-osfinal2`의 미검토25종을 대상으로 했다.
최신 후보는 **`humtrack-backend:qa-20261102-osimpact1`**이다. 운영 서버는 바꾸지 않았다.
push·PR·공개 배포 없음. Android 내부 테스트44·Windows 설치본·사용자의 앱 작업도 변경하지 않았다.

## 결과

| 판정 | 수 | 의미 |
|---|---:|---|
| 빌드 설정 수정 / 불필요한 구성요소 제거 | 2 | dash 재귀 fallback 제외, ncurses/tinfo 제거 |
| 서비스 구성으로 완화 | 2 | DNS 검색 도메인, gettext 로케일 경로. glibc 자체 패치라는 뜻은 아님 |
| 현재 구현·조건·검토한 서비스 입력 경로에서 영향 조건을 찾지 못함 | 17 | 구현 차이3, 필수 조건 부재4, 서비스 입력 경로 미발견10. 아래 범위와 한계가 적용됨 |
| 조건부 잔여 항목 | 4 | 네이티브 PBDS 헤더 코드1, 방어기법 우회 관련 벤더 비보안 분류3 |

**전체 보안 검토 A10과 출시 판정은 계속 미완료다.** 정적 분석·회귀 테스트가 모든
동적 호출이나 네이티브 메모리 안전성을 증명하지는 않는다. 경고를 ignore 파일로
숨기거나 패키지 버전을 수정된 것처럼 바꾸지 않았다.

## 실제로 바꾼 것

1. Python의 사용하지 않는 `_curses`, `_curses_panel`, `readline` 확장을 제외했다.
   이 확장들만 필요로 하던 ncurses/tinfo/readline 라이브러리도 의존성 폐쇄에서 빠진다.
   이전 이미지에서 `tsearch/tdelete`를 직접 참조하던 ncurses/tinfo도 함께 빠졌다.
   API·허밍 분석·운영자 `/bin/sh` 명령은 유지하고 검증했다.
2. dash는 **동일 Debian0.5.12-12 소스와 패치**로 다시 빌드하되, Debian 기본값인
   `--disable-fnmatch` 대신 **`--enable-fnmatch`**를 쓴다. 재귀 `pmatch` fallback이
   컴파일되지 않으며 실제 바이너리가 libc `fnmatch`를 참조함을 확인했다.
   `--disable-glob`, `--disable-lineno`와 기존 Debian 패치는 유지했다.
   복잡한 다중 별표 패턴도2초 안에 끝난다. 원본·패치 체크섬, 소스, 라이선스와
   빌드 기록은 이미지의 `/usr/local/share/humtrack-runtime/`에 보관한다.
3. 최종 이미지에 `LOCALDOMAIN=""`을 설정했다. glibc 구현에서 이 값은
   `/etc/resolv.conf`의 `search/domain` 접미사 설정을 덮어쓴다. nameserver와 직접
   DNS 조회는 계속 사용한다. 이 서비스는 Supabase/R2 등 구성된 호스트를 직접 조회한다.
   DNS 검색 접미사에 의존하는 새 서비스나 운영 설정을 추가하면 다시 검토해야 한다.
4. `LC_ALL=C.UTF-8`, `LANGUAGE=""`로 서버 로케일을 고정했다. 추가 로케일과
   메시지 카탈로그는 포함하지 않는다. HTTP 입력이 환경변수를 설정하는 경로는 없다.

DNS 문제는 이전 이미지에서304자 검색 도메인을 넣은 **읽기 전용 QA resolv.conf**로
실제 프로세스 종료를 재현했다. 동일 설정을 새 후보에 넣으면 `__res_init`이 성공한다.
각 컨테이너는 외부 네트워크 차단·메모리 제한·core dump 비활성 상태였으며 고객 데이터는 사용하지 않았다.

기존 libc/libstdc++를 다른 배포판이나 비호환 버전으로 교체하지 않았다. DNS·gettext는
**현재 배포 구성에 대한 완화**이며, 운영에서 해당 환경변수를 덮어쓰면 판정을 재검토해야 한다.
[DNS 공식 공지](https://security-tracker.debian.org/tracker/CVE-2026-8674),
[gettext 공식 공지](https://security-tracker.debian.org/tracker/CVE-2026-84243).

## 25종 전체 판정

공통 증빙은 `artifacts/os-impact-2026-11-02/`에 있다. `elf-audit-final.json`은
정확한 최종 이미지의 ELF348개를 심볼·해시와 함께 조사한 결과다. 서버 Python43개 파일의
관련 호출30곳과 소스 해시도 `service-path-review.json`에 기록했다.

| CVE | 현재 서비스에 대한 판정 / 근거 |
|---|---|
| [2026-102473](https://security-tracker.debian.org/tracker/CVE-2026-102473) | 수정: dash 재귀 fallback 대신 libc fnmatch 사용. 실제 ELF 참조·제한시간 내 패턴 검사 통과 |
| [2026-102474](https://security-tracker.debian.org/tracker/CVE-2026-102474) | 구현 조건 부재: 고정한0.5.12+Debian 패치에는 문제의 Unicode escape 변환 분기가 없다. 실제 `printf %b`도 `\u`/`\U`를 변환하지 않음 |
| [2025-6141](https://security-tracker.debian.org/tracker/CVE-2025-6141) | 제거: 사용하지 않는 터미널 확장과 ncurses/tinfo termcap parser가 최종 이미지에 없음 |
| [2026-8674](https://security-tracker.debian.org/tracker/CVE-2026-8674) | 완화: 긴 검색 도메인 assertion을 실제 재현했고 `LOCALDOMAIN=""` 적용 후 동일 입력 성공. 일반 DNS/TLS도 성공 |
| [2026-84243](https://security-tracker.debian.org/tracker/CVE-2026-84243) | 완화: C.UTF-8 로케일·빈 LANGUAGE, 추가 로케일 부재. 사용자 입력을 프로세스 환경으로 내보내는 경로 없음 |
| [2026-86805](https://security-tracker.debian.org/tracker/CVE-2026-86805) | 필수 조건 부재: SUID/SGID 파일0, 서비스 AT_SECURE0·UID1000·capabilities0. 권한 상승용 loader 조건 없음 |
| [2026-95818](https://security-tracker.debian.org/tracker/CVE-2026-95818) | 필수 조건 부재: 동일한 privileged/AT_SECURE loader 조건 없음 |
| [2026-77117](https://security-tracker.debian.org/tracker/CVE-2026-77117) | 필수 조건 부재: glibc SHIFT_JISX0213 gconv 모듈 없음. 실제 `iconv_open`이 EINVAL을 반환 |
| [2026-80489](https://security-tracker.debian.org/tracker/CVE-2026-80489) | 필수 조건 부재: EUC-JISX0213 gconv 모듈 없음. 실제 변환기 열기 실패 확인 |
| [2026-97399](https://security-tracker.debian.org/tracker/CVE-2026-97399) | 구현 조건 부재: Power8 전용 공지. 이 후보는 Linux x86_64/amd64. 다른 CPU 빌드로 판정 전용 금지 |
| [2026-95619](https://security-tracker.debian.org/tracker/CVE-2026-95619) | 구현 조건 부재: 실제 Linux libstdc++는 posix_memalign 경로 사용. 동일 바이너리가 공식 overflow 입력9개를 모두 거부하고 정상 정렬 할당 성공 |
| [2026-18374](https://security-tracker.debian.org/tracker/CVE-2026-18374) | 입력 경로 미발견: 공격자가 fopen의 파일명뿐 아니라 MODE의 `,ccs=`를 제어해야 함. 현재 서비스 파일 모드는 고정값이며 음원은 bytes/virtual IO 또는 생성한 임시 경로로 전달. 모든 외부 native 내부 경로의 완전한 증명은 아님 |
| [2026-19499](https://security-tracker.debian.org/tracker/CVE-2026-19499) | 입력 경로 미발견: strfmon/strfmon_l 외부 참조 없음. 금액 네이티브 포맷 API 없음 |
| [2026-19542](https://security-tracker.debian.org/tracker/CVE-2026-19542) | 입력 경로 미발견: tsearch/tdelete를 직접 참조하던 ncurses/tinfo 제거 후 외부 참조0. API는 백만 노드 수준 libc 트리를 만들고 지우는 기능을 노출하지 않음. libc 자체 패치는 아님 |
| [2026-5435](https://security-tracker.debian.org/tracker/CVE-2026-5435) | 입력 경로 미발견: ns_printrr/ns_printrrf/fp_nquery 디버그 출력 함수 참조0. 일반 DNS 조회와 다른 코드 |
| [2026-6238](https://security-tracker.debian.org/tracker/CVE-2026-6238) | 입력 경로 미발견: 같은 deprecated DNS 디버그 출력 경로. 일반 resolver가 해당 함수를 호출한다는 근거 없음 |
| [2026-6368](https://security-tracker.debian.org/tracker/CVE-2026-6368) | 입력 경로 미발견: wordexp/wordfree 외부 참조0. FFmpeg는 셸을 거치지 않는 인자 목록으로 실행 |
| [2026-6791](https://security-tracker.debian.org/tracker/CVE-2026-6791) | 입력 경로 미발견: libc wordexp의 tilde 확장에 요청 값을 넘기는 경로 없음 |
| [2010-4756](https://security-tracker.debian.org/tracker/CVE-2010-4756) | 입력 경로 미발견: libc glob(3)에 사용자 패턴을 넘기는 API 없음. Python pathlib/glob은 별도 구현이며 dash의 libc glob 사용도 비활성 |
| [2018-20796](https://security-tracker.debian.org/tracker/CVE-2018-20796) | 입력 경로 미발견: regcomp/regexec 외부 참조0, POSIX regex 요청 API 없음. Python re는 다른 엔진 |
| [2019-9192](https://security-tracker.debian.org/tracker/CVE-2019-9192) | 입력 경로 미발견: 같은 glibc POSIX regex 조건. 벤더 논쟁만으로 수정 완료라 표시하지 않음 |
| [2026-102010](https://security-tracker.debian.org/tracker/CVE-2026-102010) | 잔여 추적: 수정은 PBDS binary_heap erase_if 헤더에 있음. 파일·심볼 문자열 흔적은 없지만 완전 인라인 코드는 흔적이 없을 수 있어 prebuilt wheel/LLVM 등 전체를 배제했다고 판정하지 않음 |
| [2019-1010022](https://security-tracker.debian.org/tracker/CVE-2019-1010022) | 잔여 위협 모델: stack guard 우회. 벤더 비보안 분류, 별도 메모리 오류가 있어야 악용. 패치/완전 무해 판정은 하지 않음 |
| [2019-1010024](https://security-tracker.debian.org/tracker/CVE-2019-1010024) | 잔여 위협 모델: 스레드 스택·힙 재사용과 ASLR. 벤더 비보안 분류, 다른 정보 유출/메모리 오류와의 결합 검토 필요 |
| [2019-1010025](https://security-tracker.debian.org/tracker/CVE-2019-1010025) | 잔여 위협 모델: 스레드 힙 주소 추정. 벤더는 ASLR 우회 단독을 취약점으로 보지 않음. 주소 노출 경로 전체를 증명한 것은 아님 |

### 판정 한계와 다음 검토

- **입력 경로 미발견10종은 라이브러리 패치 완료라는 뜻이 아니다.** ELF 심볼 참조,
  검토한 Python 코드와 현재 허용 API를 대조한 범위의 판정이다. dlsym·FFI·JIT·정적 인라인
  코드까지 정적 참조만으로 전부 증명할 수 없다. 기능/의존성 변경 시 다시 검토한다.
- C++ PBDS 항목은 libstdc++ DSO만 교체해도 이미 컴파일된 템플릿이 고쳐지지 않는다.
  현재 공급된 wheel·LLVM의 빌드 소스/옵션 대조가 추가 근거다. 임의의 ABI 교체로 닫지 않는다.
  [공식 헤더 수정](https://gcc.gnu.org/git/?p=gcc.git;a=commit;h=aaa8351f4d2e636f9680a1f0a8ebc2f0a60611e6).
- 나머지3종은 upstream 비보안 분류 사실과 서비스의 별도 메모리 오류·정보 유출 위협을
  구분해 잔여 목록에 둔다. 스택 가드/ASLR을 끄거나 스캐너 경고를 숨기지 않는다.
- 새 배포 환경의 locale/LOCALDOMAIN 덮어쓰기, 새 native 모듈·CPU·gconv·privileged 실행 파일·
  사용자 지정 셸/패턴 기능이 생기면 현재 판정을 다시 적용하지 않는다.

## 동일 최종 후보의 검증

- Linux 백엔드: **335 통과 / 11 건너뜀**, 실제 격리 PostgreSQL 포함.
- 실제 API: **30개 통과**, 허밍 분석·오토튠·MIDI·음원 Range/해시·다양한 음원 형식 포함.
- 이미지 health **healthy**, 인증서 검증을 켠 DNS/TLS 통과. 운영자 cloud monitor CLI도
  자격 증명이 없는 상태에서 예상한 aggregate 오류 응답까지 정상 실행.
- ELF348개, 서비스 소스43개/관련 호출30곳 조사. SUID/SGID0·AT_SECURE0·capabilities0 확인.
- 제거된 glibc 변환기는 실제 iconv_open으로 검사. fnmatch 연결·제한 시간 회귀·긴 DNS 설정 회귀 통과.
- 정확한 최종 libstdc++의 aligned-new 함수를 역어셈블해 `posix_memalign` 호출도 확인했다
  (`cpp-disassembly-proof.json`, 원본 바이너리 SHA256 일치).
- 최종 Python 패키지82개를 다시 조회: 알려진 취약점 **0**, 설치 목록과 audit 목록 정확히 일치.
- 남긴 Debian 패키지22개는 이날 확인한 지원 버전 snapshot과 모두 일치한다.

### 스캐너 원본과 커스텀 셸을 구분

| 기준 | 이전 osfinal2 | 이번 osimpact1 |
|---|---:|---:|
| 실제 남긴 Debian 패키지 | 26 | 22 |
| OS 원시 경고 행 / 고유 CVE | 63 / 35 | **57 / 31** |
| 원시 Critical / High / Medium / Low 행 | 0 / 6 / 36 / 21 | **0 / 4 / 36 / 17** |
| Python 알려진 취약점 | 0 | **0** |

원시 High4행은 여전히 포함되지 않은 mount/nsenter 명령 관련 공지다. 이전 부재 증명도
최종 이미지에서 재확인했다. 전체 raw57행은 그대로 보존했다.

**커스텀 dash는 Debian 설치 패키지로 가장하지 않는다.** 원본 Debian dash 패키지의 실행
파일은 남기지 않았고, 같은 검증된 소스로 빌드한 바이너리·설정·해시를 `dash.json`으로
별도 보관한다. 스캐너의 dpkg 경고 감소만으로 해당2종을 닫지 않고 위 표에서 직접 조사했다.
따라서 raw57만이 이미지의 모든 커스텀 컴포넌트 평가를 대신하지 않는다.

## 후보와 사용자에게 남긴 일

- 태그: `humtrack-backend:qa-20261102-osimpact1`.
- index digest: `sha256:78d22ae6ffa6cdff6a4c490c2983a4639a188b62e26715f277d2bc4ae82b0b3c`.
- TAR: `artifacts/releases/backend-candidate-20261102-osimpact1/humtrack-backend-qa-20261102-osimpact1.tar`.
- 크기990,870,016 bytes, SHA256 `272b805dcd5bae7b711c4d4e1fcda409f8b1435e2241fa5720fb76a608d366c5`.
- 미커밋 소스의 해시·실제 빌드 이미지·TAR/레이어 해시를 함께 보관했다. 이전 후보는 보존했다.

상세 기계 판독 기록은 `os-impact-assessment.json`의25개 항목과
`service-path-review.json`, `elf-audit-final.json`, `preconditions-final.json`,
`dns-search-before-mitigation.json`, `implementation-preconditions-before.json`,
`cpp-probe-final-binary-match.json`, `cpp-disassembly-proof.json`, `runtime-verification.json`, `verification-receipt.json`이다.
공식 원문25개와 소스/패치·다운로드 해시도 같은 QA 폴더의 `primary/`에 보관했다.

이번 작업을 위해 사용자가 새로 로그인하거나 키를 등록할 일은 없다. 기존 실제 기기
앱 테스트·청취·로그인/구매·업데이트 보존 확인은 사용자 항목으로 유지한다.
운영 Fly에서 동일 후보의 부팅·DNS·외부 서비스 왕복은 향후 승인된 배포 단계에서 확인한다.
현재 요청대로 실제 운영 배포나 공개는 하지 않았다.
