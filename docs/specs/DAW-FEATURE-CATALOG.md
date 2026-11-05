# DAW 기능 카탈로그 (clean-room)

작성일: 2026-10-22 · 대상: HumTrack Studio (Flutter 데스크톱+모바일, 흥얼거림 → 루프/곡)

## 이 문서의 규칙

- `docs/specs/CLEANROOM.md`를 따른다. 출처는 **공식 공개 매뉴얼/도움말 페이지**와 **hands-on observation 2026-10-21**(`artifacts/ableton-analysis-20261021/findings.json`, Ableton Live 12.4.6 Trial을 블랙박스로 써 보고 남긴 관찰 기록)뿐이다.
- 디컴파일, 바이너리, 설치 파일 내용, `C:/src/re-lab`, `studio/` 프로토타입은 **보지 않았다**.
- 동작 설명은 모두 직접 바꿔 쓴 한 줄 요약이다. 매뉴얼 문장을 옮기지 않았다. 기능 이름만 원래 영어 명칭을 쓴다.
- 이 카탈로그는 **후보 목록**이다. 구현하려면 각 항목마다 `docs/specs/<area>/<feature>.md` 스펙(`_TEMPLATE.md`)을 따로 쓰고 owner 승인을 받아야 한다.
- 출처 URL은 기능이 설명된 매뉴얼 **장(chapter) 단위**다. 세부 동작은 스펙을 쓸 때 다시 확인한다.

### 열 설명

- **Seen in**: FL = FL Studio, AL = Ableton Live 12, LP = Logic Pro (Mac)
- **관련도** (흥얼거림 우선 루프/곡 앱 기준): high / medium / low
- **크기** (HumTrack 구현 추정): S = 며칠, M = 1–2주, L = 그 이상이거나 엔진 작업 필요

---

## 1. 기능 표

### 1.1 Transport & tempo

| ID | 분류 | Feature | 사용자 동작 → 결과 | Seen in | Source | 관련도 | 크기 |
|---|---|---|---|---|---|---|---|
| TR-01 | Transport | Play / Stop | 스페이스 등으로 재생/정지를 토글한다. 정지 후 다시 누르면 정해진 시작점부터 재생한다. | AL, FL | https://www.ableton.com/en/live-manual/12/arrangement-view/ · https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/toolbar_panels.htm | high | S |
| TR-02 | Transport | Pattern / Song mode | 지금 편집 중인 패턴만 반복 재생할지, 곡 전체 배치를 재생할지 고른다. | FL | https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/toolbar_panels.htm | high | S |
| TR-03 | Tempo | Tempo (BPM) 입력 | 숫자 입력이나 드래그로 BPM을 바꾸면 모든 MIDI와 워프된 오디오가 새 템포를 따른다. | AL, FL | https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/toolbar_panels.htm · https://www.ableton.com/en/live-manual/12/audio-clips-tempo-and-warping/ | high | S |
| TR-04 | Tempo | Tap tempo | 버튼을 박자에 맞춰 여러 번 두드리면 두드린 간격의 평균으로 템포가 정해진다. | FL | https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/toolbar_panels.htm#tap_tempo | high | S |
| TR-05 | Tempo | Tempo automation | 곡 템포를 오토메이션 선으로 그려 구간마다 빨라지거나 느려지게 한다. | AL | https://www.ableton.com/en/live-manual/12/automation/ | low | M |
| TR-06 | Tempo | Time signature changes | 박자표를 지정하고, 곡 중간에 박자표가 바뀌는 지점을 둔다. | AL, FL | https://www.ableton.com/en/live-manual/12/arrangement-view/ · https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/playlist.htm#playlist_TimeSignature | medium | M |
| TR-07 | Transport | Metronome | 재생/녹음 중 박마다 클릭음을 내고, 켜고 끌 수 있다. | AL, FL | https://www.ableton.com/en/live-manual/12/recording-new-clips/ · https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/toolbar_panels.htm | high | S |
| TR-08 | Transport | Loop region | 타임라인의 구간을 반복 범위로 지정하면 재생이 그 구간만 반복한다. | AL, FL | https://www.ableton.com/en/live-manual/12/arrangement-view/ · https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/playlist.htm#Playlist_TimeMarkers | high | S |
| TR-09 | Tempo | Tempo Follower | 마이크로 들어오는 소리의 박을 추적해 곡 템포를 그에 맞춰 계속 조정한다. | AL | https://www.ableton.com/en/live-manual/12/synchronizing-with-link-tempo-follower-and-midi/ | medium | L |
| TR-10 | Sync | Ableton Link | 같은 네트워크의 다른 앱/기기와 템포와 박 위치를 맞춘다. | AL | https://www.ableton.com/en/live-manual/12/synchronizing-with-link-tempo-follower-and-midi/ | low | M |
| TR-11 | Tempo | Detect tempo / Fit to tempo | 오디오 클립의 템포를 추정하거나, 클립 길이를 곡 템포에 맞게 늘이고 줄인다. | FL, AL | https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/playlist.htm · https://www.ableton.com/en/live-manual/12/audio-clips-tempo-and-warping/ | high | M |
| TR-12 | Transport | Panic / Stop sound | 한 번에 모든 울리는 음을 멈춘다(걸린 음 해소). | FL | https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/menu_tools.htm | high | S |

### 1.2 Recording

| ID | 분류 | Feature | 사용자 동작 → 결과 | Seen in | Source | 관련도 | 크기 |
|---|---|---|---|---|---|---|---|
| RC-01 | Recording | Capture MIDI (retroactive) | 녹음 버튼을 누르지 않고 연주한 뒤 Capture를 누르면 방금 연주가 클립으로 생기고, 템포와 루프 길이도 연주에서 추정된다. | AL | https://www.ableton.com/en/live-manual/12/recording-new-clips/ | high | M |
| RC-02 | Recording | Score logger dump | 항상 켜진 기록기가 최근 연주 노트를 보관하고, 원하는 시간 범위(분 단위)를 골라 선택한 패턴으로 꺼낸다. 악기별로 나뉘어 들어간다. | FL | https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/menu_tools.htm | high | M |
| RC-03 | Recording | Audio logger | 마스터 출력 오디오를 메모리에 계속 굴려 담아 두었다가 나중에 꺼낸다. 최대 길이와 이펙트 전/후 위치를 고른다. | FL | https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/menu_tools.htm | high | M |
| RC-04 | Recording | One-click audio recording | 메뉴 한 번으로 바로 오디오 녹음을 시작해 편집기나 타임라인에 넣는다. | FL | https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/menu_tools.htm · https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/recording_audio.htm | high | S |
| RC-05 | Recording | Clip slot recording (fixed length) | 빈 슬롯에서 녹음하면 새 클립이 생긴다. 고정 길이를 정해 두면 그 길이에서 자동으로 멈추고 루프가 된다. | AL | https://www.ableton.com/en/live-manual/12/recording-new-clips/ | high | M |
| RC-06 | Recording | Arrangement recording | 타임라인 위에서 재생 위치부터 직선으로 녹음한다. | AL, FL | https://www.ableton.com/en/live-manual/12/recording-new-clips/ · https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/recording_audio.htm | medium | M |
| RC-07 | Recording | MIDI overdub / blend | 반복 재생 중 녹음하면 이전 노트를 지우지 않고 새 노트를 겹쳐 쌓는다. | AL, FL | https://www.ableton.com/en/live-manual/12/recording-new-clips/ · https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/recording_scores.htm | high | M |
| RC-08 | Recording | Loop recording → take lanes | 반복 구간에서 여러 번 녹음하면 회차마다 별도 take로 쌓인다. | AL | https://www.ableton.com/en/live-manual/12/comping/ | high | M |
| RC-09 | Recording | Comping | 여러 take에서 좋은 구간만 골라 하나의 결과 클립으로 합친다. | AL | https://www.ableton.com/en/live-manual/12/comping/ | medium | L |
| RC-10 | Recording | Punch in/out | 미리 정한 구간 안에서만 녹음이 실제로 기록된다. | AL | https://www.ableton.com/en/live-manual/12/recording-new-clips/ | low | M |
| RC-11 | Recording | Record quantization | 녹음되는 노트의 시작을 격자에 자동으로 맞춘다. | AL, FL | https://www.ableton.com/en/live-manual/12/recording-new-clips/ · https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/recording_scores.htm | high | S |
| RC-12 | Recording | Count-in | 녹음 전에 정해진 마디 수만큼 박을 들려준 뒤 녹음을 시작한다. | AL, FL | https://www.ableton.com/en/live-manual/12/recording-new-clips/ · https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/toolbar_panels.htm | high | S |
| RC-13 | Recording | Step input / step editing | 재생하지 않고 건반을 누를 때마다 노트를 넣고 커서가 한 칸씩 이동한다. | AL, FL | https://www.ableton.com/en/live-manual/12/editing-midi/ · https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/toolbar_panels.htm | medium | M |
| RC-14 | Recording | Computer keyboard as piano | 컴퓨터 자판을 피아노 건반처럼 써서 노트를 연주/녹음한다. | AL, FL | https://www.ableton.com/en/live-manual/12/midi-and-key-remote-control/ · https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/recording_scores.htm | high | S |
| RC-15 | Recording | Automation recording | 재생 중 노브나 페이더를 움직이면 그 움직임이 오토메이션으로 기록된다. | AL, FL | https://www.ableton.com/en/live-manual/12/automation/ · https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/recording_automation.htm | medium | M |
| RC-16 | Recording | Input monitoring | 녹음할 트랙의 입력 소리를 실시간으로 들을지(켜기/자동/끄기) 정한다. | AL | https://www.ableton.com/en/live-manual/12/routing-and-i-o/ | medium | S |
| RC-17 | Recording | Cancel recording | 진행 중인 녹음을 버리고 만들어진 파일도 지운다. | FL | https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/menu_tools.htm | medium | S |
| RC-18 | Recording | Latency compensation | 오디오 장치 지연만큼 녹음 위치를 보정해 박에 맞게 기록한다. | FL, AL | https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/envsettings_audio.htm · https://www.ableton.com/en/live-manual/12/computer-audio-resources-and-strategies/ | high | M |

### 1.3 Piano roll / MIDI note editing

| ID | 분류 | Feature | 사용자 동작 → 결과 | Seen in | Source | 관련도 | 크기 |
|---|---|---|---|---|---|---|---|
| PR-01 | Piano roll | Draw mode | 펜 도구로 격자를 클릭/드래그해 노트를 그린다. | AL, FL | https://www.ableton.com/en/live-manual/12/editing-midi/ · https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/pianoroll.htm | high | S |
| PR-02 | Piano roll | Select & transpose | 노트를 클릭해 선택하고 위/아래 키로 반음씩 옮긴다. 세기와 시간은 그대로이고 Undo로 원래 값이 돌아온다. (hands-on observation 2026-10-21) | AL | https://www.ableton.com/en/live-manual/12/editing-midi/ | high | S |
| PR-03 | Piano roll | Move & resize | 노트 몸체 드래그로 위치를, Shift+좌/우로 시작은 둔 채 끝만 줄이거나 늘인다. (hands-on observation 2026-10-21) | AL, FL | https://www.ableton.com/en/live-manual/12/editing-midi/ · https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/pianoroll.htm | high | S |
| PR-04 | Piano roll | Velocity lane | 아래 세기 영역에서 선택 노트의 막대를 끌어 세기를 바꾼다. 음높이와 시간은 그대로다. (hands-on observation 2026-10-21) | AL, FL | https://www.ableton.com/en/live-manual/12/editing-midi/ · https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/pianoroll.htm | high | S |
| PR-05 | Piano roll | Octave shift | 선택 노트를 한 번에 한 옥타브 올리거나 내린다. | AL | https://www.ableton.com/en/live-manual/12/editing-midi/ | high | S |
| PR-06 | Piano roll | Velocity deviation | 노트마다 세기 범위를 주면 재생할 때마다 그 범위 안에서 세기가 달라진다. | AL | https://www.ableton.com/en/live-manual/12/editing-midi/ | high | S |
| PR-07 | Piano roll | Note chance (probability) | 노트마다 울릴 확률을 정해, 루프가 돌 때마다 그 노트가 날지 말지가 달라진다. | AL | https://www.ableton.com/en/live-manual/12/editing-midi/ | high | M |
| PR-08 | Piano roll | Deactivate (mute) notes | 노트를 지우지 않고 꺼 두면 화면에는 남고 소리만 나지 않는다. 데모 세트 파일에서 노트 192개 중 40개가 꺼진 채 저장된 것을 확인. (hands-on observation 2026-10-21) | AL, FL | https://www.ableton.com/en/live-manual/12/editing-midi/ · https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/pianoroll.htm | high | S |
| PR-09 | Piano roll | Split notes | 노트를 지정한 지점에서 둘로 자른다. | AL, FL | https://www.ableton.com/en/live-manual/12/editing-midi/ · https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/pianoroll.htm | high | S |
| PR-10 | Piano roll | Join / Glue | 같은 음높이로 맞닿은 노트들을 하나로 합친다. | AL, FL | https://www.ableton.com/en/live-manual/12/editing-midi/ · https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/pianoroll_menu.htm | high | S |
| PR-11 | Piano roll | Chop | 긴 노트를 격자 단위나 정한 개수로 잘게 나눈다. | AL, FL | https://www.ableton.com/en/live-manual/12/midi-tools/ · https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/pianoroll_chp.htm | medium | S |
| PR-12 | Piano roll | Quantize (amount) | 선택 노트의 시작(과 끝)을 격자에 얼마나 강하게 붙일지 비율로 정해 맞춘다. | AL, FL | https://www.ableton.com/en/live-manual/12/editing-midi/ · https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/pianoroll_qnt.htm | high | S |
| PR-13 | Piano roll | Humanize | 노트 시작 시간을 조금씩 무작위로 흐트러뜨려 기계적인 느낌을 줄인다. | AL | https://www.ableton.com/en/live-manual/12/editing-midi/ | high | S |
| PR-14 | Piano roll | Legato | 각 노트를 다음 노트 시작 지점까지 늘여 끊김 없이 잇는다. | AL, FL | https://www.ableton.com/en/live-manual/12/editing-midi/ · https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/pianoroll_menu.htm | high | S |
| PR-15 | Piano roll | Reverse / Flip | 선택 노트의 시간 순서를 뒤집거나(가로), 음높이를 위아래로 뒤집는다(세로). | AL, FL | https://www.ableton.com/en/live-manual/12/editing-midi/ · https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/pianoroll_flip.htm | medium | S |
| PR-16 | Piano roll | Stretch ×2 / ÷2 | 선택 구간 전체를 두 배 길게 또는 절반으로 줄인다. 드래그로 자유 비율도 가능. | AL, FL | https://www.ableton.com/en/live-manual/12/editing-midi/ · https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/pianoroll.htm | medium | S |
| PR-17 | Piano roll | Fit to Scale | 선택 노트 중 스케일 밖 음을 가장 가까운 스케일 음으로 옮긴다. | AL | https://www.ableton.com/en/live-manual/12/editing-midi/ | high | S |
| PR-18 | Piano roll | Scale highlight | 키와 스케일을 지정하면 스케일에 속한 줄이 강조되어 보인다. | AL, FL | https://www.ableton.com/en/live-manual/12/editing-midi/ · https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/pianoroll.htm#pianoroll_KeySignatures | high | M |
| PR-19 | Piano roll | Fold to Scale | 스케일에 속한 음 줄만 남기고 나머지 줄을 숨겨, 틀린 음을 그릴 수 없게 한다. | AL | https://www.ableton.com/en/live-manual/12/editing-midi/ | high | S |
| PR-20 | Piano roll | Fold (used notes) | 노트가 있는 음 줄만 보이게 접는다. 드럼 편집에 유용. | AL | https://www.ableton.com/en/live-manual/12/editing-midi/ | medium | S |
| PR-21 | Piano roll | Snap to scale | 노트를 그리거나 옮길 때 스케일 음에만 붙는다. | FL | https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/pianoroll.htm | high | S |
| PR-22 | Piano roll | Ghost notes | 다른 악기의 노트를 흐리게 겹쳐 보여 주어 맞춰 쓰기 쉽게 한다. | FL | https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/pianoroll.htm | high | M |
| PR-23 | Piano roll | Multi-clip editing | 여러 클립의 노트를 한 편집기에서 함께 보고 편집한다. | AL | https://www.ableton.com/en/live-manual/12/editing-midi/ | medium | L |
| PR-24 | Piano roll | Chord Stamp | 코드 종류를 고른 뒤 한 번 클릭하면 그 자리에 코드 구성음이 한꺼번에 놓인다. | FL | https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/pianoroll.htm#chordstamp_icon | high | S |
| PR-25 | Piano roll | Chord progression tool | 진행을 골라 선택한 악기 패턴에 코드 진행을 깔아 준다. | FL | https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/pianoroll_chordprogression.htm | high | M |
| PR-26 | Piano roll | Stacks (chord generator) | 클립 스케일 안에서 코드나 코드 진행을 생성해 넣는다. | AL | https://www.ableton.com/en/live-manual/12/midi-tools/ | high | M |
| PR-27 | Piano roll | Arpeggiate (tool) | 선택한 코드 노트를 패턴(상행/하행 등)에 따라 펼친 노트열로 바꿔 쓴다. | AL, FL | https://www.ableton.com/en/live-manual/12/midi-tools/ · https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/pianoroll_arpeggiate.htm | high | M |
| PR-28 | Piano roll | Strum | 코드 노트들의 시작을 조금씩 어긋나게 해 기타를 긁는 듯하게 만든다. 세기도 함께 기울일 수 있다. | AL, FL | https://www.ableton.com/en/live-manual/12/midi-tools/ · https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/pianoroll_strum.htm | high | S |
| PR-29 | Piano roll | Flam / Ornament | 노트 바로 앞에 짧은 꾸밈음이나 겹치는 타격을 덧붙인다. | AL, FL | https://www.ableton.com/en/live-manual/12/midi-tools/ · https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/pianoroll_flam.htm | medium | S |
| PR-30 | Piano roll | Connect | 기존 노트 사이 빈틈에 경과음을 무작위로 채운다. | AL | https://www.ableton.com/en/live-manual/12/midi-tools/ | medium | M |
| PR-31 | Piano roll | Recombine | 선택 노트끼리 위치·음높이·길이·세기를 서로 바꿔 변형을 만든다. | AL | https://www.ableton.com/en/live-manual/12/midi-tools/ | medium | S |
| PR-32 | Piano roll | Span / Articulate | 노트 길이를 레가토·테누토·스타카토 같은 주법 길이로 한꺼번에 맞춘다. | AL, FL | https://www.ableton.com/en/live-manual/12/midi-tools/ · https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/pianoroll_menu.htm | medium | S |
| PR-33 | Piano roll | Velocity Shaper / Scale levels | 그린 곡선이나 배율·오프셋으로 선택 노트의 세기를 일괄 재구성한다. | AL, FL | https://www.ableton.com/en/live-manual/12/midi-tools/ · https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/pianoroll_scale.htm | medium | S |
| PR-34 | Piano roll | Limit (range) | 노트를 지정한 음역 안으로 옥타브 단위로 접어 넣는다. | FL | https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/pianoroll_limit.htm | high | S |
| PR-35 | Piano roll | Randomize | 스케일 안에서 무작위 노트를 만들거나 기존 노트 값을 무작위로 흔든다. | FL | https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/pianoroll_random.htm | medium | S |
| PR-36 | Piano roll | LFO tool | 노트 속성(피치벤드 등)에 주기적인 파형 변화를 그려 넣는다. | AL, FL | https://www.ableton.com/en/live-manual/12/midi-tools/ · https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/pianoroll_lfo.htm | low | M |
| PR-37 | Piano roll | Riff machine | 몇 단계 마법사로 리프 패턴을 자동 생성하고 어울리는 악기를 붙인다. | FL | https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/pianoroll_riff.htm | medium | L |
| PR-38 | Piano roll | Seed generator | 정한 음높이·길이·세기 범위에서 무작위 노트를 생성한다. | AL | https://www.ableton.com/en/live-manual/12/midi-tools/ | medium | M |
| PR-39 | Piano roll | Rhythm generator | 한 음(드럼 패드)에 대해 반복 리듬 패턴을 생성한다. | AL | https://www.ableton.com/en/live-manual/12/midi-tools/ | high | M |
| PR-40 | Piano roll | Euclidean generator | 박 수와 타격 수로 고르게 흩어진 리듬을 최대 4성부까지 만든다. | AL | https://www.ableton.com/en/live-manual/12/midi-tools/ | medium | S |
| PR-41 | Piano roll | Shape generator | 그린 모양을 따라 음역에 노트를 흩어 배치한다. | AL | https://www.ableton.com/en/live-manual/12/midi-tools/ | low | M |
| PR-42 | Piano roll | Slide / portamento notes | 특정 노트를 다음 음으로 미끄러지듯 이어지게 표시한다. | FL | https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/pianoroll.htm | medium | M |
| PR-43 | Piano roll | Glissando | 한 노트에서 다음 노트로 음높이를 연속으로 휘게 한다. | AL | https://www.ableton.com/en/live-manual/12/midi-tools/ | low | M |
| PR-44 | Piano roll | Duplicate / Duplicate loop | 선택 노트를 바로 뒤에 복사하거나, 루프 구간과 그 안의 노트를 두 배로 늘린다. | AL, FL | https://www.ableton.com/en/live-manual/12/editing-midi/ · https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/pianoroll_menu.htm | high | S |
| PR-45 | Piano roll | Insert / delete time | 클립 중간에 빈 시간을 끼우거나 구간을 지워 뒤를 당긴다. | AL | https://www.ableton.com/en/live-manual/12/editing-midi/ | medium | S |
| PR-46 | Piano roll | Crop clip | 루프 밖의 노트와 구간을 잘라낸다. | AL | https://www.ableton.com/en/live-manual/12/editing-midi/ | low | S |
| PR-47 | Piano roll | Grid / snap settings | 격자 간격(자동/고정, 셋잇단)을 바꾸고 스냅을 켜고 끈다. | AL, FL | https://www.ableton.com/en/live-manual/12/editing-midi/ · https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/toolbar_panels.htm#panel_globalsnap | high | S |
| PR-48 | Piano roll | Note preview | 노트를 그리거나 클릭하면 그 음이 바로 들린다. | AL, FL | https://www.ableton.com/en/live-manual/12/editing-midi/ · https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/pianoroll.htm | high | S |
| PR-49 | Piano roll | Play selected / Paint | 선택 노트만 들어 보거나, 드래그로 같은 노트를 연속으로 칠한다. | FL | https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/pianoroll.htm | medium | S |
| PR-50 | Piano roll | Event / CC lanes | 피치벤드·모듈레이션 같은 연속 값을 노트 아래 레인에 그린다. | AL, FL | https://www.ableton.com/en/live-manual/12/clip-envelopes/ · https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/automation_eventeditor.htm | low | M |
| PR-51 | Piano roll | MPE per-note expression | 노트마다 피치·압력·슬라이드 곡선을 따로 편집한다. | AL | https://www.ableton.com/en/live-manual/12/editing-mpe/ | low | L |
| PR-52 | Piano roll | Tuning systems | 12평균율이 아닌 음률을 불러와 노트 줄과 재생 음높이를 바꾼다. | AL | https://www.ableton.com/en/live-manual/12/using-tuning-systems/ | low | L |
| PR-53 | Piano roll | Color groups | 노트에 색 그룹을 지정해 성부를 구분하고 선택한다. | FL | https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/pianoroll.htm#Pianoroll_ColorGroups | low | S |
| PR-54 | Piano roll | Magic lasso / select tools | 자유 모양으로 감싸거나 범위로 노트를 골라 선택한다. | FL | https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/pianoroll.htm | medium | S |

### 1.4 Step sequencer / channel rack / drum rack

| ID | 분류 | Feature | 사용자 동작 → 결과 | Seen in | Source | 관련도 | 크기 |
|---|---|---|---|---|---|---|---|
| ST-01 | Step seq | Step grid | 악기 줄마다 16분음표 칸을 눌러 켜고 끄면 그 박에서 소리가 난다. | FL | https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/channelrack.htm | high | M |
| ST-02 | Step seq | Graph editor | 칸마다 세기·팬·미세 음높이·시간 밀림·반복 등을 막대 그래프로 조절한다. | FL | https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/channelrack.htm | medium | M |
| ST-03 | Step seq | Swing (global + per channel) | 전체 스윙 양을 정하고 악기별로 스윙 적용 배율을 따로 준다. | FL | https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/channelrack.htm · https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/chansettings_misc.htm | high | S |
| ST-04 | Step seq | Fill each N steps | 2·4·8칸마다 자동으로 칸을 채운다. 고급 채우기는 패턴·오프셋을 더 정한다. | FL | https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/channelrack.htm · https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/stepsequencer_advancedfilltool.htm | high | S |
| ST-05 | Step seq | Rotate steps | 한 줄의 패턴을 좌우로 한 칸씩 돌린다. | FL | https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/channelrack.htm | medium | S |
| ST-06 | Step seq | Per-channel loop length | 악기마다 다른 반복 길이를 줘서 폴리미터를 만든다. | FL | https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/channelrack.htm | medium | M |
| ST-07 | Step seq | Generate steps / Loop Starter | 주사위나 장르 선택으로 드럼 리듬과 샘플 조합을 무작위로 시작한다. | FL | https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/channelrack.htm | high | M |
| ST-08 | Step seq | Pattern selector | 여러 패턴을 만들고 전환·복제해 곡의 재료로 쓴다. | FL | https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/channelrack.htm#channelrack_patternselector | high | M |
| ST-09 | Drum rack | Drum pads | 패드마다 샘플(또는 장치 체인)을 하나씩 두고 한 음 = 한 소리로 연주한다. | AL | https://www.ableton.com/en/live-manual/12/instrument-drum-and-effect-racks/ | high | M |
| ST-10 | Drum rack | Pad sample swap | 패드에 샘플을 끌어 놓거나 교체하면 기존 노트는 그대로이고 소리만 바뀐다. | AL | https://www.ableton.com/en/live-manual/12/instrument-drum-and-effect-racks/ | high | S |
| ST-11 | Drum rack | Choke groups | 같은 그룹의 패드가 울리면 다른 패드 소리가 끊긴다(열린/닫힌 하이햇). | AL | https://www.ableton.com/en/live-manual/12/instrument-drum-and-effect-racks/ | medium | S |
| ST-12 | Drum rack | Drum Sampler controls | 원샷 샘플의 시작점·길이·음높이·엔벨로프를 패드별로 조절한다. | AL | https://www.ableton.com/en/live-manual/12/live-instrument-reference/ | medium | M |
| ST-13 | Channel rack | Channel groups / filter | 악기 줄을 그룹으로 묶고 그룹만 보이게 걸러 본다. | FL | https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/channelrack.htm | low | S |

### 1.5 Patterns, clips & scenes (session)

| ID | 분류 | Feature | 사용자 동작 → 결과 | Seen in | Source | 관련도 | 크기 |
|---|---|---|---|---|---|---|---|
| CL-01 | Session | Clip grid | 트랙 × 씬 칸에 클립을 두고, 칸을 눌러 박에 맞춰 재생/정지한다. | AL | https://www.ableton.com/en/live-manual/12/session-view/ | medium | L |
| CL-02 | Session | Scene launch | 가로 한 줄(씬)을 한꺼번에 실행해 곡의 한 섹션으로 전환한다. | AL | https://www.ableton.com/en/live-manual/12/session-view/ | medium | M |
| CL-03 | Session | Launch quantization | 클립을 눌러도 다음 마디/박 경계에서 시작되게 한다. | AL | https://www.ableton.com/en/live-manual/12/launching-clips/ | medium | S |
| CL-04 | Session | Clip follow actions | 클립이 정한 시간만큼 재생된 뒤 다음/이전/무작위 클립으로 자동 전환한다. | AL | https://www.ableton.com/en/live-manual/12/launching-clips/ | medium | M |
| CL-05 | Session | Scene follow actions | 씬 단위로 다음 씬 이동 규칙을 줘 곡을 자동 진행한다. | AL | https://www.ableton.com/en/live-manual/12/launching-clips/ | medium | M |
| CL-06 | Clip | Start / End / Loop | 클립의 재생 시작·끝과 루프 위치·길이를 따로 정하고 루프를 켜고 끈다. (hands-on observation 2026-10-21) | AL | https://www.ableton.com/en/live-manual/12/clip-view/ | high | S |
| CL-07 | Clip | Duplicate loop | 클립 루프와 내용을 한 번에 두 배로 늘린다. 실행 후 미리보기 범위가 늘어난 것을 관찰. (hands-on observation 2026-10-21) | AL | https://www.ableton.com/en/live-manual/12/clip-view/ · https://www.ableton.com/en/live-manual/12/editing-midi/ | high | S |
| CL-08 | Session | Session → Arrangement record | 클립을 실행하며 연주한 흐름을 타임라인에 그대로 기록한다. | AL | https://www.ableton.com/en/live-manual/12/session-view/ | medium | M |
| CL-09 | Session | Launch modes | 누르는 방식(한 번/누르는 동안/토글/반복)에 따라 클립 재생 규칙이 달라진다. | AL | https://www.ableton.com/en/live-manual/12/launching-clips/ | low | S |
| CL-10 | Session | Live Loops | 셀 격자에 루프를 두고 템포에 맞춰 시작/정지하며 섹션을 만든다. | LP | https://support.apple.com/guide/logicpro/control-live-loops-logic-pro-devices-lgcp00c0b301/mac | medium | L |
| CL-11 | Session | Playlist performance mode | 타임라인의 클립들을 라이브 연주용 트리거로 바꿔 실행한다. | FL | https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/playlist_performance.htm | low | L |
| CL-12 | Clip | Clip envelopes | 클립 안에 음량·필터 등의 변화 곡선을 넣고, 클립과 다른 길이로 반복시킬 수 있다. | AL | https://www.ableton.com/en/live-manual/12/clip-envelopes/ | medium | M |

### 1.6 Arrangement / playlist

| ID | 분류 | Feature | 사용자 동작 → 결과 | Seen in | Source | 관련도 | 크기 |
|---|---|---|---|---|---|---|---|
| AR-01 | Arrangement | Pattern clips on timeline | 패턴을 타임라인에 클립으로 여러 번 배치해 곡을 짠다. | FL | https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/playlist_patterns.htm | high | M |
| AR-02 | Arrangement | Linked clip instances | 같은 패턴의 여러 배치가 내용을 공유해, 하나를 고치면 모두 바뀐다. | FL | https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/playlist.htm | high | M |
| AR-03 | Arrangement | Make unique | 연결된 클립 하나를 독립 사본으로 떼어내 따로 고칠 수 있게 한다. | FL | https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/playlist.htm#ClipMenus | high | S |
| AR-04 | Arrangement | Slip edit | 클립 경계는 그대로 두고 안의 내용만 앞뒤로 민다. | FL | https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/playlist.htm | high | M |
| AR-05 | Arrangement | Ripple edit | 클립 한쪽 끝을 늘이거나 줄이면서 내용도 함께 밀린다. | FL | https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/playlist.htm | medium | M |
| AR-06 | Arrangement | Slice clip | 칼 도구로 클립을 원하는 위치에서 둘로 자른다. | FL, AL | https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/playlist.htm · https://www.ableton.com/en/live-manual/12/arrangement-view/ | high | S |
| AR-07 | Arrangement | Chop clip by bar/beat | 클립을 마디나 박 단위 조각들로 한 번에 나눈다. | FL | https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/playlist.htm | medium | S |
| AR-08 | Arrangement | Time markers / locators | 이름 붙은 표식으로 섹션(인트로·후렴)을 표시하고 그 위치로 바로 이동한다. | FL, AL | https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/playlist.htm#Playlist_TimeMarkers · https://www.ableton.com/en/live-manual/12/arrangement-view/ | high | S |
| AR-09 | Arrangement | Consolidate | 여러 클립/구간을 하나의 클립(또는 오디오)으로 합친다. | AL, FL | https://www.ableton.com/en/live-manual/12/arrangement-view/ · https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/playlist.htm | medium | M |
| AR-10 | Arrangement | Multiple arrangements | 같은 프로젝트 안에 곡 배치를 여러 버전으로 두고 복제·전환한다. | FL | https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/playlist.htm | medium | M |
| AR-11 | Arrangement | Track groups | 트랙을 부모/자식으로 묶어 접고 펴며 함께 다룬다. | FL, AL | https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/playlist.htm · https://www.ableton.com/en/live-manual/12/mixing/ | medium | M |
| AR-12 | Arrangement | Insert / delete / duplicate time | 전체 트랙에 걸쳐 시간 구간을 끼우거나 지우거나 복제한다. | AL | https://www.ableton.com/en/live-manual/12/arrangement-view/ | medium | M |
| AR-13 | Arrangement | Clip deactivate | 타임라인 클립을 지우지 않고 꺼서 소리만 뺀다. | AL | https://www.ableton.com/en/live-manual/12/arrangement-view/ | high | S |
| AR-14 | Arrangement | Freeze / flatten | 무거운 트랙을 임시로 오디오로 굳혀 CPU를 아끼고, 필요하면 확정한다. | AL | https://www.ableton.com/en/live-manual/12/computer-audio-resources-and-strategies/ | medium | M |
| AR-15 | Arrangement | Lock track to content | 트랙을 특정 클립에 고정해, 그 트랙을 클릭하면 항상 그 클립이 놓인다. | FL | https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/playlist.htm | low | S |
| AR-16 | Arrangement | Track mode linking | 악기·타임라인 트랙·믹서 트랙을 한 묶음으로 연결해 함께 만든다. | FL | https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/playlist.htm | medium | M |
| AR-17 | Arrangement | Chord track | 곡 전체에 코드 진행 레인을 두고, 코드를 반복 구간으로 묶어 반복할 수 있다. | LP | https://support.apple.com/guide/logicpro/loop-chords-on-the-chord-track-lgcpc32d0e1b/mac | high | L |
| AR-18 | Arrangement | Clip snapping & drag-copy | 클립을 격자에 붙여 끌고, 수정키와 함께 끌면 복사된다. | AL, FL | https://www.ableton.com/en/live-manual/12/arrangement-view/ · https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/playlist.htm | high | S |

### 1.7 Audio editing

| ID | 분류 | Feature | 사용자 동작 → 결과 | Seen in | Source | 관련도 | 크기 |
|---|---|---|---|---|---|---|---|
| AU-01 | Audio | Warp (time-stretch) | 오디오를 곡 템포에 맞춰 음높이 변화 없이 늘이고 줄인다. | AL, FL | https://www.ableton.com/en/live-manual/12/audio-clips-tempo-and-warping/ · https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/chansettings_sampler.htm | high | L |
| AU-02 | Audio | Warp modes | 리듬·음정·질감 등 재료 성격에 맞는 늘이기 방식을 고른다. | AL | https://www.ableton.com/en/live-manual/12/audio-clips-tempo-and-warping/ | medium | L |
| AU-03 | Audio | Warp markers | 오디오의 특정 지점을 박자 위치에 고정해 부분적으로 타이밍을 고친다. | AL | https://www.ableton.com/en/live-manual/12/audio-clips-tempo-and-warping/ | medium | M |
| AU-04 | Audio | Quantize audio | 오디오의 타격 지점을 찾아 격자에 맞게 움직인다. | AL | https://www.ableton.com/en/live-manual/12/audio-clips-tempo-and-warping/ | high | M |
| AU-05 | Audio | Transpose / detune | 오디오 클립의 음높이를 반음·센트 단위로 바꾼다. | AL | https://www.ableton.com/en/live-manual/12/audio-clips-tempo-and-warping/ | high | M |
| AU-06 | Audio | Reverse | 오디오 클립을 거꾸로 재생되게 뒤집는다. | AL | https://www.ableton.com/en/live-manual/12/audio-clips-tempo-and-warping/ | medium | S |
| AU-07 | Audio | Fades & crossfades | 클립 시작/끝에 페이드를 걸고, 겹친 클립 사이를 교차 페이드한다. | AL, FL | https://www.ableton.com/en/live-manual/12/arrangement-view/ · https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/playlist_audioclip.htm | high | S |
| AU-08 | Audio | Clip gain | 클립 자체의 음량을 트랙 페이더와 별개로 조절한다. | AL | https://www.ableton.com/en/live-manual/12/clip-view/ | high | S |
| AU-09 | Audio | Slice to new MIDI track | 오디오를 타격·박 단위로 잘라 패드에 나누고, 그 순서대로 치는 MIDI 클립을 만든다. | AL | https://www.ableton.com/en/live-manual/12/audio-clips-tempo-and-warping/ | high | M |
| AU-10 | Audio | Convert Melody to MIDI | 단선율 오디오를 분석해 노트가 담긴 MIDI 클립을 새 트랙에 만든다. | AL | https://www.ableton.com/en/live-manual/12/converting-audio-to-midi/ | high | L |
| AU-11 | Audio | Convert Drums to MIDI | 드럼 오디오에서 킥·스네어·하이햇 타격을 찾아 드럼 MIDI로 바꾼다. | AL | https://www.ableton.com/en/live-manual/12/converting-audio-to-midi/ | high | L |
| AU-12 | Audio | Convert Harmony to MIDI | 화음이 있는 오디오에서 여러 음을 동시에 추출해 MIDI로 만든다. | AL | https://www.ableton.com/en/live-manual/12/converting-audio-to-midi/ | medium | L |
| AU-13 | Audio | Pitch correction | 녹음된 음을 노트 단위로 보여 주고 음정·길이·비브라토를 고친다. | FL | https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/plugins/Newtone.htm | high | L |
| AU-14 | Audio | Stem separation | 섞인 음원을 보컬·드럼·베이스·기타 등 따로 된 트랙으로 나눈다. | AL, FL, LP | https://www.ableton.com/en/live-manual/12/stem-separation/ · https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/menu_tools.htm · https://support.apple.com/guide/logicpro/extract-vocal-instrumental-stems-stem-lgcp61bae908/mac | medium | L |
| AU-15 | Audio | Deverb | 오디오 클립의 울림(잔향)을 줄인다. | FL | https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/playlist.htm | medium | L |
| AU-16 | Audio | Audio clip envelopes | 오디오 클립 안에 음량·팬 변화를 그린다. | FL | https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/playlist_audioclip.htm | medium | S |
| AU-17 | Audio | Sampler slicing | 샘플을 타격 지점별로 나눠 각 조각을 건반에 배치해 연주한다. | AL | https://www.ableton.com/en/live-manual/12/live-instrument-reference/ | medium | M |
| AU-18 | Audio | Bounce to audio | 트랙이나 선택 구간을 효과까지 포함한 오디오로 굳혀 새 트랙이나 제자리에 둔다. | AL | https://www.ableton.com/en/live-manual/12/bounce-to-audio/ | medium | M |
| AU-19 | Audio | Sample editor | 별도 편집기에서 오디오를 자르고 노멀라이즈·노이즈 제거 등을 한다. | FL | https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/plugins/Edison.htm | low | L |
| AU-20 | Audio | Time warping editor | 오디오의 박 위치를 마커로 잡아 시간 흐름을 고친다. | FL | https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/plugins/Newtime.htm | low | L |

### 1.8 Mixer

| ID | 분류 | Feature | 사용자 동작 → 결과 | Seen in | Source | 관련도 | 크기 |
|---|---|---|---|---|---|---|---|
| MX-01 | Mixer | Volume / Pan | 트랙마다 음량과 좌우 위치를 조절한다. | AL, FL | https://www.ableton.com/en/live-manual/12/mixing/ · https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/mixer.htm | high | S |
| MX-02 | Mixer | Mute / Solo | 트랙을 끄거나 혼자 듣는다. Solo를 켜면 다른 트랙이 비활성 표시되고, 풀면 원래 상태로 돌아온다. (hands-on observation 2026-10-21) | AL, FL | https://www.ableton.com/en/live-manual/12/mixing/ · https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/mixer.htm | high | S |
| MX-03 | Mixer | Sends / returns | 여러 트랙이 하나의 공용 효과(리버브 등)로 양을 정해 보낸다. | AL, FL | https://www.ableton.com/en/live-manual/12/mixing/ · https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/mixer.htm | medium | M |
| MX-04 | Mixer | Group / bus tracks | 여러 트랙을 한 버스로 모아 한꺼번에 음량·효과를 건다. | AL, FL | https://www.ableton.com/en/live-manual/12/mixing/ · https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/mixer.htm | medium | M |
| MX-05 | Mixer | Sidechain | 다른 트랙 소리(킥 등)에 따라 이 트랙의 압축/음량이 반응한다(덕킹). | AL, FL | https://www.ableton.com/en/live-manual/12/live-audio-effect-reference/ · https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/mixer.htm | medium | M |
| MX-06 | Mixer | Level meters | 트랙과 마스터의 레벨과 클리핑을 미터로 보여 준다. | AL, FL | https://www.ableton.com/en/live-manual/12/mixing/ · https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/mixer.htm | high | S |
| MX-07 | Mixer | Insert effect slots | 트랙마다 여러 효과를 순서대로 꽂고 켜고 끈다. | AL, FL | https://www.ableton.com/en/live-manual/12/working-with-instruments-and-effects/ · https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/mixer.htm | high | M |
| MX-08 | Mixer | Stereo separation / phase invert | 트랙 스테레오 폭을 좁히거나 넓히고 위상을 뒤집는다. | FL | https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/mixer.htm | low | S |
| MX-09 | Mixer | Track delay | 트랙 재생 시점을 밀리초 단위로 앞당기거나 늦춘다. | AL | https://www.ableton.com/en/live-manual/12/mixing/ | low | S |
| MX-10 | Mixer | Crossfader | 두 그룹의 트랙 사이를 디제이처럼 한 손잡이로 섞는다. | AL | https://www.ableton.com/en/live-manual/12/mixing/ | low | M |
| MX-11 | Mixer | Delay compensation | 효과가 만드는 지연을 자동 보정해 트랙끼리 박이 어긋나지 않게 한다. | FL | https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/mixer_trackprops.htm | low | M |
| MX-12 | Mixer | Cue / preview output | 곡 출력과 별개의 출력으로 미리 듣기를 한다. | AL | https://www.ableton.com/en/live-manual/12/mixing/ | low | M |

### 1.9 Devices: instruments & effects

| ID | 분류 | Feature | 사용자 동작 → 결과 | Seen in | Source | 관련도 | 크기 |
|---|---|---|---|---|---|---|---|
| DV-01 | Devices | Hot-swap preset | 장치를 선택하고 교체 모드에 들어가 브라우저에서 다른 프리셋을 고르면 노트는 두고 소리만 바뀐다. 교체 모드 진입·이탈 시 기존 장치 유지 확인. (hands-on observation 2026-10-21) | AL | https://www.ableton.com/en/live-manual/12/working-with-the-browser/ | high | M |
| DV-02 | Devices | Instrument rack (layering) | 여러 악기를 한 묶음에 병렬로 넣어 겹치거나 음역/세기로 나눈다. | AL | https://www.ableton.com/en/live-manual/12/instrument-drum-and-effect-racks/ | medium | M |
| DV-03 | MIDI effect | Arpeggiator | 누르고 있는 코드를 실시간으로 정한 패턴·속도의 분산화음으로 연주한다. | AL | https://www.ableton.com/en/live-manual/12/live-midi-effect-reference/ | high | M |
| DV-04 | MIDI effect | Chord | 한 음을 넣으면 정해 둔 음정들을 더해 코드로 울린다. | AL | https://www.ableton.com/en/live-manual/12/live-midi-effect-reference/ | high | S |
| DV-05 | MIDI effect | Scale | 들어오는 음을 정한 스케일 음으로 실시간 대응시킨다. | AL | https://www.ableton.com/en/live-manual/12/live-midi-effect-reference/ | high | S |
| DV-06 | MIDI effect | Random | 들어오는 음의 음높이를 확률적으로 바꿔 변화를 준다. | AL | https://www.ableton.com/en/live-manual/12/live-midi-effect-reference/ | medium | S |
| DV-07 | MIDI effect | Pitch / Velocity / Note Length | 들어오는 음을 이조하거나 세기 곡선·길이를 바꾼다. | AL | https://www.ableton.com/en/live-manual/12/live-midi-effect-reference/ | low | S |
| DV-08 | Instrument | Sampler / Simpler | 샘플 하나를 건반 전체로 음높이를 바꿔 연주한다. | AL, FL | https://www.ableton.com/en/live-manual/12/live-instrument-reference/ · https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/chansettings_sampler.htm | high | M |
| DV-09 | Instrument | Synthesizers | 내장 신스로 음색을 만들고 프리셋을 고른다. | AL, FL | https://www.ableton.com/en/live-manual/12/live-instrument-reference/ · https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/generator_plugins.htm | medium | L |
| DV-10 | Effect | EQ | 주파수 대역별로 소리를 깎거나 올린다. | AL | https://www.ableton.com/en/live-manual/12/live-audio-effect-reference/ | medium | M |
| DV-11 | Effect | Compressor / Glue | 큰 소리를 눌러 음량을 고르게 하고 덩어리감을 준다. | AL | https://www.ableton.com/en/live-manual/12/live-audio-effect-reference/ | medium | M |
| DV-12 | Effect | Reverb | 공간 울림을 더한다. | AL | https://www.ableton.com/en/live-manual/12/live-audio-effect-reference/ | high | M |
| DV-13 | Effect | Delay / Echo | 박에 맞춘 메아리를 더한다. | AL | https://www.ableton.com/en/live-manual/12/live-audio-effect-reference/ | high | M |
| DV-14 | Effect | Auto Filter | 필터로 밝기를 바꾸고 LFO·엔벨로프로 움직이게 한다. 데모 세트의 Strum 트랙 체인에 쓰인 것을 관찰. (hands-on observation 2026-10-21) | AL | https://www.ableton.com/en/live-manual/12/live-audio-effect-reference/ | high | M |
| DV-15 | Effect | Saturation / distortion | 배음을 더해 소리를 두껍게 하거나 거칠게 한다. | AL | https://www.ableton.com/en/live-manual/12/live-audio-effect-reference/ | medium | M |
| DV-16 | Effect | Tuner | 들어오는 소리의 음높이와 가장 가까운 음, 차이를 보여 준다. | AL | https://www.ableton.com/en/live-manual/12/live-audio-effect-reference/ | medium | S |
| DV-17 | Effect | Vocoder | 목소리의 모양을 다른 소리(신스)에 입혀 '말하는 신스'를 만든다. | AL | https://www.ableton.com/en/live-manual/12/live-audio-effect-reference/ | medium | L |
| DV-18 | Devices | Device presets | 장치 설정을 프리셋으로 저장하고 다시 불러온다. | AL | https://www.ableton.com/en/live-manual/12/working-with-instruments-and-effects/ | medium | S |
| DV-19 | Devices | Device chain order / bypass | 장치 순서를 끌어서 바꾸고 각 장치를 켜고 끈다. | AL | https://www.ableton.com/en/live-manual/12/working-with-instruments-and-effects/ | medium | S |
| DV-20 | Devices | Smart disable | 소리를 내지 않는 플러그인을 자동으로 쉬게 해 CPU를 아낀다. | FL | https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/menu_tools.htm | medium | S |
| DV-21 | Devices | Plug-in hosting | 외부 VST/AU 플러그인을 불러 악기/효과로 쓴다. | AL | https://www.ableton.com/en/live-manual/12/using-plug-ins/ | low | L |

### 1.10 Automation & modulation

| ID | 분류 | Feature | 사용자 동작 → 결과 | Seen in | Source | 관련도 | 크기 |
|---|---|---|---|---|---|---|---|
| AM-01 | Automation | Breakpoint envelopes | 파라미터 레인에 점을 찍고 이어 시간에 따른 값 변화를 그린다. | AL, FL | https://www.ableton.com/en/live-manual/12/automation/ · https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/playlist_automationclip.htm | medium | M |
| AM-02 | Automation | Automation shapes | 미리 만든 모양(사인·램프 등)을 선택 구간에 한 번에 그려 넣는다. | AL | https://www.ableton.com/en/live-manual/12/automation/ | medium | S |
| AM-03 | Automation | Curved segments | 두 점 사이 선을 곡선으로 휘게 한다. | AL | https://www.ableton.com/en/live-manual/12/automation/ | low | S |
| AM-04 | Automation | Automation clips | 오토메이션을 독립 클립으로 만들어 타임라인에 배치·복제한다. | FL | https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/playlist_automationclip.htm | medium | M |
| AM-05 | Automation | Last tweaked → automation | 방금 만진 노브로 바로 오토메이션 클립이나 컨트롤러 연결을 만든다. | FL | https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/menu_tools.htm | medium | S |
| AM-06 | Automation | Override / re-enable | 손으로 값을 바꾸면 오토메이션이 일시 해제되고, 버튼으로 다시 따르게 한다. | AL | https://www.ableton.com/en/live-manual/12/automation/ | low | S |
| AM-07 | Modulation | Macros | 여러 파라미터를 한 손잡이에 묶어 한 번에 움직인다. | AL | https://www.ableton.com/en/live-manual/12/instrument-drum-and-effect-racks/ | high | M |
| AM-08 | Modulation | Macro variations / randomize | 매크로 값 조합을 스냅샷으로 저장해 전환하거나 무작위로 섞는다. | AL | https://www.ableton.com/en/live-manual/12/instrument-drum-and-effect-racks/ | medium | M |
| AM-09 | Modulation | Clip modulation envelopes | 클립 안에서 원래 값을 기준으로 상대적인 변화를 준다. | AL | https://www.ableton.com/en/live-manual/12/clip-envelopes/ | low | M |
| AM-10 | Control | MIDI / key mapping | 하드웨어 컨트롤이나 자판 키를 화면의 파라미터·버튼에 연결한다. | AL, FL | https://www.ableton.com/en/live-manual/12/midi-and-key-remote-control/ · https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/basics_controllers.htm | low | M |

### 1.11 Browser & library

| ID | 분류 | Feature | 사용자 동작 → 결과 | Seen in | Source | 관련도 | 크기 |
|---|---|---|---|---|---|---|---|
| BR-01 | Browser | Categories | 소리/드럼/악기/효과/샘플 범주로 라이브러리를 탐색한다. | AL | https://www.ableton.com/en/live-manual/12/working-with-the-browser/ | high | M |
| BR-02 | Browser | Preview in tempo | 목록에서 소리를 고르면 곡 템포에 맞춰 미리 들려준다. | AL | https://www.ableton.com/en/live-manual/12/working-with-the-browser/ | high | S |
| BR-03 | Browser | Search | 이름이나 태그로 라이브러리를 검색한다. | AL, FL | https://www.ableton.com/en/live-manual/12/working-with-the-browser/ · https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/menu_tools.htm | medium | S |
| BR-04 | Browser | Tags / collections | 소리에 색 라벨·태그를 달아 즐겨찾기 모음을 만든다. | AL | https://www.ableton.com/en/live-manual/12/working-with-the-browser/ | high | S |
| BR-05 | Browser | Similar sound search | 고른 소리와 비슷한 소리를 찾아 추천한다. | AL | https://www.ableton.com/en/live-manual/12/working-with-the-browser/ | medium | L |
| BR-06 | Browser | Online sound library | 앱 안에서 온라인 샘플/루프 라이브러리를 찾아 내려받는다. | FL | https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/menu_tools.htm | medium | L |
| BR-07 | Browser | Current project view | 프로젝트에 쓰인 패턴·샘플·플러그인·편집 기록을 목록으로 본다. | FL | https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/browser.htm#Browser_CurrentProject | low | M |
| BR-08 | Browser | Clipboard to file | 클립보드의 MIDI/오디오를 파일로 저장해 라이브러리에 남긴다. | FL | https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/menu_tools.htm | low | S |
| BR-09 | Browser | Purge unused | 쓰지 않는 오디오 클립·채널을 찾아 지운다. | FL | https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/menu_tools.htm | low | S |

### 1.12 Groove & swing

| ID | 분류 | Feature | 사용자 동작 → 결과 | Seen in | Source | 관련도 | 크기 |
|---|---|---|---|---|---|---|---|
| GR-01 | Groove | Groove Pool | 그루브 파일을 클립에 지정하면 재생 타이밍과 세기가 그 느낌을 따른다(비파괴). | AL | https://www.ableton.com/en/live-manual/12/using-grooves/ | high | M |
| GR-02 | Groove | Groove parameters | 그루브의 기준 격자, 당김 정도, 타이밍·세기 적용량, 무작위 양을 조절한다. | AL | https://www.ableton.com/en/live-manual/12/using-grooves/ | high | M |
| GR-03 | Groove | Extract groove | 기존 클립(오디오/MIDI)의 타이밍과 세기 패턴을 뽑아 새 그루브로 만든다. | AL | https://www.ableton.com/en/live-manual/12/using-grooves/ | high | M |
| GR-04 | Groove | Commit groove | 그루브 효과를 노트에 실제로 적용해 확정하고 그루브 연결을 푼다. | AL | https://www.ableton.com/en/live-manual/12/using-grooves/ | medium | S |
| GR-05 | Groove | Global swing | 손잡이 하나로 짝수 16분음표를 늦춰 셔플감을 준다. | FL | https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/channelrack.htm | high | S |
| GR-06 | Groove | Groove library | 장르/기계별 그루브 모음에서 골라 쓴다. | AL | https://www.ableton.com/en/live-manual/12/using-grooves/ | medium | S |

### 1.13 Export / import

| ID | 분류 | Feature | 사용자 동작 → 결과 | Seen in | Source | 관련도 | 크기 |
|---|---|---|---|---|---|---|---|
| IO-01 | Export | Audio export (WAV/MP3 등) | 곡 전체나 구간을 오디오 파일로 렌더한다. 포맷·품질을 고른다. | AL, FL | https://www.ableton.com/en/live-manual/12/managing-files-and-sets/ · https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/fformats_save_export.htm | high | M |
| IO-02 | Export | Stem export | 트랙(믹서 트랙)마다 따로 된 오디오 파일들로 내보낸다. | AL, FL | https://www.ableton.com/en/live-manual/12/managing-files-and-sets/ · https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/fformats_save_export.htm | medium | M |
| IO-03 | Export | MIDI export | 클립이나 곡의 노트를 표준 MIDI 파일로 내보낸다. | AL, FL | https://www.ableton.com/en/live-manual/12/managing-files-and-sets/ · https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/fformats_save_export.htm | high | S |
| IO-04 | Import | MIDI import | MIDI 파일을 끌어 놓아 노트 클립으로 불러온다. | AL | https://www.ableton.com/en/live-manual/12/managing-files-and-sets/ | high | M |
| IO-05 | Import | Audio import | 오디오 파일을 끌어 놓으면 클립이 되고 템포가 자동 판단된다. | AL | https://www.ableton.com/en/live-manual/12/managing-files-and-sets/ · https://www.ableton.com/en/live-manual/12/audio-clips-tempo-and-warping/ | medium | S |
| IO-06 | Export | Render range from markers | 루프/시작 표식으로 렌더 범위와 끝 꼬리를 정한다. | FL | https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/playlist.htm#Playlist_TimeMarkers | medium | S |
| IO-07 | Project | Collect all and save | 프로젝트가 쓰는 외부 파일을 프로젝트 폴더로 모아 저장한다. | AL | https://www.ableton.com/en/live-manual/12/managing-files-and-sets/ | low | M |
| IO-08 | Project | Templates / default set | 자주 쓰는 트랙·악기 구성을 템플릿으로 저장해 새 곡 시작점으로 쓴다. | AL | https://www.ableton.com/en/live-manual/12/managing-files-and-sets/ | medium | S |
| IO-09 | Project | Project file format | 프로젝트는 gzip으로 묶인 XML이며 노트·장치 체인·클립 루프 정보가 분리 저장된다. 격자 밖 시작/길이 노트도 정밀하게 보존된다. (hands-on observation 2026-10-21) | AL | https://www.ableton.com/en/live-manual/12/managing-files-and-sets/ | medium | M |
| IO-10 | Export | Prepare for MIDI export | 모든 악기를 MIDI 출력용으로 바꿔 곡 전체 MIDI 렌더를 준비한다. | FL | https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/menu_tools.htm | low | S |
| IO-11 | Export | Distribution | 앱에서 곡을 스트리밍 서비스 배포로 보낸다. | FL | https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/menu_tools.htm | low | L |

### 1.14 Workflow

| ID | 분류 | Feature | 사용자 동작 → 결과 | Seen in | Source | 관련도 | 크기 |
|---|---|---|---|---|---|---|---|
| WF-01 | Workflow | Undo / redo | 편집을 한 단계씩 되돌리고 다시 적용한다. | AL, FL | https://www.ableton.com/en/live-manual/12/live-keyboard-shortcuts/ · https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/menu_edit.htm | high | S |
| WF-02 | Workflow | Undo history list | 저장된 편집 기록 목록을 보고 원하는 단계로 이동한다. | FL | https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/menu_edit.htm · https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/browser.htm#Browser_CurrentProject | medium | M |
| WF-03 | Workflow | Keyboard shortcuts | 편집·이동·도구 전환을 단축키로 한다. | AL, FL | https://www.ableton.com/en/live-manual/12/live-keyboard-shortcuts/ · https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/basics_shortcuts.htm | medium | S |
| WF-04 | Workflow | Multitouch | 터치 화면에서 여러 손가락으로 편집·확대·연주한다. | FL | https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/basics_interface.htm#FLStudio_multitouch | high | M |
| WF-05 | Workflow | Accessibility / keyboard navigation | 화면 낭독기와 키보드만으로 화면 요소를 이동·조작한다. | AL | https://www.ableton.com/en/live-manual/12/accessibility-and-keyboard-navigation/ | medium | M |
| WF-06 | Workflow | Info / help view | 마우스를 올린 요소의 설명을 작은 도움말 창에 보여 준다. | AL | https://www.ableton.com/en/live-manual/12/live-concepts/ | medium | S |
| WF-07 | Workflow | Task macros | 반복 작업(정리·변환)을 메뉴 한 번으로 자동 실행한다. | FL | https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/menu_tools.htm | low | M |
| WF-08 | Workflow | Select unused channels | 어떤 패턴에도 노트가 없는 악기를 골라 정리한다. | FL | https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/menu_tools.htm | low | S |

### 1.15 Performance / live

| ID | 분류 | Feature | 사용자 동작 → 결과 | Seen in | Source | 관련도 | 크기 |
|---|---|---|---|---|---|---|---|
| PF-01 | Performance | Controller integration | 전용 패드 컨트롤러로 클립 실행·연주·장치 조절을 한다. | AL | https://www.ableton.com/en/live-manual/12/using-push-2/ | low | L |
| PF-02 | Performance | Key-mapped clip launch | 자판 키에 클립/씬 실행을 연결해 라이브로 튼다. | AL | https://www.ableton.com/en/live-manual/12/midi-and-key-remote-control/ | low | S |
| PF-03 | Performance | Prepare for performance | 프로젝트를 라이브 클립 실행용 설정으로 한 번에 바꾼다. | FL | https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/menu_tools.htm · https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/playlist_performance.htm | low | M |
| PF-04 | Performance | Live Loops remote control | 외부 기기로 셀 격자를 실행·정지한다. | LP | https://support.apple.com/guide/logicpro/control-live-loops-logic-pro-devices-lgcp00c0b301/mac | low | M |

### 1.16 AI / generative helpers

| ID | 분류 | Feature | 사용자 동작 → 결과 | Seen in | Source | 관련도 | 크기 |
|---|---|---|---|---|---|---|---|
| AI-01 | Generative | Session Players (bass / keys) | 베이스·건반 연주자 트랙을 추가하면 코드에 맞춰 스타일별 반주를 자동 연주한다. | LP | https://support.apple.com/guide/logicpro/session-players-overview-lgcpbf624405/mac | high | L |
| AI-02 | Generative | Drummer | 장르와 연주자를 고르면 복잡도·세기 등을 조절할 수 있는 드럼 연주가 생성된다. MIDI로 변환해 편집할 수 있다. | LP | https://support.apple.com/guide/logicpro/drummer-lgcpa4324884/mac | high | L |
| AI-03 | Generative | Chord-following players | 전체 코드 트랙이나 구간별 코드를 바꾸면 반주 연주자가 그 화성으로 다시 연주한다. | LP | https://support.apple.com/guide/logicpro/chords-and-session-players-lgcp70dd5af3/mac | high | L |
| AI-04 | Generative | AI mastering | 곡을 올리면 목표 음량(LUFS)에 맞춰 자동 마스터링한다. | FL | https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/menu_tools.htm | high | L |
| AI-05 | Generative | Remix wizard (stems) | 기존 곡을 스템으로 나눠 리믹스 프로젝트로 연다. | FL | https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/menu_tools.htm | low | L |

행 수: TR 12 · RC 18 · PR 54 · ST 13 · CL 12 · AR 18 · AU 20 · MX 12 · DV 21 · AM 10 · BR 9 · GR 6 · IO 11 · WF 8 · PF 4 · AI 5 = **233**

---

## 2. HumTrack Studio 상위 25 후보

순위 = 흥얼거림 → 음악 증폭 효과(관련도) × 구현 용이성(크기, 기존 코드 재사용). HumTrack에 이미 있는 것(구간 복제·반복, Undo/Redo, 악기 시청·즐겨찾기, 트랙 Mute/Volume — findings.json `humtrack_existing`)은 확장 관점으로만 넣었다.

| 순위 | 후보 (ID) | 이유 |
|---|---|---|
| 1 | Retroactive hum capture (RC-01, RC-02, RC-03) | 녹음 버튼을 누르기 전 떠오른 흥얼거림을 놓치지 않는다. 마이크 입력을 롤링 버퍼로 두고 "방금 것 저장"하면 되므로 험 앱의 핵심 경험에 직결된다. |
| 2 | 선택 기반 노트 편집 (PR-02, PR-03, PR-04, PR-05) | 분석 결과를 다시 찍지 않고 고치는 기본기. findings.json의 P0 항목과 같고 hands-on으로 동작을 확인했다. |
| 3 | Deactivate notes (PR-08, AR-13) | 분석 오탐 노트를 지우지 않고 꺼 두는 비파괴 편집. 플래그 하나라 작고, 되돌리기 쉽다. |
| 4 | Fit to Scale + Snap to scale (PR-17, PR-21) | 흥얼거림의 음정 오차를 곡의 키에 맞추는 가장 직접적인 도구. 이미 키 추정(Auto Key)이 있어 붙이기 쉽다. |
| 5 | Scale highlight + Fold to Scale (PR-18, PR-19) | 모바일 작은 화면에서 스케일 음 줄만 보여 주면 틀린 음을 넣을 수 없고 세로 공간도 절약된다. |
| 6 | Quantize with amount + record quantize (PR-12, RC-11) | 험 타이밍은 흔들리므로 비율 퀀타이즈로 느낌을 살리며 정리. 기존 격자 모델에 바로 얹힌다. |
| 7 | Note chance + velocity deviation (PR-06, PR-07) | 짧은 험 루프를 반복해도 매번 조금씩 달라져 지루하지 않다. 노트 속성 두 개 추가와 재생 시 판정만 필요하다. |
| 8 | Chord Stamp / Stacks (PR-24, PR-26, DV-04) | 멜로디 하나만 흥얼거려도 그 아래 코드를 원탭으로 깐다. 스케일 정보와 결합하면 틀린 코드가 안 나온다. |
| 9 | Chord progression + chord-following accompaniment (PR-25, AR-17, AI-03) | 험 멜로디에서 코드 진행을 제안하고 베이스/건반이 따라오게 하면 "루프 → 곡"의 핵심 증폭기가 된다. 단계적으로(진행 제안 → 단순 패턴 반주) 만들 수 있다. |
| 10 | Arpeggiate tool + Arpeggiator (PR-27, DV-03) | 코드를 리듬 있는 반주로 바꾸는 가장 싼 방법. 오프라인 변환(노트 생성)부터 하면 재생 엔진 변경이 없다. |
| 11 | Strum (PR-28) | 코드에 사람 손맛을 더하는 작은 변환. 시작 시간 오프셋만 계산하면 된다. |
| 12 | Groove: extract / apply / swing (GR-01, GR-02, GR-03, GR-05) | 사용자의 험이나 '따따' 비트박스에서 그루브를 뽑아 다른 파트에 입히면 곡 전체가 그 사람 느낌을 갖는다. 스윙 하나부터 시작 가능. |
| 13 | Split / Join(Glue) / Chop (PR-09, PR-10, PR-11) | 험 분석이 붙이거나 쪼갠 노트를 바로잡는 필수 도구. P0 '편집 중 노트 정보 보존' 규칙과 함께 설계해야 한다. |
| 14 | Linked sections + Make unique (AR-02, AR-03) | 후렴을 고치면 모든 후렴이 바뀌고, 필요하면 하나만 떼어 변주. 기존 구간 복제를 연결/독립 두 모드로 확장한다. |
| 15 | Limit (octave fold) (PR-34) | 험 분석의 옥타브 오류나 사람마다 다른 음역을 악기 음역으로 접어 넣는다. 매우 작다. |
| 16 | Legato + Humanize (PR-14, PR-13) | 끊긴 험 노트를 잇고, 찍어 넣은 노트에는 사람 느낌을 더한다. 둘 다 일괄 변환이라 작다. |
| 17 | Slip edit + slice clip (AR-04, AR-06) | 섹션 경계를 두고 안의 리듬만 밀거나 구간을 자른다. 루프 기반 배치에 잘 맞는다. |
| 18 | Solo (mute 상태 보존) + Pan (MX-01, MX-02) | findings.json P1. 믹서에 Solo/Pan이 없으므로 작고 효과가 크다. |
| 19 | 같은 패턴으로 악기 교체 (DV-01, ST-10) | findings.json P1. 노트는 두고 소리만 바꿔 비교하는 흐름. 기존 악기 시청을 구간 재생으로 넓힌다. |
| 20 | Convert drums / Slice to MIDI (AU-11, AU-09) | '따따' 비트박스를 킥·스네어·하이햇 MIDI로 바꾸는 것은 험 앱의 차별점. 기존 타악 분류 분석과 이어진다(크기 L이지만 관련도 최상). |
| 21 | Rhythm / Euclidean generators + Generate steps (PR-39, PR-40, ST-07) | 멜로디만 흥얼거린 사용자에게 드럼 바탕을 한 번에 깔아 준다. 규칙 기반이라 오프라인·결정적으로 만들 수 있다. |
| 22 | Duplicate loop + clip loop controls (PR-44, CL-06, CL-07) | 1–2마디 험을 4/8마디로 늘리는 기본 동작. 기존 구간 반복을 노트 편집기에도 노출하면 된다. |
| 23 | Time markers / sections + loop region (AR-08, TR-08) | 인트로·벌스·후렴 이름표와 부분 반복으로 루프를 곡 구조로 만든다. 작다. |
| 24 | Tap tempo + count-in + metronome (TR-04, RC-12, TR-07) | 흥얼거리기 전에 템포를 손으로 정하고 박을 들으면 분석 정확도가 오른다. 각각 작다. |
| 25 | MIDI / stem export (IO-03, IO-02) | 험으로 만든 결과를 다른 DAW로 가져가는 출구. 표준 MIDI는 작고, 스템은 기존 렌더 경로 재사용. |

### 보류 권장 (findings.json `defer`와 일치)

Session View 전체 복제(CL-01 계열), 전체 Warp 엔진(AU-01–03), MPE·미분음(PR-51, PR-52), 복잡한 장치 라우팅·플러그인 호스팅(DV-21), 원본 프로그램의 악기·샘플·프리셋 복사(CLEANROOM 금지).

---

## 3. 출처 목록

- Ableton Live 12 Reference Manual: https://www.ableton.com/en/live-manual/12/welcome-to-live/
- FL Studio Online Manual (Image-Line): https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/pianoroll.htm (각 행의 페이지)
- Logic Pro User Guide for Mac (Apple Support): https://support.apple.com/guide/logicpro/
- hands-on observation 2026-10-21: `artifacts/ableton-analysis-20261021/findings.json` (git-ignored, 로컬 전용. 스크린샷은 배포하지 않음)
