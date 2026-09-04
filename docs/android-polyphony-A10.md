# A10 — Android 동시발음수 32 제한 (미수정, 작업 지시)

> 상태: **미수정.** 수정 대상이 외부 GitHub 포크의 C++ 상수라 이 저장소에서 고칠 수 없다.
> 영향: 소리가 안 나는 게 아니라 **소리가 도중에 끊긴다**(voice stealing). 낮은 우선순위지만 원인이 명확하므로 기록해 둔다.
> 확인 시점: 2026-09-04.

## 무엇이 문제인가

Android 재생은 `flutter_midi_pro` 포크를 쓴다 (`mobile/pubspec.yaml` 의 `dependency_overrides`):

```
url: https://github.com/hjm181227/flutter_midi_pro.git
ref: 1d8fc682517e3e8398c3aba73abec7d39e5b0e40
```

이 포크의 `android/src/main/cpp/native-lib.cpp` 에서 **사운드폰트 하나를 로드할 때마다 FluidSynth 인스턴스와 Oboe 출력 스트림을 새로 만들고**, 각각에 다음을 고정한다:

```cpp
fluid_settings_setint(settings[nextSfId], "synth.polyphony", 32);   // ← 21행
fluid_settings_setint(settings[nextSfId], "audio.period-size", 64); // ← 17행
```

결과:

1. **동시 32 보이스 한계.** GM 신스 하나가 멜로디 + 베이스 + 멜로디필 + 드럼 + 메트로놈 클릭을 전부 담당한다. 기타 스트럼(한 번에 6음) 3레인 + 릴리즈 테일이 겹치면 32를 넘고, FluidSynth 가 오래된 보이스부터 끊는다 — 사용자에겐 "치던 소리가 갑자기 사라지는" 현상.
2. **인스턴스마다 별도 저지연 스트림.** GM + 808 + 힙합킷 + 곡이 쓰는 카탈로그 폰트 1~3개 = 최대 6개의 Oboe 스트림이 동시에 돈다. 중급 안드로이드 기기에서 글리치 유발 요인.

iOS 는 `dart_melty_soundfont` 기반이라 무관하다.

## 어떻게 고치나

### 최소 수정 (권장, 5분)

포크에 커밋 하나:

```cpp
// native-lib.cpp:21
fluid_settings_setint(settings[nextSfId], "synth.polyphony", 256);
```

FluidSynth 기본값은 256이며, 보이스는 실제로 울릴 때만 CPU 를 쓰므로 상한을 올리는 것 자체는 거의 공짜다. 그다음 `mobile/pubspec.yaml` 의 `ref` 를 새 커밋 해시로 바꾸고 `flutter pub get`.

### 근본 수정 (선택)

폰트마다 신스를 만드는 대신 **하나의 신스에 `fluid_synth_sfload` 를 여러 번** 호출하고 bank offset 으로 구분한다. 스트림이 1개로 줄어 글리치 여지가 사라지지만, `selectInstrument` / `playNote` 의 sfId 라우팅을 전부 손봐야 한다.

### 앱 쪽에서 할 수 있는 것 (포크 수정 없이)

포크의 Dart API 에 `unloadSoundfont(int sfId)` 가 이미 있는데 **앱이 한 번도 호출하지 않는다**. 곡 편집 화면을 떠날 때 그 곡에서만 쓰던 카탈로그 폰트를 내리면 동시 스트림 수가 준다.

건드릴 곳: `mobile/lib/audio/synth.dart` 의 `_slotSfId` / `_loadingSlot` / `_channelSf` 캐시. 내리기 전에 해당 채널의 노트를 모두 정지하고 세 맵에서 항목을 지워야 하며, 아니면 다음 재생에서 죽은 sfId 로 라우팅돼 **무음**이 된다.

> 이번 작업에서 하지 않은 이유: Windows 개발 환경에 Android 실기기가 없어 "무음 회귀"를 검증할 수 없었다. 포크 수정과 함께 실기기에서 한 번에 확인하는 편이 안전하다.

## 검증 방법 (Android 실기기)

1. 기타 사운드를 멜로디·멜로디필·베이스 3레인에 배정하고 코드 모드로 스트럼을 촘촘히 채운다.
2. 드럼 + 808 + 메트로놈까지 켜고 루프 재생.
3. **수정 전**: 밀도가 올라가는 지점에서 먼저 친 음이 끊긴다.
   **수정 후**: 끊기지 않는다.
4. 함께 볼 것: `adb shell dumpsys media.audio_flinger | grep -i underrun`, 그리고 곡을 여러 번 열고 닫으며 메모리 증가 추이.

## 관련

- 감사 원문: [audit-2026-09-03.md](audit-2026-09-03.md) §4 A10
- iOS 쪽 대응 사례: [lessons.md](lessons.md)
