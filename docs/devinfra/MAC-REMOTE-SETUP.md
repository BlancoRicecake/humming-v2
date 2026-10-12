# Mac 작업 — Codex에 붙여 넣는 프롬프트로 진행

결정 (2026-10-12, Heo): Mac 원격 작업은 **Mac의 Codex**로 한다. Claude는 Codex에 그대로 붙여 넣을 프롬프트를 만들고, Heo가 Codex의 결과 요약을 Claude에게 다시 붙여 넣는다. Tailscale·SSH는 쓰지 않는다.

```
Claude (프롬프트 작성) → Heo (Codex에 붙여 넣기) → Mac Codex (실행) → Heo (결과 요약을 Claude에 붙여 넣기)
```

Mac에서는 **출시 서명 빌드를 하지 않는다** (GitHub Actions 담당). 그래서 Mac에는 배포 인증서(.p12)와 ASC API 키가 필요 없다.

## 모든 Mac 프롬프트에 들어가는 규칙

- 저장소 위치는 `~/src/humming-v2` 하나. 다른 곳에 새로 clone하지 않는다.
- 시크릿 값(키, 비밀번호, plist 내용, .env 값)을 화면에 출력하지 않는다. 있는지·형식이 맞는지만 말한다.
- 스토어 업로드, 심사 제출, 인증서 발급·폐기를 하지 않는다.
- 끝에 정해진 형식의 **"Claude에게 전달할 결과"** 블록을 출력한다.

## Mac에서 막히기 쉬운 지점 (프롬프트에 반영됨)

- 절전·잠금: 전원 연결, 디스플레이가 꺼져도 잠자기 방지. macOS·Xcode 자동 업데이트 끄기 (Xcode가 바뀌면 빌드가 깨짐).
- 키체인 잠김: 개발 서명이 멈추면 Mac에서 로그인 키체인 잠금 해제.
- Xcode Apple ID 세션 만료·2단계 인증: 화면에서 다시 로그인해야 한다. Codex가 대신할 수 없다.
- iPad 첫 연결: USB로 한 번 연결해 신뢰 → 개발자 모드 → Xcode에서 "Connect via network". 이후 Mac과 같은 Wi-Fi에서 무선 설치 가능.
- ⚠️ PC의 `backend\secrets\humtrack-transfer\GoogleService-Info.plist`는 iOS 1.0.9를 크래시시킨 옛 파일이다. **Mac에 복사하지 않는다.** 올바른 병합본은 Mac의 `mobile/ios/Runner/`에 있다 (10-04 핫픽스).

## 프롬프트 기록

| 번호 | 목적 | 상태 |
|---|---|---|
| M1 | Mac 현재 상태 점검 (읽기 전용) | 전달함 2026-10-12 |

### M1 — Mac 현재 상태 점검

전제: PC에서 `chore/devinfra` 브랜치가 GitHub에 push된 뒤 실행.

````
HumTrack(humming-v2) 저장소의 Mac 개발 환경을 점검해줘. 이번 작업은 확인만 하고, 아래에 명시한 것 외에는 아무것도 바꾸지 마.

규칙
- 시크릿 값(키, 토큰, 비밀번호, plist·.env 내용)은 절대 출력하지 마. 있는지와 형식만 말해.
- 스토어 업로드, 인증서 변경, git push, 커밋, 파일 삭제는 하지 마.

1. 저장소 찾기
   - ~/src/humming-v2 가 있는지 확인. 없으면 이 Mac에 있는 humming-v2 clone 위치를 모두 찾아서 경로만 알려줘 (새로 clone하지 마).
2. git 상태 (저장소 안에서)
   - 현재 브랜치, `git status --short` 줄 수
   - `git fetch --prune origin` 실행
   - GitHub에 없는 로컬 브랜치, 또는 push 안 된 커밋이 있는 브랜치 목록
     (`git for-each-ref refs/heads --format='%(refname:short) %(upstream:short) %(upstream:track)'`)
   - `git worktree list`
3. 점검 스크립트 받기
   - 작업 중인 변경이 없을 때만: `git switch chore/devinfra` (원격에서 가져오기). 변경이 있으면 바꾸지 말고 그 사실만 알려줘.
   - `python3 infra/scripts/dev_doctor.py` 실행, 출력 전체를 보여줘 (이 스크립트는 시크릿 값을 출력하지 않아).
   - `python3 -m unittest infra/scripts/test_dev_doctor.py` 결과
4. 도구 버전
   - `sw_vers`, `xcodebuild -version`, `flutter --version`, `ruby -v`, `bundle -v`, `pod --version` (없으면 없다고)
5. 기기
   - `flutter devices` 결과 (iPad가 보이는지)
6. 절전 설정
   - `pmset -g` 에서 sleep, displaysleep, womp 값

마지막에 아래 형식으로 요약해줘.

=== Claude에게 전달할 결과 ===
저장소 경로:
현재 브랜치 / 변경 줄 수:
GitHub에 없는·push 안 된 브랜치:
worktree:
dev_doctor FAIL 항목:
dev_doctor WARN 항목:
단위 테스트:
macOS / Xcode / Flutter / Ruby / CocoaPods:
flutter devices:
pmset sleep / displaysleep / womp:
기타 이상한 점:
=== 끝 ===
````
