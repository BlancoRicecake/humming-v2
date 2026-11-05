# 출시 준비 결과와 사용자에게 남긴 일

> 이 문서는 10/31 당시 기록이다. 11/01의 Apple 계약·버전44·실제 스테이징 통합 검증과
> 운영 migration007 보안 수정은 [STAGING-VERIFICATION-2026-11-01.md](STAGING-VERIFICATION-2026-11-01.md)를 따른다.

2026-10-31 KST. 최신 파일이 있는 `C:/src/humming-v2`에서 진행했다.
**출시 보류. 운영 배포·DB 변경·고객 공지·스토어 업로드·push·PR은 실행하지 않았다.**
이 문서는 이전 계획을 완료로 바꾸는 보고가 아니라, 실제 증거와 남은 의존성을 정리한 인계다.

## 이번에 처리한 일

1. Fly의 기존 로그인으로 운영 서버를 **읽기 전용** 점검했다. 서버 내부 `/health`와
   구독 알림 상태가200으로 응답했다. Supabase 프로젝트도 앱 설정과 일치했다.
   R2 `vocals/` 전체 목록의 객체0개/0바이트, 클라우드 프로젝트·용량 행0건을 확인했다.
   곡 내용·객체 키·계정 토큰은 내려받거나 기록하지 않았다.
2. 새 커밋 RPC·삭제 큐·공지 테이블이 현재 PostgREST에서 보이지 않는 것을 확인했다.
   실제 DB 부재와 스키마 캐시/노출 문제를 구분하는
   `backend/sql/2026-10-31_release_preflight_readonly.sql`을 준비했다.18개 항목을
   읽기 전용 트랜잭션에서 검사하며, 누락된 migration과 잘못된 클라이언트 권한을 검출했다.
3. 기본 Python API 조회의403은 Cloudflare1010이었다. 같은 PC에서 Dart 형식과
   `HumTrack (+https://hum-track.com)` 식별 헤더를 쓴 공개 조회는200/ok였다.
   Fly 기본 HTTPS 주소도200이었다. **앱 접속 장애나 서버 장애로 단정하지 않는다.**
   실제 설치 앱의 허밍/로그인 왕복은 여전히 별도 검사다.
4. **운영 서버에 음원 카탈로그23개 행만 있고 .sf2 파일은0개**인 문제를 확인했다.
   실제 `/soundfonts`는 빈 목록이다. 로컬에는 유효한 음원11개가 있고 필수8개는
   모두 존재한다. `backend/verify_soundfonts.py`를 Docker 빌드에 연결해 필수 파일
   누락·잘못된 파일 경로·손상된 컨테이너/명시 해시를 검사한다. 빈 음원 서버 이미지가
   다시 만들어지는 것을 막지만 **현재 운영 이미지는 아직 고치지 않았다.**
5. 앱의 추가 음원 다운로드를 수정했다. 같은 크기의 손상 캐시도 해시로 판정해
   복구하며, 복구 실패 시 해당 파일을 정상 악기로 반환하지 않는다. 너무 큰 임시 파일은
   처음부터 받고, 반복416은 유한하게 실패 처리해 재시도가 끝나도록 했다.
6. GeneralUser GS 공식 라이선스 원문을 앱 라이선스 화면에 추가했다. 기존 SF2의
   내장 이름은 `GeneralUser GS 2.0.3 BETA`여서 그대로 표시한다. 음원 파일은 교체하지 않았다.
   설치 폴더에는 Flutter/패키지와 추가 원문을 묶은 `THIRD-PARTY-NOTICES.txt`를 넣었다.
   고지 추가만으로 전체 음원·모든 네이티브 의존성의 권리 검토가 끝난 것은 아니다.
7. 최신 Windows 내부 설치 후보를 새 경로로 만들었다. 기존 `releases/current`와
   이전 후보를 보존했다. 클라우드는 OFF이며 서명 전이다.
8. Google Play의 전체 App Bundle 목록을 확인했다. 최고 업로드는 **1.0.13 /43**,
   내부 테스트에서 제공 중이고 프로덕션은 **1.0.10 /39**다. Apple 최고 번호 확인이
   남아 있어 pubspec 버전은 바꾸지 않았다. 최종 빌드는44 이상이면서 Apple 최고보다 커야 한다.

## 검증과 증거

최신 증거: `artifacts/release-followthrough-2026-10-31/`.

| 검사 | 결과 | 증거 |
|---|---|---|
| Flutter analyze |0건|`analyze.log`|
| 앱 전체 |1052 통과 /19 skip|`flutter-full.log`|
| 백엔드 전체 |314 통과 /11 skip, 실제 로컬 PG 포함|`backend-full.log`|
| 패키징 |9 통과|`packaging-tests.log`|
| Windows main Release |성공|`windows-configured-build.log`, `humtrack-build-receipt.json`|
| 읽기 전용 서비스 조사 |서버 내부·외부·DB 노출·R2 객체 수 점검|`remote-readonly.json`, `public-api-check.json`, `api-client-compatibility.json`|
| 운영 음원 누락 |선언23/실제0, HTTP 목록0|`resource-server-readonly.json`|
| 로컬 음원 |선언23/사용 가능11/필수 누락0/손상0|`local-soundfont-pack.log`|
| 설치 후보 |미서명·클라우드 OFF·공개 준비 false|`installer-build.log`, 후보 manifest/해시|

새 후보: `artifacts/releases/candidate-1.0.13-43-resources-20261031/`.
SHA-256: `d3f7d956d87d6c9f4a8de6e6c679a6e001e64e8e1af9e10b2fbb145fc2241ba5`.
번호43의 기존 스토어 빌드와 다른 내부 산출물이므로 스토어에 이 번호로 올리지 않는다.

이전 클라우드 앱↔로컬 HTTP 왕복과 공급자 계약29절차 결과는
`artifacts/cloud-lifecycle-2026-10-31/`에 있다. R2는 대역이었다.
백엔드11 skip은 옛 계약 검사, 앱19 skip도 실기기 완료로 세지 않는다.
Windows MSB8028 경고와 테스트용 JWT 키 길이 경고는 남아 있다.

## 사용자가 직접 해야 하는 일

개발 명령이나 SQL을 직접 실행할 필요는 없다. 다음 접근·물리 조작·사업자 결정만 필요하다.

| 순서 | 직접 할 일 | 방법 / 완료 후 알려줄 내용 | 제가 이어서 할 일 |
|---|---|---|---|
|1|Supabase 로그인|사이드브라우저의 로그인 화면에서 기존 계정으로 로그인. 프로젝트 `iznehtmmpnivtjdiohgg`의 humstudio가 보이면 “Supabase 로그인 완료”|실제 정책/RPC/트리거 조회, 스테이징 준비 가능 여부·비용 확인, 적용·배포와 격리 계정 검증 준비|
|2|App Store Connect 로그인·2FA|Chrome에서 App Store Connect 로그인 후 HumTrack 접근 가능 상태로 두고 알려주기|최고 빌드 번호와 심사 상태 확인, 공통 버전/번호 확정, 서명 CI 빌드 준비|
|3|서명 서비스/인증서의 사업자·본인 확인과 비용 결정|Windows 공개 게시자명을 정하고 필요한 발급·결제/인증 절차 직접 완료. 개인키·비밀번호를 채팅에 붙이지 않기|안전한 서명 연결, 앱/설치 파일 서명·타임스탬프·최종 해시 검사|
|4|폰과 iOS 기기/Mac 접근 제공|Android는 기존 데이터 그대로 USB 연결·잠금 해제·디버깅 허용. iOS는 TestFlight 설치 또는 Mac/실기기 테스트 준비|업데이트 데이터 보존, 로그인·구독·클라우드 왕복을 가능한 범위에서 자동 검증|
|5|실제 허밍·소리 확인|안내받은 짧은 허밍 녹음과 재생을 듣고 악기/보컬·지연·음량 이상 여부 확인|파일·노트·해시·재시작·내보내기 검사 결과와 사용자 청취 결과를 합침|
|6|출시 정책·고지·최종 공개 결정|확인된 저장 지역과 삭제 기록 보관안, 고지 시행일/이력을 검토·확정. 마지막에 출시 여부 결정|문구/스토어 신고/공지 초안 반영, 최종 동일 후보 재검증 후 게시 준비|

Supabase 로그인은 이번 대화에서 사용자가 직접 하고 나중에 알려주기로 했다.
자동 승인 검토가 기존 GitHub 로그인 버튼 클릭을 거부했으며, 로그인은 사용자가
직접 맡기로 남겨둔 작업이라는 이유였다. 해당 클릭을 우회하지 않았다.
필요한 로그인/인증이 더 있으면 그 화면만 사용자에게 남긴다.

새 스테이징 자원의 비용, 새 DB 비밀번호 입력, 신원 확인·약관 동의가 필요하면
그 단계만 구체적으로 안내한다. 사용자에게 고객 데이터 정리나 서버 키 복사·공유를 맡기지 않는다.

## 접근이 준비되면 제가 마무리할 일

1. 최종 소스 동결과 원격 CI. 현재 작업은 미커밋이며 기존 push·PR 보류 요청을 유지했다.
2. Supabase 실제003/004/005/006, SELECT 전용 정책·서비스 RPC·Auth 트리거·캐시 검증.
3. 실제 음원11개를 포함한 서버 이미지 준비와 격리 환경 검증. Git만 복제한 환경에는
   큰 음원이 없으므로 빈 이미지 빌드는 차단된다. 선택 파일12개는 현재 미포함이며
   런타임 목록에서도 제외된다.23개 전부 제공한다고 고지하지 않는다.
4. 클라우드 정리 작업자·지속 큐 모니터링·장애 알림을 연결하고 실제 실패/복구 증거 확보.
5. 전용 계정2개로 실제 Supabase·R2 공급자 검사, 한도·구독 만료·탈퇴·지연 PUT 검증.
   고객 계정의 구독을 강제로 바꾸거나 고객 파일을 시험용으로 지우지 않는다.
6. 최신 설치 프로그램을 개발 도구 없는 Windows PC/VM에서 검증. 이 PC에서의
   설치·제거와 새 PC 검증을 구분한다. 필요한 새 PC/VM 접근이 없다면 제공만 요청한다.
7. 최종 AAB/IPA/Windows 서명·Sentry 수신·라이선스/리소스·공지 표시·다운로드 페이지 검증.
8. 결과를 [출시 체크리스트](RELEASE-CHECKLIST-2026-10-31.md)에 반영하고 공개 직전 보고.

## 개인정보·스토어 고지 개정 초안 — 미게시

아래 문구는 기존 정책의 관련 절을 교체할 초안이다. 정책 전체를 대체하지 않으며,
`[확정 필요]`를 채우기 전 활성 문서/스토어 신고에 적용하지 않는다.
Firebase 초안의 예정일2026-11-01을 클라우드 시행일로 재사용하지 않는다.

KO: “HumTrack의 클라우드 백업은 Pro 사용자가 직접 선택하여 작업물을 저장하는
기능입니다. 자동으로 모든 곡을 동기화하지 않습니다. 백업 파일에는 곡과 노트 등
프로젝트 데이터가 들어가며, 녹음은 사용자가 ‘녹음 포함’을 선택한 경우에만 포함됩니다.
녹음 포함은 기본적으로 꺼져 있습니다. 백업 객체는 Cloudflare R2에, 소유 계정·사본
정보·용량 등 메타데이터는 Supabase에 저장됩니다. 처리 지역과 국외 이전 관련 사항은
[실제 설정·계약 확인 후 기재]입니다. 구독이 만료되어도 기존 사본의 목록·복원·삭제는
이용할 수 있으며 신규 업로드는 제한됩니다. 클라우드 사본 삭제는 기기 원본을 삭제하지
않습니다. 탈퇴 요청 접수 후 계정 접근을 차단하고 파일 삭제를 재시도하며, 이미 발급된
업로드의 지연 완료도 재검사합니다. 삭제 처리용 최소 기록의 보관 목적·기간과 최종
삭제 기준은 [확정 필요]입니다. 관련 문의는 humtrack@gmail.com으로 접수합니다.”

EN: “Cloud backup is a Pro feature that saves your work when you choose to back it up.
It does not automatically synchronize every song. A backup includes project data such
as the song and notes. Recordings are included only when you select that option, which
is off by default. Backup objects are stored in Cloudflare R2; account ownership,
backup metadata and usage information are stored in Supabase. Processing locations
and cross-border transfer details: [confirm actual settings and contracts]. After a
subscription expires, existing backups can still be listed, restored or deleted; new
uploads are restricted. Deleting a cloud copy keeps the original on your device.
An accepted account deletion request blocks account access and schedules retries for
server file deletion, including checks for uploads that finish late. Purpose, retention
period and final removal criteria for minimal deletion records: [decision required].
Contact humtrack@gmail.com for requests.”

App Privacy/Data Safety에서 수동 백업한 프로젝트·선택적 녹음을 기존 ‘서버 미보관’
설명과 구분해야 한다. 녹음/사용자 콘텐츠·사용자 ID·구매/진단 항목의 분류와 선택성,
서비스 제공 목적·수탁자 관계를 최종 설정/계약과 대조한다. 기존 Firebase 제출 초안의
‘오디오가 전혀 수집되지 않는다’는 판단을 클라우드 공개 시 그대로 사용하지 않는다.

## Windows 다운로드·업데이트 안내 초안 — 미게시

KO: “HumTrack for Windows — 설치 프로그램을 내려받아 설치한 뒤 앱을 실행하세요.
기본 악기는 포함되어 있으며 추가 음원은 앱 안에서 필요할 때 다운로드할 수 있습니다.
업데이트 전 작업을 저장하고 HumTrack을 종료한 뒤 새 설치 프로그램을 실행하세요.
계정 구독은 휴대폰 앱에서 관리하고 Windows에서는 같은 계정으로 로그인하세요.
문의: humtrack@gmail.com.”

EN: “HumTrack for Windows — download and run the installer, then launch the app.
Basic instruments are included. Download additional sounds inside the app when needed.
Before updating, save your work and close HumTrack, then run the new installer.
Manage subscriptions in the phone app and sign in with the same account on Windows.
Support: humtrack@gmail.com.”

최종 페이지에는 검증한 Windows 버전/x64 요구 사항, 최종 버전·크기·SHA-256,
게시자 서명, 공개 HTTPS 다운로드 URL, 변경점·알려진 제한·문의 링크를 함께 넣는다.
현재 내부 파일 경로를 공개 다운로드 링크처럼 게시하지 않는다. 설치/추가 음원 경로와
실제 제공 목록을 검증한 뒤 위 문구를 사용한다. 자동 업데이트는 약속하지 않는다.

근거: [Cloudflare 오류1010](https://developers.cloudflare.com/support/troubleshooting/http-status-codes/cloudflare-1xxx-errors/error-1010/),
[GeneralUser GS 제작자 라이선스](https://github.com/mrbumpy409/GeneralUser-GS/blob/684543d5e5efaef08d02be50dcda8d552478fa60/documentation/LICENSE.txt),
[Microsoft VC 배포 자료](https://learn.microsoft.com/cpp/windows/redistributing-visual-cpp-files).
