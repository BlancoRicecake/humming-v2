# 원격 develop → CI 직접 빌드 → Android 내부 테스트46

2026-11-04 KST. 사용자 의도는 develop에 push한 소스로 내부 테스트를 검증하는 것이다.
기존45 등록 상태만 확인하는 것으로 끝내지 않고, GitHub Actions에서 **원격 develop을
직접 checkout하여 테스트·서명 빌드·internal 등록**까지 실행했다.

## 최종 결과

- [실제 실행: Mobile Store Release #16](https://github.com/BlancoRicecake/humming-v2/actions/runs/41685325728)
- source branch: **develop**
- source commit: **533a04d2c53a3234432cd373756249140d312cb3**
- workflow: `.github/workflows/release-mobile.yml`
- 입력: `platform=android`, `destination=internal`, `build_number=46`,
  `replace_pending_ios_release=false`.
- Android job 성공, iOS job skipped. 로컬 작업 트리로 빌드하지 않았다.
- release helper·Android 인증 가드·analyze·전체1115 pass/30 skip 후,
  같은 실행에서 release AAB를 서명 빌드하고 Play internal에 등록했다.
- **1.0.14 (46), internal/completed**를 Google Play API로 다시 조회했다.
- production39와 다른 트랙은 전후 동일하다. PR·공개 배포·운영 서버/DB 변경은 없다.

## 출처·산출물 대조

원격 develop의 pubspec은1.0.14+45다. 기존 수동 릴리스 워크플로의 공식
`build_number=46` 입력으로 빌드 번호만46으로 지정했다. 소스 코드는 수정하지 않았다.
45는 사용된 번호이므로 새 CI 검증본을46으로 구분했다. 다음 새 Android 빌드는47 이상이다.

- CI artifact: `HumTrack-Android-16`, ID13257035298. 이름의16은 워크플로 실행 번호다.
- artifact의 head branch/develop, head SHA/533a04d를 확인한 뒤 AAB를 다운로드했다.
- AAB:212790902바이트. SHA256:
  `2d7f6ad1693a83841b6ba712368900bd0938b9ea958fd48ab3821a8714b2fbea`.
- Google의46번 bundle SHA256이 위 CI 산출물 해시와 정확히 일치했다.
- package `com.humtrack.app`, versionName1.0.14/versionCode46, min24/target36,
  main.dart release, debuggable/testOnly false.
- bundletool 구조, 기존 업로드 인증서 일치, JAR 서명, native81개/64비트16KB ELF,
  자격 증명 파일 미포함 검사를 통과했다.
- artifact ZIP digest는 GitHub 메타데이터에 별도 보존했다. ZIP digest와 AAB 해시는
  서로 다른 대상이므로 혼동하지 않는다.
- 빌드 설정은 GitHub release profile이다. cloud flag는 release helper에서
  통과시키지 않으므로 **클라우드 OFF**다. 로컬45의 internal 환경 설정 파일을
  재사용하지 않았다. 실제 Sentry 이벤트 수신은 기기 검증으로 남는다.

## 휴대폰 확인

[내부 테스트 참여 링크](https://play.google.com/apps/internaltest/4701278899500552203)는
기존과 같지만 대상 빌드는46으로 바뀌었다. 기존 테스터 계정으로 열어 **앱 삭제나
데이터 초기화 없이 업데이트**한다. 휴대폰의 업데이트 노출·설치·실제 소리 판단은 미확인이다.

기존 곡/녹음 보존 → 새 시험 곡의 허밍/MIDI/악기 재생 → 저장·재실행 →
백업/MIDI/WAV 내보내기를 확인한다. iOS는 사용자 MacBook 작업으로 남긴다.

## 증빙과 보존

- `artifacts/mobile-update-2026-11-04/develop-ci-46/`: dispatch.json,
  workflow-run-final.json, workflow.log, build-receipt.json, aab-verification.json,
  play-ci46-readback.json.
- AAB 및 주요 영수증:
  `artifacts/releases/candidate-android-1.0.14-46-ci-20261104/`.
- 44/45는 이전 내부 테스트 이력이며 삭제하지 않았다. 이번 완료 보고의 대상은46이다.
- 루트의 미커밋 원본·브랜치·손상된 changelogs 폴더는 보존했다.
