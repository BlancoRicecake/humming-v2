# Android 내부 테스트 1.0.14 (44)

2026-11-01 KST. 사용자가 현재 수정본의 Android 내부 테스트 업로드를 요청했다.
이 요청은 Google Play의 internal 트랙에만 적용하며 Git push·PR·정식 공개 배포는 보류한다.
**업로드 완료:** 검증한 AAB를 internal에 commit한 뒤 다시 조회하여44/completed를 확인했다.
production39·다른 트랙은 변경되지 않았다. 실제 기기의 업데이트/실행 확인은 사용자에게 남긴다.

## 완료 결과

- Flutter analyze0건, 전체1052통과/19skip, 인증 누락 가드10통과.
- 서명 AAB 구조·원본 업로드 키 일치·target API36·native81개 중64비트16KB ELF 검사 통과.
- AAB212771261바이트, SHA-256 `3cc6e1c097c8dfc96d9afe09b441b081d6037c1d35c6d310aa8c288494b4496c`.
  Google upload 응답 해시와 일치한다. 컨테이너 크기를 실제 기기 다운로드 크기로 해석하지 않는다.
- internal `1.0.14 (44) internal QA` / completed. 실제 Play UI에서 **내부 테스터에게 제공됨**,
  게시일11/01 23:43 확인·캡처 저장(`play-internal-44.jpg`).
- `jlionk200@gmail.com`이 현재 선택된 테스터 목록에 있음을 읽기 전용 확인했다. 목록은 수정하지 않았다.
- 임시 key.properties·공개 defines JSON은 제거했고 원본 자격 증명은 보존했다.
-44는 이제 사용된 번호다. 클라우드 ON 등 후보 내용/설정을 바꿔 다시 올릴 때는 **45 이상**을 사용한다.

## 후보와 사전 검사

- `C:/src/humming-v2/mobile/`의 현재 소스로 main.dart Release AAB를 빌드한다.
  과거 CI 산출물을 다시 올리거나 원격 브랜치로 소스를 바꾸지 않는다.
- 공통 버전 `1.0.14+44`. 업로드 직전 최고 사용 번호는43, internal43, production39다.
- 기존6개 공개 설정과 원본 업로드 키를 사용한다. 서버 관리자 키는 앱에 넣지 않는다.
- `HUMTRACK_CLOUD_BACKUP=false`, `FIREBASE_ANALYTICS_ENABLED=false`,
  `SENTRY_ENVIRONMENT=internal`. Sentry 이벤트 실제 수신 완료를 의미하지 않는다.
- Android 서명 연결용 key.properties는 일시적으로 만들고 종료 시 지운다.
  원본 키/속성/Play 서비스 계정 파일은 `backend/secrets/humtrack-transfer/`에 그대로 둔다.
- Flutter3.47.1 / Gradle8.14.3, 인증 누락 가드10개·analyze·전체 Flutter 테스트 후 빌드한다.
- Google 공식 bundletool1.18.3은 공급자 SHA-256 일치를 확인하고 저장소 안에서만 사용한다.
  구조·패키지·버전·target API·서명 원본 일치·64비트 native16KB ELF 정렬을 검사한다.
- 업로드는 검증 파일의 SHA-256과 동일한 AAB로 제한한다. 서버가 반환한 해시도 대조한다.
- internal 외 트랙이 바뀌지 않았음을 commit 전후 비교한다. 스토어 설명·스크린샷·상품·테스터 목록은 변경하지 않는다.

## 설치와 사용자 테스트

Play Console에 표시된 실제 참여 링크:
[HumTrack 내부 테스트 참여](https://play.google.com/apps/internaltest/4701278899500552203).
기존 내부 테스트 참여 계정 `jlionk200@gmail.com`으로 휴대폰에서 연다.
테스터 목록에 포함·참여 상태여야 하며 실제 기기의 업데이트 노출은 사용자가 확인한다.

기존 앱을 삭제하거나 데이터를 초기화하지 않는다. 기존 곡을 저장한 뒤 Play에서 업데이트한다.
스토어 앱 정보/휴대폰 설정에서 **1.0.14**가 설치됐는지 확인한다.

| 순서 | 직접 확인할 내용 | 기대 결과 |
|---|---|---|
|1|업데이트 후 기존 곡·녹음·설정을 열고 앱을 닫았다 다시 열기|기존 작업물과 설정 보존|
|2|새 시험 곡에서 짧게 허밍 → MIDI 변환 → 악기 재생|변환·노트·소리·지연에 이상 없음|
|3|보컬 녹음과 악기 노트를 함께 저장 → 앱 재실행 → 곡 다시 열기|녹음/노트/재생 상태 복구|
|4|시험 곡을 .humtrack/MIDI/WAV로 내보내고 다시 가져오기/열기|파일이 실제로 생성되고 적절한 앱에서 열림|
|5|로그인·로그아웃·다시 로그인, 기존 구독의 복원/상태 확인|다른 계정 곡과 섞이지 않고 올바른 상태 표시|

오류가 있으면 위 순서 번호, 발생 시각, 화면/행동과 소리 여부만 전달하면 된다.
비밀번호·영수증 원문·사용자 토큰을 보내지 않는다.
구매/만료·마이크 권한 거부·기기 전환·클라우드 왕복은 후속 안내에 따라 별도 확인한다.
**이번 빌드에서는 클라우드 백업을 테스트할 수 없다.** 운영 준비 후 새 번호로 검증한다.

## 증거와 남은 확인

증거 폴더: `C:/src/humming-v2/artifacts/android-internal-2026-11-01/`.
`build-receipt.json`의 mobile 소스 파일별 SHA-256과 실제 AAB 검증/업로드 해시로 후보를 구분한다.
기준 HEAD만으로 미커밋 수정본을 재현할 수 있다고 주장하지 않는다.
최종 Play가 생성한 split APK의16KB 기기 실행, 실제 설치·업데이트 데이터 보존·소리·Sentry 수신은
자동 구조 검사나 internal completed 상태로 대체하지 않는다.

추가 운영자 확인: Play 알림 센터에 개발자 결제 계정 확인 요청이 보였다.
HumTrack internal 업로드를 차단하는지 또는 다른 앱/계약에 한정되는지는 알림만으로 단정하지 않는다.
[Play 결제 설정](https://play.google.com/console/u/1/developers/5993240480136168281/paymentssettings)은
계정 소유자가 신원·결제 정보를 직접 확인한다. 이번 작업에서 금융 설정/계약을 변경하지 않는다.

근거: [Android 공식 bundletool 안내](https://developer.android.com/tools/bundletool),
[Google Play internal 트랙/Edits](https://developers.google.com/android-publisher/tracks),
[현재 target API 요구](https://developer.android.com/google/play/requirements/target-sdk).
