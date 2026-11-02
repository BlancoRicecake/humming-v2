# HumTrack 앱 업데이트 · Windows 첫 출시 체크리스트

기준일: 2026-11-02 KST 갱신. **현재 판정: 출시 보류.**
11/03 사이트 배포 후속: 공지/관리자 페이지·현재 홈페이지를 기존 Vercel에 공개했다.
14개 경로·파일 해시·관리자 noindex/no-store·공개 피드0건 확인. 앱/백엔드/Windows 배포나
공지 게시는 하지 않았다. [사이트 배포 기록](SITE-DEPLOY-2026-11-03.md).

사용자 결정: Windows는 다운로드 후 설치하는 프로그램으로 제공하고 추가 음원은
앱 안에서 필요할 때 받는다. 클라우드 백업도 검증을 마친 뒤 이번 출시에 포함한다.

각 필수 항목은 **코드가 있음 / 로컬 검증 / 실제 서비스·기기 검증**을 구분한다.
아래 필수 체크박스를 모두 완료하고 같은 최종 커밋·설정·바이너리로 확인한 뒤 출시한다.
11/01 운영 DB에는 기존 클라우드 RPC 2개의 클라이언트 실행 권한을 회수하는 migration007만 적용했다.
사용자 후속 요청으로 Android1.0.14(44)를 **내부 테스트에만 업로드**했다. production39는 유지했다.
전체 클라우드 migration·서버 배포·고객 공지·메일·정식 스토어 출시는 실행하지 않았다.
11/02 사용자 별도 승인으로 **공지005·공지관리자006**과 관리자 Redirect URL을 운영에 적용했다.
확인 true/true/2/0, 공개 피드200·0건/관리자 목록401. 공지 생성·게시·웹 배포 없음.
`006_cloud_lifecycle.sql` 적용과 구분하며 [공지 운영 적용 기록](ANNOUNCEMENTS-PRODUCTION-2026-11-02.md)을 따른다.
최신 실제 서비스 검증과 적용 범위는 [STAGING-VERIFICATION-2026-11-01.md](STAGING-VERIFICATION-2026-11-01.md)를 따른다.
후속 로컬 Docker 복구·음원 포함 이미지·격리12항목 검증은
[LOCAL-BACKEND-CANDIDATE-2026-11-01.md](LOCAL-BACKEND-CANDIDATE-2026-11-01.md)를 따른다.
11/02의 관리자 점검008·실제 스테이징 예약 실행/잔여 정리·새 로컬 후보는
[RELEASE-OPS-2026-11-02.md](RELEASE-OPS-2026-11-02.md)를 따른다. 앱 실기기 검증은 사용자 진행 중이다.
11/02 보안 점검은 [SECURITY-REVIEW-2026-11-02.md](SECURITY-REVIEW-2026-11-02.md)를 따른다.
JWT 오류·디코더 로그 노출은 로컬 수정했으며 새 후보 17항목을 통과했다.
후속 [네이티브 수정 결과](NATIVE-AUDIO-SECURITY-2026-11-02.md): FFmpeg CAF·실제 로드되는
libsndfile WAV 문제를 새 로컬 후보에서 해결했다. Linux335/11·API29·upstream143·UBSan3 통과.
최신 [setuptools·OS 점검 결과](RUNTIME-SECURITY-2026-11-02.md): setuptools/pip/wheel 제거,
SQLite·zlib 수정과 최소 런타임 검증을 마쳤다. 최종 `qa-20261102-osfinal2`는 Linux335/11·API30 통과,
Python 알려진 취약점0이다. OS 원시63행·35종 중 영향받는 명령 미포함10종을 증명했으며,
필요한 라이브러리25종은 공식 수정/추가 검토 대상으로 남아 있다. 전체 보안 게이트는 미완료다.
후속 [OS25종 서비스 영향 검토](OS-IMPACT-REVIEW-2026-11-02.md): 최신 `qa-20261102-osimpact1`에서
수정/제거2·구성 완화2·조건/입력 경로 미발견17·조건부 잔여 추적4로 조사했다.
Linux335/11·API30·Python 취약점0, raw OS57행·31종은 보존했다. 라이브러리 전체 수정 판정은 아니다.
이전 backend-candidate-20261102는 보안 수정 전 이력이며 공개 배포 후보로 사용하지 않는다.

## 1. 지금 먼저 해결할 출시 차단 항목

| ID | 병목과 확인 근거 | 완료 조건 | 담당 |
|---|---|---|---|
| S1 | FFmpeg·libsndfile·SQLite·zlib 로컬 수정, setuptools 제거 완료. 최신 osimpact1은 터미널 라이브러리 제외·fnmatch 셸·DNS/로케일 완화 추가. Linux335/11·API30 통과. 남은25종 영향 검토 완료, 조건부 잔여4와 입력 경로 미발견 판정의 한계 기록. 운영은 수정 전 | A10 잔여 네이티브/위협 모델 검토, 경로 판정 범위 확인과 승인 후 운영 반영·검증. OS-IMPACT-REVIEW 참조 | 운영 + 잔여 보안 |
| C1 | 영속 큐·유한한 임대·주기적 정리를 구현하고 로컬 경쟁·중단·복구 검사를 통과했다. 운영 작업자는 아직 꺼져 있음 | migration006 적용 후 실제 작업자·재시도·관측 확인 | 실제 서비스 |
| C2 | Auth cascade 이후에도 살아남는 탈퇴 기록과 늦은 PUT 정리 구현. 앱은 삭제 진행을 안내한다 | 실제 Auth 트리거 권한·삭제 재시도·만료 후 재검사·완료 증빙 확인. 최소 기록 보관 기간 확정 | 실제 서비스 + 정책 |
| C3 | 기존 실서비스 테스트11개는 옛 계약이라 **무조건 skip**. 새 검증기는 실제 스테이징 Supabase/Auth/R2·현재 API에서29절차 통과. 비구독자 차단·탈퇴202도 확인 | 실제 구매/만료·두 네이티브 기기·한도·응답 유실·운영 작업자는 추가 확인 | 기기 + 운영 검증 |
| C4 | 기존 스테이징 권한·R2·공지 검증 통과. 운영은007 보안 수정과 공지005·공지관리자006 적용, 공지0건 유지 | 운영 클라우드 migration003/004/006_cloud_lifecycle/008과 작업자·배포 후 검증 필요. 공지관리자006과 구분 | 운영 검증 |
| P1 | 앱 내/웹 약관과 개인정보처리방침이 “기기에만 저장, 클라우드에 보관하지 않음”이라고 명시 | 선택적 클라우드 저장, 녹음 포함 선택, 수탁자·위치·보관·탈퇴·만료 후 접근을 실제 구현과 일치시키고 기존 문서의 개정 고지 절차/일정을 확인 | 운영자 문구 승인 + 구현 |
| W1 | 기존 Windows 실행본은 공개 설정 없이도 만들어지고, 설치·서명 경로가 없었음 | 설정 검증/빌드 증빙/설치 후보는 이번에 준비. 서명과 깨끗한 PC 검증을 추가 완료 | Codex + 서명 자격 |
| W2 | Windows 브라우저 OAuth 콜백을 기존 앱으로 전달하는 코드와 설치 등록이 빠져 있었음 | 전달 코드·프로토콜 설치는 준비. 실제 Google/Apple 로그인 → 원래 창·세션 복구 → 재시작 유지 | 실제 계정 검증 |
| R1 | Android·Apple 최고 업로드43/1.0.13 확인. 새 후보1.0.14+44 선정. Apple 유료 계약 활성 확인 | 최종 커밋에서 서명 IPA/AAB 빌드·기기 설치 검사 | Mac/CI + 기기 |
| R3 | 운영은 실제.sf2 파일0개. 음원11개 포함 로컬 이미지 빌드와1CPU/1GB 격리12검사 통과, Docker 소켓 오류 복구 | 운영 이미지 교체 후 실제 앱 다운로드·재시작 이어받기·공간 부족 검증 필요 | 배포 보류 + 기기 검증 |
| R2 | 소스·DB·백엔드·앱을 함께 고정한 출시 후보가 없음 | 최종 커밋, 환경, 스키마, 버전·빌드, SHA-256, 검증 기록을 동결하고 동일 후보로 실기기 검증 | Codex + 운영자 |

### 주의할 일정

현재 `mobile/assets/legal/privacy.md`는 Firebase 고지용 **초안**이고 예정 시행일은
2026-11-01이다. 이 날짜가 클라우드 고지까지 완료했다는 뜻은 아니다.
기존 문서에는 중대한 변경의 사전 공지 절차가 있으며, 실제 게시·발송 이력과 필요한
일정을 확인해야 한다. 이번에 고객에게 공지나 메일을 보내지 않았다.

## 2. 필수 체크리스트 — 모두 완료해야 출시

### A. 후보·빌드·회귀

- [x] A01 출시 범위 결정: 앱 업데이트 + Windows 설치 프로그램 + 검증 후 클라우드 공개.
- [ ] A02 최종 커밋·소스·공개 설정·서버 스키마를 동결한다. 현재 준비 수정은 아직 미커밋이다.
- [x] A03 Android·ASC 기준 최고43에서 **1.0.14+44**를 선정했다. 후속 Android 내부 업로드로44가 소비됐다. pubspec44는 해당 테스트본 식별자로 유지하며 다음 변경 후보는45 이상을 사용한다. Apple 최고는43이었다.
- [x] A04 11/01 Android 내부 후보 직전 Flutter analyze0건, 전체 **1052 통과 / 19 건너뜀 / 실패0** 재확인. `artifacts/android-internal-2026-11-01/` 증거. 건너뛴 검사는 실기기 완료로 세지 않는다.
- [x] A05 백엔드 전체 **335 통과 / 11 건너뜀 / 실패0**, 최종 `qa-20261102-osimpact1`·실제 로컬 PostgreSQL 포함. 보안 경계 신규10개 포함. 별도 실제 Supabase/R2 예약 실행·통합 증거와 구분한다.
- [x] A06 Android ARM64 디버그 APK 컴파일 성공. 77개 .so를 열어 64비트 ELF/비압축 APK 16KB 정렬 검사 통과.
- [ ] A07 서명1.0.14(44) AAB의 패키지/버전·원본 키·target36·64비트16KB ELF 검사 및 internal 업로드/재조회 완료. **사용자 기기 설치와 Play split APK 실행은 미확인.** 클라우드 ON 최종 후보는 새 번호로 다시 검사한다. [Android 내부 테스트](ANDROID-INTERNAL-TEST-2026-11-01.md) 참조.
- [ ] A08 최종 **서명 IPA/TestFlight**를 만들고 Firebase+Google plist 7키 검증, cold start, 백그라운드 복귀를 실제 iPhone/iPad에서 확인한다.
- [ ] A09 develop/main CI 및 새 Windows 네이티브 CI가 최종 커밋에서 통과한다. 워크플로 수정은 로컬에 준비했으며 원격 실행은 아직이다.
- [ ] A10 조건부 잔여4종(PBDS 헤더/컴파일 코드1·벤더 비보안 분류 방어기법 우회3), 입력 경로 미발견10종의 판정 한계와 기타 보안 범위를 검토한다. 이전 미검토25종은 수정/제거2·구성 완화2·조건/경로 미발견17·잔여4로 조사했다. 최신 osimpact1 Linux335개·API30개·DNS/TLS·상태 검사 통과, Python 취약점0. raw OS57행·31종과 커스텀 dash 별도 검토를 보존했다. 라이브러리 전체 수정/전체 보안 완료 판정은 아니다.

### B. 저장·소리·로그인·구독

- [x] B01 이전 검증에서 로컬 저장/닫기/복구, .humtrack 왕복, MIDI/WAV/stems, 계정 격리 회귀 통과. `docs/specs/ui/storage-audit-2026-10-30.md` 참조.
- [ ] B02 기존 스토어 앱 위 업데이트 설치: 실제 기존 곡/녹음/설정 보존, 예전 .bak 복원, 새 버전에서 만든 작업물의 안전한 처리 확인. 데이터가 있는 기기를 초기화하지 않는다.
- [ ] B03 Android/iPhone/Windows에서 허밍 녹음 → 서버 변환 → 노트 확인 → 악기/보컬 재생 → 저장·재실행 → WAV/MIDI 내보내기. 소리·지연은 사용자 청취 확인을 포함한다.
- [ ] B04 마이크 거부·해제, 입력/출력 장치 변경, 오프라인·서버 오류, 디스크 부족에서 작업물 보존과 재시도 안내를 확인한다.
- [ ] B05 실제 Google/Apple 로그인·취소·로그아웃·계정 전환·재시작 후 세션 복구를 확인한다. Windows 설치 후 브라우저 복귀를 포함한다.
- [x] B06 Windows에서는 모바일 구독 가격/결제 버튼 대신 휴대폰 구독 안내와 **서버 Pro 상태 확인**을 제공하도록 수정. 기존 모바일 복원 흐름과 추가 회귀 테스트 통과.
- [ ] B07 실제 테스트 구매/복원/만료/취소·계정 전환, 폰에서 구독한 같은 계정의 Windows Pro 판정을 확인한다. 권한 우회/로컬 강제 Pro를 쓰지 않는다.
- [ ] B08 과거 스토어 알림 장애의 최신 상태와 App Store 알림/Play RTDN → 서버 권한 갱신을 확인한다. 10/30 GitHub IAP 모니터 성공은 확인했으나 이번 실제 거래를 확인한 것은 아니다.

### C. 클라우드 — 이번 출시 필수

- [x] C01 고아 스윕·잔여 삭제 재시도 및 계정 탈퇴 작업의 로컬 구현·검증 완료. 정상 사본·진행 중 커밋 보호, 유한 임대, Auth cascade·지연 PUT·다중 작업자 검사 포함. 운영 적용은 C02~C05/E04에 남아 있다.
- [ ] C02 스테이징003–008, 권한24/24·공개 키 REST11/11·실제60초 예약 루프2회·유예 후 잔여 lease 정리 검증 완료. 운영은007·공지005·공지관리자006 적용. 클라우드006 수명주기 등 전체 운영 migration과 상시 작업자 활성화/실행은 미완료.
- [ ] C03 현재 서버 소스의 배포 후보를 검증하고 `/storage/usage` contract 1 및 권한·용량 계산 확인. 운영 내부 health/구독 알림200, 실제 클라우드 행0·R2 vocals 객체0 확인. 기본 Python 조회의Cloudflare1010과 달리 Dart/HumTrack 식별 요청은200이며 앱 접속 장애로 단정하지 않는다.
- [ ] C04 실제 R2에서 서명 길이·조건부 PUT/재사용412·Copy/해시·삭제 응답·정리8절차 통과. 공급자 부분 삭제 실패의 실제 장애 재현은 미완료(로컬 대역 테스트 있음). 서비스 키는 앱/설치 파일에 넣지 않는다.
- [ ] C05 실제 스테이징 Auth+현재 API+R2 contract 1의29절차·SHA-256·계정 격리·오래된 커밋409/기존 사본 보존 통과. 실제 앱 가져오기·두 기기·한도 초과·중단/응답 유실 추가 확인 필요. 시험용 Pro 행은 실제 구매 검증이 아님.
- [ ] C06 폰 → Windows → 폰 실제 왕복: 노트/녹음/원본·효과 음원 보존. 복원은 새 로컬 곡, 클라우드 사본 삭제는 로컬 곡을 보존.
- [ ] C07 구독 만료 후에도 기존 클라우드 사본 목록·복원·삭제 가능, 업로드만 제한되는지 실제 계정으로 확인.
- [ ] C08 개인정보·약관·앱 설명·동의 및 녹음 포함 선택이 일치하고 개정 고지 절차/일정이 완료됐다는 증빙 확보. 실제 저장 지역과 탈퇴 최소 기록의 보관 기간 확정 필요. 사실표·KO/EN 안내 초안만 준비했으며 활성 고지는 변경하지 않았다.
- [x] C09 **긴급 읽기 전용 모드** 구현·검증: `CLOUD_BACKUP_WRITES_ENABLED=false`는 새 업로드/커밋만 503으로 중단하고 목록·사용량·복원 URL·삭제는 유지한다. 전체 `CLOUD_SYNC_ENABLED=false`는 모든 경로를 감추므로 운영 장애 대응에 혼동하지 않는다.
- [ ] C10 위 검증 완료 후 최종 앱 `HUMTRACK_CLOUD_BACKUP=true`, 서버 `CLOUD_SYNC_ENABLED=true`를 적용한 동일 후보로 재검증. 현재 Windows 내부 후보는 클라우드 OFF다.

### D. Windows 설치·리소스·배포

- [x] D01 공개 설정을 검증한 main.dart Release 빌드 성공. 잘못된 관리자 키/QA 엔트리/증빙 불일치를 패키징에서 거부하도록 준비.
- [x] D02 재사용 build 폴더의 옛 사용법·.lib/.exp·임의 실행 파일을 패키지에서 제외. 공식 VC143 x64 CRT와 Flutter data·플러그인 포함, 파일별 SHA-256 기록.
- [x] D03 Windows **1.0.14+44** 설치 후보 생성. `artifacts/releases/candidate-1.0.14-44-20261101/`에 보관하며 이전 후보와 `artifacts/releases/current`는 유지한다. **클라우드 OFF·서명 전 내부 검증본**이다.
- [x] D04 별도 QA ID/프로토콜로 한글·공백 경로 설치 → 재설치 → 제거, 검증용 사용자 파일 바이트 보존 및 실제 HumTrack 프로토콜 불변 검증. `installer-qa/result.json`. 실제 기존 사용자 데이터나 깨끗한 PC 검증으로 확대 해석하지 않는다.
- [ ] D05 Authenticode 서명과 타임스탬프, 공개 게시자명, 설치/실행 파일 체인 확인. 현재 실행 파일·설치 후보는 미서명이다.
- [ ] D06 개발 도구/기존 VC 런타임 없는 깨끗한 Windows 11 x64 일반 사용자 환경에서 설치·첫 실행·재부팅·업데이트·제거·프로토콜 확인. Windows 10을 지원 표기하려면 해당 환경도 검증한다.
- [ ] D07 번들8개 오프라인 합성·캐시 복구/이어받기 회귀 통과. 서버 후보 이미지에 음원11개 포함, 실제 로컬 HTTP206/416·다운로드 해시 일치 통과. 운영 음원0개 문제의 배포 수정과 실제 앱 추가 다운로드·공간 부족·재시작은 남음.
- [ ] D08 다운로드 페이지에 설치 exe, 버전/요구 OS/파일 크기·SHA-256/릴리스 노트·문의 주소 제공. 새 설치 파일을 다시 받아 업데이트하는 절차와 작업물 보존 확인. 자동 업데이트는 구현·검증 없이 약속하지 않는다.
- [ ] D09 GeneralUser GS 공식 원문과 제작자 고지를 앱에 추가했고, 설치 폴더의 읽을 수 있는 THIRD-PARTY-NOTICES.txt에 Flutter/패키지·추가 원문 포함을 검증했다. 기존 음원은 내장 이름2.0.3 BETA 그대로 유지. 전체 음원/네이티브 의존성·CRT 배포 조건 최종 검토는 남음.

### E. 공지·오류 수신·출시 운영

- [x] E01 스테이징005 공개 피드5항목 및 운영 공지005·공지관리자006·Redirect URL 적용 검증 완료. 11/03 웹 사이트 배포, 공개 피드200·0건/관리자 목록401 및 보안 헤더 확인. 공지 게시·실제 관리자 로그인/초안 저장·앱 표시 검증은 미실행.
- [ ] E02 내부 대상 공지로 실행 시 표시·확인 후 재실행·revision·회수·오프라인·편집 중 비방해를 실제 앱/프로그램에서 확인. 샘플을 전체 고객에게 게시하지 않는다.
- [ ] E03 최종 Android/iOS/Windows 빌드에서 통제된 시험 오류가 Sentry 해당 프로젝트·버전·환경으로 도착하는지 event ID와 시각 기록. DSN 유효성 검사만으로 수신 완료로 세지 않는다.
- [ ] E04 관리자 전용 heartbeat/적체/지연 점검008·안전한 CLI/감시 워크플로 준비. 실제 스테이징 정상2회와 중지 후 stale 감지 검증. 워크플로는 비활성, 저장소 Fly 토큰 없음. 운영 알림/수신자·용량/업로드 실패 관측의 실제 연결은 미완료.
- [ ] E05 사용자 변경점·알려진 제한·문의 `humtrack@gmail.com`·단계적 출시·중단/복구 절차를 확정한다. 로컬 파일을 손상시키는 구버전으로 단순 다운그레이드하지 않는다.
- [ ] E06 모든 필수 항목을 완료한 최종 후보와 증빙을 사용자에게 보고하고 사용자가 출시 여부를 최종 확정한다. 현재 체크리스트를 완료했다고 표시하지 않는다.

## 3. 이미 처리한 로컬 병목과 증거

| 항목 | 결과 / 증거 |
|---|---|
| Android JDK 경로 | 삭제된 `mobile/build/preflight-tools/jdk-17.0.20.1+1` 참조를 설치된 Microsoft JDK17로 변경. 실제 설정 파일은 `%APPDATA%/.flutter_settings`였다. 변경 전 원본 바이트 백업은 확보하지 못했으며, 변경 전 조회 값으로 복원용 `flutter-settings-before.reconstructed.json`을 만들었다. 현재 원본과 변경 내역도 `flutter-settings-after.json`, `jdk-setting-change.json`에 보존 |
| 앱 검사 | 최신 `artifacts/release-followthrough-2026-10-31/analyze.log`, `flutter-full.log`: 0건 /1052 통과·19 skip |
| Android | `android-debug.log`, `android-16kb-debug.json`: 네이티브 컴파일과 정렬 통과. 현재 AGP/Kotlin/SDK XML 경고는 남지만 이 빌드 차단은 아님 |
| Windows | 최신 `artifacts/staging-2026-11-01/windows-configured-build.log`, `humtrack-build-receipt.json`:1.0.14+44, 공개 키 이름만 기록, 값·관리자 키 미포함. source has local changes 상태 |
| 설치 후보 | 최신 `artifacts/staging-2026-11-01/installer-build.log`,44 후보 manifest/해시; `public_release_ready=false`.95개 파일 해시·추가 라이선스 포함. 이전 후보 유지 |
| 데스크톱 구독 | `desktop-entitlement-tests.log`: 관련16 통과. 최신 전체 앱1052에도 포함 |
| 패키징 경계 | `python infra/scripts/test_windows_release.py`:9 통과 |
| 서명 자격 | 현재 사용자 코드서명 인증서 0개. GitHub에도 Windows 서명용 시크릿 이름은 없음. 서명 서비스/인증서 확보와 게시자 확인 필요 |
| 백엔드 | 최신 `artifacts/os-impact-2026-11-02/backend-linux-full.log`:최종 osimpact1 후보335 통과·11 skip, API30·DNS/TLS·상태 검사·TAR 해시 확인. setuptools/native/SQLite/zlib 후속으로 fnmatch 셸·DNS/로케일 완화·터미널 라이브러리 제외. Python 취약점0. OS25종 영향 검토와 조건부 잔여4·정적 분석 한계를 기록. 전체 보안 검토는 미완료. 앞선 실제 스테이징 검증과 범위 구분 |
| 클라우드 로컬 통신 | `artifacts/cloud-lifecycle-2026-10-31/http-roundtrip-evidence.json`: 노트·녹음128088바이트 비교, 기기 곡2개 보존. 공급자 검증기도 로컬29절차 통과. 실제 R2 검증 아님 |
| 원격 상태 | 10/30 마지막 배포·스토어 메타데이터 워크플로 성공, 필요한 모바일 배포 시크릿 **이름** 존재. 새 후보의 서명 빌드를 검증한 것은 아님 |
| 공개 iOS 버전 | Apple lookup에서 1.0.10, 공개일 2026-10-05, iOS15+. ASC 업로드/심사 중 최고 빌드 번호와 구분 |
| 실제 운영 조사 | `artifacts/release-followthrough-2026-10-31/remote-readonly.json`, `resource-server-readonly.json`, `api-client-compatibility.json`. 서버·고객 데이터 변경 없음 |

증거 폴더는 `C:/src/humming-v2/artifacts/release-preflight-2026-10-31`이다.
클라우드 수명주기 구현 시점의 증거는 `artifacts/cloud-lifecycle-2026-10-31/`이다.
후속 최신 결과·직접 할 일·고지/다운로드 안내 초안은 [RELEASE-HANDOFF-2026-10-31.md](RELEASE-HANDOFF-2026-10-31.md), 증거는 `artifacts/release-followthrough-2026-10-31/`를 따른다.
구현과 운영 적용 절차는 [CLOUD-LIFECYCLE-2026-10-31.md](CLOUD-LIFECYCLE-2026-10-31.md)에 기록했다.
이전 자료를 최신 완료 상태로 잘못 읽지 않도록 이 체크리스트를 출시 판단의 기준으로 쓴다.

## 4. 진행 순서

1. **클라우드 데이터 수명주기·탈퇴·실서비스 테스트와 고지 문구/일정**부터 해결한다. 구현 지시서는 [CLOUD-RELEASE-WORKORDER-2026-10-31.md](CLOUD-RELEASE-WORKORDER-2026-10-31.md)에 있다. 스토어 심사 직전에 발견하면 출시 일정을 가장 크게 늦춘다.
2. 서명 자격과 실제 테스트 계정/서비스 접근을 준비하면서 Windows 설치/콜백/리소스를 검증한다.
3. 동일 최종 커밋에서 CI·서명 AAB/IPA·Windows 설치 후보를 만든다. 사용 빌드 번호를 먼저 확인한다.
4. 사용자가 폰을 연결·로그인한 뒤 업데이트/구매/클라우드 왕복·청취를 함께 확인한다.
5. 공지·Sentry·삭제 큐/용량 알림과 복구 절차를 확인한다.
6. 최종 증빙 확인 후 스토어 출시와 Windows 다운로드 공개를 진행한다.

체크리스트 상태 검사(소스·서비스를 바꾸거나 배포하지 않음):

```powershell
python infra/scripts/release_gate.py --output artifacts/release-preflight-2026-10-31/release-gate.json
```

현재 결과는 **14/43 완료, 29개 미완료, 종료 코드2**다. 보안 검증 A10을 추가했다. 모든 필수 항목이 완료돼야
검사가 0으로 끝난다. 체크 표시는 각 항목에 적은 실제 증빙을 확인하고 갱신한다.

## 참고한 공식 배포 자료

- [Flutter Windows 배포와 VC 런타임](https://docs.flutter.dev/platform-integration/windows/building)
- [Microsoft 서명 및 SmartScreen 평판](https://learn.microsoft.com/windows/apps/package-and-deploy/smartscreen-reputation): 서명만으로 새 프로그램의 경고가 즉시 사라진다고 보장하지 않는다.
- [app_links Windows 등록/기존 인스턴스 전달](https://github.com/llfbandit/app_links/blob/main/doc/README_windows.md): 현재 잠긴 6.4.1의 `SendAppLink(HWND)` API에 맞춰 구현했다.
- [Android 16KB 지원 검사](https://developer.android.com/guide/practices/page-sizes): 최종 Play 제출물과 기기 검사가 필요하다.
- [Inno Setup 공식 다운로드](https://jrsoftware.org/isdl.php), [포터블 컴파일러 모드](https://jrsoftware.org/ishelp/topic_technotes.htm). 컴파일러는 공식 서명을 확인한 뒤 저장소 안에서만 준비했다.
