# Track pan

- **ID:** mixer-001
- **Status:** implemented (uncommitted)
- **Inspired by:** Ableton Live 12 — Mixer Pan; FL Studio — Mixer track pan (카탈로그 MX-01)

## Sources
- https://www.ableton.com/en/live-manual/12/mixing/ : 트랙마다 Pan 손잡이가 있고, 한쪽으로 돌리면 그쪽 채널은 커지고 반대쪽은 작아진다(기본 Stereo Pan 모드). 손잡이를 더블클릭하면 기본값(가운데)으로 돌아간다.
- https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/mixer.htm : 팬은 소리를 좌우로 옮기며, 스테레오 폭(Stereo separation)은 별도 손잡이다.
- Hands-on observation 2026-10-21 (findings.json `humtrack_existing`, recommended_order 3·5): HumTrack 믹서는 트랙별 Mute/Volume만 있고 Pan이 없다.
- HumTrack 기존 동작(코드 읽음): iOS/macOS/Windows 실시간 합성(`audio/melty_synth_backend.dart`)은 신스의 스테레오 출력을 `(L+R)/2` **모노로 합쳐** 1채널로 내보낸다(`PcmOutput.setup(channelCount: 1)`; Windows 네이티브 `desktop_pcm.cpp`는 1채널만 허용). Android는 `flutter_midi_pro`(FluidSynth)이며 `controlChange(sfId, channel, controller, value)`를 제공한다. WAV 믹스와 stem은 `encodeWavMono16FromStereo`로 **모노** 파일이다. 보컬은 `bounceVocalClips`가 모노로 만들고 `audioplayers`로 재생한다.

## User-visible behavior
1. 믹서 시트(모바일)와 데스크톱 믹서 줄마다 볼륨 슬라이더 아래 **Pan** 슬라이더가 생긴다. 범위 L100…C…R100, 기본 C. 값 표시는 "L23", "C", "R40".
2. 손잡이를 끌면 재생 중인 소리가 바로 그쪽으로 옮겨진다. 더블탭/더블클릭(데스크톱은 Alt+클릭도) = C로 복귀.
3. 내보낸 WAV 믹스와 stem은 **스테레오** 파일이며 Pan이 들린 그대로 반영된다. MIDI 파일에는 채널별 Pan(CC10)이 들어간다.
4. Mute/Solo는 Pan과 무관하게 지금처럼 동작한다. Pan 변경은 Undo로 되돌린다(드래그 1회 = Undo 1회).

## 값과 법칙
- 저장 값 p ∈ [−1, 1](−1 = 왼쪽 끝). 표시 = round(|p|·100).
- **신스 트랙(멜로디·베이스·드럼·Beat-Fill·추가 트랙):** MIDI CC10으로 신스에 전달. cc = p ≤ 0 ? round(64 + 64p) : round(64 + 63p) → −1→0, 0→64, 1→127. 실시간(MeltySynth)과 WAV 렌더(MeltySynth)가 같은 신스 팬 처리를 쓰므로 iOS/데스크톱 재생과 내보내기가 같다. Android(FluidSynth)는 자체 팬 법칙이라 미세하게 다를 수 있다(허용).
- **보컬 트랙(기본 Vocal + Audio 레인, 곡 전체 보컬):** HumTrack이 직접 L/R 이득을 곱한다. 균형 법칙 gL = min(1, 1 − p), gR = min(1, 1 + p). 가운데에서는 지금과 똑같은 레벨(양쪽 1.0)이다.
- 메트로놈 클릭(ch15)은 항상 가운데.

## Edge cases
- 실시간 채널 공유: 기본 드럼 ch9, Beat-Fill ch10, 추가 트랙은 각자 할당 채널이라 트랙 = 채널 1:1이다. 악기 교체로 채널이 다른 사운드폰트 신스로 옮겨 가면(`_bindSynth`) 그 채널의 Pan을 새 신스에 다시 보낸다. 사운드폰트 재로드·출력 재구성 후에도 다시 보낸다.
- 내보내기 채널 공유: WAV 렌더는 Beat-Fill과 추가 드럼 트랙을 레인마다 따로(각자 ch9) 렌더하므로 레인별 CC10을 그 렌더의 ch9에 넣는다(지금 CC7 볼륨을 레인별로 바꿔 넣는 방식과 같음). 일반 `.mid` 내보내기는 모든 드럼 레인이 ch9 하나를 공유하므로 ch9 Pan = 기본 `drums` 값만 쓴다(문서화된 한계).
- 모든 Pan이 C이면 `.mid` 내보내기는 CC10을 쓰지 않는다 → 지금 파일과 **바이트 동일**.
- 보컬 실시간: 소리 나는 보컬 레인 중 하나라도 p ≠ 0이면 "손대지 않은 단일 테이크는 원본 파일 그대로 재생" 지름길을 쓰지 않고 스테레오 믹스 파일로 bounce한다. 곡 전체 보컬(`songVocalPath`)은 원본 파일을 재생하므로 `AudioPlayer.setBalance(p)`로 적용하고, 플랫폼이 지원하지 않으면 실시간은 가운데(내보내기는 정확히 반영).
- 스테레오 출력 전환 후에도 마스터 이득·tanh 리미터는 채널별로 같게 적용한다(가운데 소리의 음량 변화 없음).

## HumTrack design
- Model: `Song.pan: Map<String, double>`(트랙 id → p, 기본 {}; 0인 값은 저장하지 않음, 읽을 때 [−1,1] clamp). 트랙 삭제 시 키 제거.
- Code:
  - `widgets/sheets/mixer_sheet.dart`: `onPan(id, v)`, `onPanReset(id)`. 키 `mixer-pan-<id>`. 데스크톱 믹서도 같은 위젯.
  - `screens/edit_screen.dart`: `_pan` 상태, `_capture/_restore/_EditSnapshot`에 `pan` 추가, 드래그는 `_pushUndo(coalesce: true)`, 리셋은 `_pushUndo()`. 변경 시 `LoopAudio.setPan(channel, p)`, 보컬이면 `_vocalMix.clear()` 후 재bounce. `_snapshot()`에 저장.
  - `looptap/audio/loop_audio.dart`: `setPan(int channel, double p)`, `_pans` 보관 후 `prewarm`·채널 재지정 때 재전송.
  - `audio/synth.dart`: `controlChange(channel, cc, value)` — Android는 `MidiPro.controlChange`(채널의 sfId), Melty는 아래로 위임.
  - `audio/melty_synth_backend.dart`: 채널별 CC10 기억·전송(`processMidiMessage(command: 0xB0, data1: 10)`), `_bindSynth`에서 재전송. `_mixSynth`를 L/R 분리 누적으로, `PcmOutput.setup(channelCount: 2)`, 인터리브 Int16 출력.
  - `windows/runner/desktop_pcm.cpp`: `channels == 2` 허용(현재 1만 허용).
  - `music/wav_codec.dart`: `encodeWavStereo16(left, right, sr, {normalize})`(peak = max(|L|,|R|)), `mixVocalsInto`에 레인 pan 인자(위 균형 법칙). `bounceVocalClips`가 L/R 반환.
  - `music/midi_export.dart` `buildMidi(..., Map<String, double>? pan)`: CC7 옆에 채널별 CC10(t=0). 렌더용은 모든 채널에, 일반 `.mid`(`exportMidiSong`)는 p ≠ 0 채널만.
  - `music/wav_export.dart`: 믹스·stem 모두 `encodeWavStereo16`. 레인별 드럼 렌더의 ch9 CC10 = 그 레인의 p.
- UI: 데스크톱은 믹서 패널(단축키 없음, 더블클릭/Alt+클릭 리셋). 모바일은 믹서 시트.
- Export 영향: WAV 파일이 2채널이 되어 크기가 약 2배. 내보낸 WAV를 다시 읽는 코드(보관함 미리보기, 디버그 `_logWavStats`)는 채널 수를 헤더에서 읽도록 확인한다.

## Decisions (2026-10-22, owner approved)
- **이번 범위에 포함:** 실시간 출력(MeltySynth, Windows WASAPI 네이티브 C++ 포함)과 WAV 믹스·stem 내보내기를 스테레오로 전환한다. 내보내기는 항상 스테레오.
- 곡 전체 보컬의 실시간 팬은 `AudioPlayer.setBalance`가 되는 플랫폼에만 적용하고, 내보내기에는 항상 정확히 반영한다.
- Windows·iOS 실기기 확인은 구현 후 사람이 한다. 구현 보고에 확인 절차를 적는다.

## Acceptance tests
- [x] cc 매핑: p −1/−0.5/0/0.5/1 → 0/32/64/96(=round(64+31.5))/127.
- [x] `buildMidi(pan: {melody: −1})` → ch0에 `B0 0A 00`이 t=0에 있음. `pan: {}`이고 일반 `.mid` → 기존 바이트와 동일.
- [x] 레인별 드럼 렌더: Beat-Fill p=0.5 → 그 렌더 MIDI의 ch9 CC10 = 96, 기본 드럼 렌더는 64(또는 없음).
- [x] `encodeWavStereo16`: 헤더 channels=2, blockAlign=4, byteRate=sr·4, 데이터 길이 = 프레임·4.
- [x] 균형 법칙: 보컬 레인 p=−1 → 오른쪽 샘플 전부 0, 왼쪽 = 기존 모노 값. p=0 → L=R=기존 값(가운데 레벨 불변).
- [x] 렌더 통합: 멜로디 한 음, p=−1, 리버브/코러스 끈 설정 → 오른쪽 RMS < 왼쪽 RMS의 10%. (테스트는 모노 샘플 음색 GM 73 Flute 사용. 기본 피아노(GM 0)는 사운드폰트의 스테레오 샘플 자체 팬이 CC10에 더해져 오른쪽이 약 22% — 구현 보고의 열린 질문 참고.)
- [x] `Song.toJson`: pan 모두 0 → `pan` 키 없음; {bass: 0.3} → 왕복 보존; 2.0 → 1.0으로 clamp.
- [x] Undo: Pan 드래그 1회 → Undo 1회로 복원, Redo 재적용. 리셋도 Undo 1회.
- [x] Melty: 채널 0에 p 설정 후 808 신스로 재지정 → 새 신스에 CC10 재전송(가짜 신스로 메시지 기록 테스트).
- [x] 믹서 위젯: `mixer-pan-melody` 더블탭 → `onPanReset('melody')` 호출, 표시 "C".

### Manual checks (device only — not covered by tests)
- [ ] Windows 실시간: 재생 중 Pan을 끌면 신스 트랙이 즉시 좌우로 이동, C에서는 이전과 같은 음량/음색 (manual check).
- [ ] iOS(및 macOS) 실시간: 같은 확인 + 녹음 시작/종료(출력 재구성) 뒤에도 Pan 유지 (manual check).
- [ ] 곡 전체 보컬 `setBalance` 실시간 적용 여부(플랫폼별) (manual check).
- [ ] 내보낸 WAV 믹스/stem을 외부 플레이어에서 스테레오로 재생해 Pan 확인 (manual check).

## Out of scope
- 스테레오 폭/분리 팬(Split Stereo), 위상 반전(MX-08), 팬 자동화, 노트별 팬, Send/Bus(MX-03/04).
- 일반 `.mid`에서 드럼 레인별 다른 Pan(채널 구조 변경 필요).
- 레벨 미터(MX-06).
