# Lessons

프로젝트를 진행하며 겪은 까다로운 문제와 그 해결 과정을 기록합니다. 같은 증상이 다시 나타났을 때, 또는 비슷한 구조의 버그를 만났을 때 빠르게 참고하기 위한 문서입니다.

---

## iOS 허밍→MIDI 합성음 지직거림 (언더런)

날짜: 2026-06

### 증상

- iOS에서 허밍 녹음 기능을 쓸 때, 합성음(녹음 중 백킹 + 녹음 후 패드 탭)이 지직거리며 깨졌다.
- 정확한 타이밍: **녹음 전 재생은 깨끗**, **녹음 중 + 녹음 후 둘 다** 깨짐.
- Android는 동일 증상 없음.
- 제약: "마이크 표시등이 항시 뜨는 건 안 됨" → 항상 `.playAndRecord`로 두는 해법은 불가.

### 오디오 구조 (문제의 무대)

- **MeltyEngine** (`dart_melty_soundfont`) = 순수 Dart **신디사이저**. 44100Hz로 PCM을 렌더.
- **flutter_pcm_sound** = **출력 레이어**. raw RemoteIO AudioUnit으로 PCM을 스피커에 흘림.
- 둘은 보완 관계(신디가 PCM 생성 → flutter_pcm_sound가 출력).
- iOS의 `AVAudioSession`은 **프로세스 전역 싱글톤**. 입력(녹음)과 출력(RemoteIO)이 한 세션을 공유.
- 녹음이 시작되면 세션이 `.playback → .playAndRecord`로 전환되고 하드웨어 IO가 재협상된다.

### 처음 세운 가설 (그리고 전부 틀림)

초기엔 원인을 **세션 카테고리 전환 / 샘플레이트 불일치**로 봤다. 그 가설로 시도한 것들:

1. **녹음 샘플레이트를 출력과 일치**(16000→48000→디바이스 네이티브 매칭) → 실패. 크래클 그대로.
2. **출력을 항상 `.playAndRecord`로 고정 + playback과 동일 설정** → 마이크 표시등 상시 노출 문제 + 녹음 전부터 깨짐. 폐기.
3. **출력 유닛을 녹음 경계에서 rebuild**(release → setup 재생성) → 실패. 갓 만든 RemoteIO도 여전히 지직.
4. **풀 세션 리셋**(deactivate → `.playback` → reactivate)으로 IO 재협상 강제 → "녹음 중·후 여전히 깨짐". 런치 직후와 동일 상태로 되돌렸는데도 안 고쳐짐.

> 핵심 교훈: **모든 세션 기반 수정이 실패했다는 것 자체가 "세션 카테고리가 원인이 아니다"라는 강력한 신호였다.** 그런데도 같은 계열의 가설을 계속 변주하며 시도한 게 시간 낭비였다.

사용자가 던진 결정적 질문도 가설을 흔들었다:
- "동시에 도는 게 문제라면 녹음이 **끝난 뒤에는** 다시 제대로 들려야 하는 거 아니야?" → 순수 동시성/세션 문제로는 "녹음 후"가 설명되지 않았다.

### 방향 전환: 추측 대신 코드를 읽기

사용자가 "추측 그만하고 계측으로 ground truth부터 확보하자"고 요구. 무한 반복되는 PCM 로그 때문에 진단 로그가 안 읽혀서, 먼저 스팸 출처를 추적하다가 **flutter_pcm_sound의 네이티브 렌더 루프 (`FlutterPcmSoundPlugin.m`)를 직접 읽은 것이 전환점**이었다.

읽어서 알아낸 동작:

- 네이티브 ring buffer(`mSamples`)를 **실시간 오디오 스레드**(`RenderCallback`)가 계속 비운다.
- 버퍼 보충은 **메인 스레드 메서드채널 왕복**으로 이뤄진다:
  `RenderCallback` → `dispatch_async(main)` → `OnFeedSamples` → Dart `_onFeed` → `feed()` → 네이티브.
- 우리 설정은 버퍼를 **딱 1블록(~23ms)** 만 유지(`setFeedThreshold(1024)`, 매번 1024프레임 feed).
- 버퍼가 0이 되면 `RenderCallback`이 무음(`memset` zeros)을 출력하고 `AudioUnit stopped because no more samples`를 찍는다 — 이게 무한 스팸의 정체였다.

### 진짜 원인 (언더런)

크래클은 **세션 카테고리가 아니라 버퍼 언더런**이었다.

- 출력 버퍼가 ~23ms밖에 안 쌓여 있는데, 그 버퍼를 채우는 경로가 **메인 스레드 왕복**이다.
- **녹음 중**엔 이 얕은 보충 경로가 제때 못 따라가서 버퍼가 0으로 마름 → **실제 소리 중간에 무음이 끼어** 지직거림. (보충이 늦어진 정확한 원인은 계측으로 증명하지 않았다 — 아래 주의 참고.)
- **녹음 전**엔 버퍼에 무음만 차 있어서 언더런이 나도 안 들렸다(= 깨끗하게 들림). 그래서 "녹음 전만 깨끗"이라는 증상이 완벽히 설명된다.
- "녹음 후"도 오디오 IO/부하가 즉시 평소 상태로 안 돌아오면 같은 언더런이 이어진다.

> **주의 — 보충 지연의 실제 원인은 미증명.** 처음엔 "녹음 중 Opus 인코딩 + 오토튠 모니터가 메인 스레드를 막아서"라고 단정했으나, 코드 확인 결과:
> - **오토튠 모니터는 허밍 흐름에 없다.** `startAutotuneMonitor`는 별도 기능인 `vocal_record_modal.dart`(유선 이어폰 라이브 모니터링)에서만 호출된다. 허밍 모달(`hum_modal.dart`)과 무관 — 잘못된 단정이었다.
> - **Opus 인코딩은 돈다**(`hum_modal.dart` `encoder: AudioEncoder.opus`)지만, 인코딩 자체는 `record_ios` 네이티브 레이어(자체 스레드)에서 처리될 공산이 크지 Flutter 메인 스레드라는 보장은 없다.
>
> 확실히 증명된 사실은 **"버퍼를 깊게 하니 해결됐다 = 녹음 중 보충이 못 따라가는 언더런이었다"** 뿐이다. 보충 지연의 실제 원인은 (a) 녹음 시작 시 세션이 `.playAndRecord`로 바뀌며 하드웨어 IO 버퍼가 작아져 RenderCallback이 더 자주/잘게 당김, (b) 녹음 amplitude 이벤트(70ms)·`setState` UI 리빌드·feed 왕복 등 플랫폼 스레드 트래픽 증가, (c) 녹음 파이프라인의 추가 CPU 부하 — 이 조합으로 추정되며, 깊은 버퍼는 원인이 무엇이든 흡수하므로 동작했다.

### 해결

녹음 구간에서만 **버퍼를 깊게 유지**해서 메인 스레드가 잠깐 멈춰도 안 마르게 했다. 평소엔 얕게 둬 패드 탭 반응성을 지킨다.

`mobile/lib/audio/melty_synth_backend.dart`:

- 버퍼 깊이를 상태로 분리:
  - 평소(idle): threshold 1024 / target 2048 (~46ms) — 패드 탭 반응성 유지.
  - 녹음 중: threshold 4096 / target 8192 (~186ms) — 멀티블록 메인스레드 스톨도 버팀. 이때는 라이브 탭이 없으니 추가 레이턴시가 무의미.
- `_onFeed`가 콜백 한 번에 **여러 블록을 채워** `_targetFrames`까지 보충하도록 변경(기존엔 항상 1블록).
- 녹음 경계(`rebuildOutput(forRecording:)`)에서 깊이/threshold를 전환.

부수 효과: 버퍼가 0까지 잘 안 마르니 `AudioUnit stopped because no more samples` 네이티브 스팸도 거의 사라짐. Dart 쪽 `[PCM]` 스팸은 `setLogLevel(LogLevel.none)`로 차단(원래 코드에 있었으나 그게 도는 빌드를 실제로 테스트한 적이 없어 계속 찍혔던 것).

결과: **녹음 중/후 지직거림 완전 소멸.**

### 교훈 정리

1. **여러 변주가 모두 실패하면 가설의 전제를 의심하라.** 세션 기반 수정이 4번 다 실패한 시점에서 "세션이 원인이 아니다"로 갈아탔어야 했다.
2. **증상의 비대칭이 단서다.** "녹음 전만 깨끗"은 "버퍼에 무음이 차 있을 땐 언더런이 안 들린다"로만 깔끔히 설명됐다 — 이게 언더런 가설의 결정적 증거였다.
3. **추측을 반복하기 전에 의존성 네이티브 코드를 직접 읽어라.** 실시간 오디오 버퍼를 메인 스레드 왕복으로 채운다는 사실 하나가 전체 그림을 바꿨다.
4. **실시간 오디오는 메인 스레드 경합에 취약하다.** RT 스레드가 비우는 버퍼를 비-RT 경로로 채운다면, 경합 최악의 경우를 버틸 만큼의 cushion(버퍼 깊이)이 반드시 필요하다.
5. **레이턴시 vs 안정성은 상황별로 다르게 잡아라.** 라이브 입력이 없는 녹음 구간에선 깊은 버퍼(안정성), 라이브 탭이 있는 평소엔 얕은 버퍼(반응성).

---

## dart-define 시크릿 주입: all-or-nothing 폴백 함정 + `set -e` 조기 종료

날짜: 2026-06

### 배경

신규 외부 SDK(Microsoft Clarity)를 붙이면서 `CLARITY_PROJECT_ID`를 빌드에 dart-define으로 주입해야 했다. 모바일 빌드는 시크릿을 두 경로로 주입한다:

- **디버그**: `mobile/scripts/run.sh` 가 `backend/.env.secrets` 의 키를 읽어 `--dart-define` 으로 붙임.
- **출시**: `mobile/{ios,android}/fastlane/Fastfile` 의 `collect_dart_defines` 가 같은 일을 함.

"기존 키(SUPABASE_URL 등)처럼 `DEFINE_KEYS` 배열과 `.env.secrets` 에만 추가하면 끝"이라고 생각했고, 대체로 맞았지만 두 개의 숨은 함정이 있었다.

### 함정 1 — `run.sh` 가 `set -e` 로 조기 종료 (디버그 빌드 자체가 안 됨)

`run.sh` 는 `set -euo pipefail` 상태에서 각 키를 `grep ... | tail | sed` 파이프로 읽었다. **`.env.secrets` 에 없는 키**(이 환경에선 `ENGINE_URL`)를 만나면 `grep` 이 1을 반환 → `pipefail` 로 파이프라인 실패 → 변수 할당의 커맨드 치환 실패 → `set -e` 로 **스크립트가 그 줄에서 즉시 종료**. flutter run 까지 도달조차 못 했다.

증상이 고약했던 이유: 백그라운드 실행 시 **출력이 비어 있고 exit 1** 만 떨어져, 마치 빌드 도구나 환경 문제처럼 보였다. 포그라운드 `bash -x` 트레이스를 떠서야 "ENGINE_URL 읽는 줄에서 죽는다"가 드러났다.

해결: `read_env` 의 파이프라인을 `{ ...; } || true` 로 감싸 미설정 키는 빈 값으로 graceful 하게 넘어가게 함(원래 의도대로).

### 함정 2 — fastlane `collect_dart_defines` 의 all-or-nothing 폴백

원래 로직은 "ENV 에서 키를 먼저 모으고, **`env.empty?` 면** `.env.secrets` 로 폴백"이었다.

```ruby
DEFINE_KEYS.each { |k| ...ENV[k]... }   # ENV 먼저
if env.empty?                            # 단 하나도 없을 때만
  ...read backend/.env.secrets...
end
```

지금은 fastlane `.env.default` 에 DEFINE_KEYS 가 하나도 없어 항상 `env.empty?` → 폴백이 작동 → 정상. **하지만** 누군가 CI/셸에서 키를 **하나라도**(예: `SUPABASE_URL` 만) ENV 로 주입하기 시작하면 `env.empty?` 가 거짓이 되어 **폴백이 통째로 꺼지고**, `CLARITY_PROJECT_ID` 를 포함한 나머지 키가 전부 누락된다 — Clarity 가 조용히 비활성된 채 출시될 수 있는 시한폭탄.

해결: 순서를 뒤집어 **`.env.secrets` 를 base 로 먼저 읽고, ENV 가 있으면 키 단위로 덮어쓰기**. 부분 주입도 안전하고, ENV override 도 그대로 된다.

```ruby
# 1) 파일을 base 로
read backend/.env.secrets → env
# 2) ENV 가 있으면 키 단위 override
DEFINE_KEYS.each { |k| env[k] = ENV[k] unless ENV[k].to_s.empty? }
```

### 교훈 정리

1. **"기존 패턴 따라하기"는 그 패턴의 숨은 전제까지 따라가는 것이다.** 배열에 키 한 줄 추가는 맞았지만, 그 키가 흐르는 스크립트의 `set -e`/폴백 조건까지 봐야 실제로 동작했다.
2. **빈 출력 + exit 1 은 "환경 탓"으로 속단하기 쉽다.** 포그라운드 `bash -x` 로 죽는 지점을 먼저 특정하는 게 빨랐다.
3. **`set -euo pipefail` + `grep | ...` 커맨드 치환은 "값이 없을 수 있는" 조회와 상극이다.** 선택적 조회는 `|| true` 로 명시적으로 graceful 하게.
4. **설정 병합은 "base 먼저, override 나중"이 안전하다.** `if empty? then fallback` 같은 all-or-nothing 분기는 부분 주입에서 조용히 무너진다 — 키 단위 머지로.
5. **graceful-degrade 연동은 "조용히 꺼짐"이 양날의 검이다.** 키가 빠져도 앱은 안 죽지만, 그래서 누락을 빌드 로그(`dart-defines: ...` 출력)로만 잡을 수 있다 — 그 줄을 출시 체크리스트에 둘 것.
