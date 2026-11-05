# Android 내부 테스트 1.0.14 (45)

최신 내부 테스트는 사용자 요청으로 원격 develop을 CI에서 직접 빌드한 **46번**이다.
[develop 기반46 결과](ANDROID-DEVELOP-CI-INTERNAL-2026-11-04.md)를 따른다. 아래는45 이력이다.

2026-11-04 KST. 사용자 요청에 따라 Claude의 CI 수정 검토 → develop push →
원격 Mobile CI 성공 → 검증된 동일 AAB의 Google Play internal 등록을 완료했다.
PR, 공개 배포, 운영 서버/DB 변경, 공지 게시, iOS 빌드/업로드는 하지 않았다.

## 완료 결과

- 소스: `533a04d2c53a3234432cd373756249140d312cb3`, 원격 develop 반영 완료.
- [Mobile CI 성공](https://github.com/BlancoRicecake/humming-v2/actions/runs/41679470767).
  릴리스 헬퍼·analyze·전체1115 pass/30 skip·인증 가드·Android arm64 컴파일·
  APK native77개/16KB 정렬까지 성공. 같은 커밋의 기존 Windows CI도 성공했다.
- 로컬 Windows: analyze0, 전체1138 pass/19 skip. Linux 깨끗한 checkout에서
  수정 전 실패를 재현하고, 수정 후 관련16개 및 전체1115개 검사를 통과했다.
- 문제는 Linux에서 real-MeltySynth 테스트가 Android 엔진으로 가던 초기화였다.
  테스트 엔진을 명시하고 종료 후 복구하도록 했다. 실제 음향 RMS/구조 적합도
  검증을 지우거나 skip/기대값 완화로 우회하지 않았다. 제품 엔진 선택은 유지했다.
- 서명 AAB의 빌드 기록도533a04d이고, 현재 후보의 생산 입력297개 파일 해시가
  빌드 기록과 전부 일치했다. 수동 후보 manifest의 이전 SHA 표기는 이 자동
  빌드 기록을 기준으로 정정했다.
- package `com.humtrack.app`, version1.0.14/code45, min24/target36,
  main.dart Release, debuggable/testOnly false. 기존 업로드 인증서 일치,
  bundletool 구조·native81개/64비트16KB ELF·자격 증명 파일 미포함 검사 통과.
- AAB212826721바이트. SHA256:
  `38835e8471733d0a62b155fe6d0693dd899c89cb9d942e284a7073cc543806b0`.
  Google upload 응답 해시와 일치한다. 파일 크기는 실기기 다운로드 크기와 다르다.
- internal 등록 후 새 edit으로 다시 조회해 **45/completed**를 확인했다.
  production39 및 alpha/beta 등 다른 트랙은 전후 동일하다.

## 설정과 범위

- `HUMTRACK_CLOUD_BACKUP=false`, analytics OFF, Sentry internal.
  이 파일은 공개 승격용이 아닌 내부 검증용이다.
- 클라우드를 공개할 최종 후보는 운영 lifecycle/정리 관측/백엔드·음원·고지 검증을
  마친 뒤46 이상의 새 번호로 준비한다. 45는 이제 사용된 번호다.
- 원본 업로드 키는 보존했다. 임시 key.properties/공개 defines JSON은 제거됐고,
  서버 관리자 키나 Play 서비스 계정 파일을 앱에 넣지 않았다.
- 기존 루트 브랜치/미커밋 원본·손상된 changelogs 폴더는 보존했다.
- iOS는 사용자가 MacBook에서 별도로 진행한다. 이 PC에서 iOS CI/IPA/TestFlight는
  실행하지 않았다. 프로그램은 새 출시 작업을 하지 않았으며 기존 develop CI만 실행됐다.

## 휴대폰에서 확인할 것

[기존 내부 테스트 참여 링크](https://play.google.com/apps/internaltest/4701278899500552203)를
기존 테스터 계정으로 연다. **앱을 삭제하거나 데이터를 초기화하지 말고 업데이트**한다.
등록 completed는 확인했으나 사용자 휴대폰에서 업데이트가 노출·설치됐는지는 미확인이다.

1. 기존 곡·녹음·설정을 열고, 앱을 종료했다 다시 열어 보존 여부를 확인한다.
2. 새 시험 곡에서 허밍 → 변환된 MIDI 확인 → 악기 재생 → 저장·재실행을 확인한다.
3. 노트 조절/그리드 이동/길게 눌러 선택, 섹션 순서 변경을 시험 곡으로 확인한다.
4. 백업(.humtrack)/MIDI/WAV 내보내기와 로그인·기존 구독 복원을 확인한다.
5. 실제 소리·지연, 기기 권한/백그라운드 동작, 공지 표시, Sentry 실제 이벤트 수신은
   자동 테스트 통과로 대체하지 않는다. 결제/계정 삭제는 별도 시험 계정 검증 대상이다.

## 증빙

- `artifacts/mobile-update-2026-11-04/ci-validation.json`, `ci-mobile-533a04d.log`,
  `ci-fix-independent-review.json`, `CLAUDE-REPORT.md`, `linux-ci-repro/`.
- `artifacts/mobile-update-2026-11-04/android-signed/`의 aab-verification,
  build-receipt, uploaded-bundle, play-commit, play-after JSON.
- AAB와 주요 검증 영수증은
  `artifacts/releases/candidate-android-1.0.14-45-20261104/`에 보존한다.
- 이 문서와 운영 증빙은 로컬에 저장했다. 제품 수정 커밋533a04d의 develop push와
  스토어 내부 등록을 구분하며, 공개 출시 완료로 표시하지 않는다.
