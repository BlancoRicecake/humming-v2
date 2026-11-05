# Guitar articulations: short, palm-mute tone, harmonic tone (G3, v1)

- **ID:** gt-003
- **Status:** implemented (uncommitted) (2026-10-22). Approved r3 + build review + r4. Code: `mobile/lib/looptap/music/guitar_articulation.dart` (+ model, export, audio and editor changes listed under "Implementation notes"). Tests: `mobile/test/looptap/guitar_articulation_{,export_,live_}test.dart`, `mobile/test/audio/articulation_engine_test.dart`. Logs: `artifacts/g3-impl-20261022/`.
- **Review criteria:** `docs/product/guitar-articulation-review.md` (Codex, items 1–10)
- **User target:** acoustic guitar strums and gentle arpeggios on FreePats nylon (slot 1001)

## Evidence (both engines, measured 2026-10-22; scripts and logs in `artifacts/g3-design-20261022/`)
Method: SF2 zone metadata (`sf2_zones.py` → `sf2_zones.json`), plus partial-structure analysis. The pitch measure used here is a **partial-structure proxy**: the highest candidate f0 whose integer multiples hold ≥ 85% of the spectral energy. It is not the strongest peak, and it is **not a confirmed perceived pitch**; perceived pitch still needs listening. The same analysis runs on FluidSynth 2.5.4 (Android/backend; `probe_structure_fluidsynth.log`) and on MeltySynth (desktop/iOS; PCM from `mobile/test/probe/articulation_probe_test.dart`, analysed into `probe_structure_melty.log`). The two engines agree.

| Sound (GeneralUser-GS / FreePats) | Pitch | Brightness/sustain vs. plain nylon | Conclusion |
|---|---|---|---|
| FreePats nylon (slot 1001) | = key | Velocity 110→50 changes level only. Spectral centroid unchanged (e.g. 196→207 Hz Melty, 207→207 Hz Fluid). No filter zones; 1 velocity layer. | Lower velocity does **not** darken. "Short" on this sample is staccato, not palm mute. |
| GM 28 "Muted Guitar" | fundamental = key (metadata root = key, small corrections) | RMS at 0.6 s is 0–9% of the attack (nylon: 17–37%). Centroid 182–280 Hz. Velocity tiers lower the filter. | Has the palm-mute character (darker, short) but an **electric** timbre. Usable only as a labelled approximation. |
| GM 31 "Guitar Harmonics" | Keys **50–86**: energy sits on multiples of key+24 (fit at +24 = 0.88–0.99 in both engines). Keys ≤ 45: no candidate explains ≥ 85% (unclear). Key 87–88: inconsistent. Metadata (root keys 62–107 for samples named Gb2…C6) does **not** describe the sounding pitch. | Bell-like long decay. | Usable as a **tone approximation** only for (proxy-measured) sounding pitch S = key+24 with **key ∈ 50..86 (S = 74..110)**. Not proven outside that range, so unsupported there. |

Technique reference (user-approved Archtop manual, read by Codex): **palm mute** reduces brightness **and** sustain (p3); **staccato** is short but keeps brightness (p3). Natural and artificial harmonics are described separately (p4); a harmonic is not a fixed octave shift.

Listening has not been verified. These are waveform and metadata facts only.

## Review r3 decisions (Codex ①–⑥, binding; override anything below that conflicts)
- **① Parameters are snapshotted per note.** At apply time the note stores an immutable articulation value: `{kind, gateMs, velScale}`. `LoopPrefs` only supplies the defaults for *new* applies. A saved song therefore sounds the same in any session or with any settings. Re-applying with other values replaces the snapshot.
- **② G3 never changes string, pitch or length.** There is no automatic string assignment in G3. Natural-harmonic position info uses the existing G2 `guitarString` only (display-only). "일반으로" removes only the articulation, so G1 stroke data, G2 ring and string data, and any later manual edits are preserved exactly.
- **③ One routing plan for the whole song.** `ArticulationPlan.of(song)` deterministically decides, for every (track, role), whether an articulation channel exists and which one. The **same plan** is passed to live playback, audition, the full mix and each stem.
  - If a (track, role) has no channel in the plan, its articulated notes render as normal **in every output**, so outputs never differ. The UI shows the "채널 부족" badge.
  - At apply time a role that cannot get a channel is **refused** and counted. A fallback is never reported as a successful harmonic or palm apply.
- **④ Nylon gate + velocity is labelled 짧게 (staccato) only.** It never counts as palm mute. Palm mute in v1 is the clearly labelled **GM 28 tone approximation** on a dedicated channel.
- **⑤ MIDI conformance is defined by rule, not by identical events.** A `.mid` note is written at the **sounding pitch** with the same start and the same gated length that live and WAV use. Live and WAV send GM 31 key S − 24 (and GM 28 key = S) on the articulation channel. Tests compare sounding pitch, start and length across live, MIDI and WAV, plus the documented timbre loss. They do not compare raw key numbers.
- **⑥ Additional tests:**
  - Switching normal ↔ 짧게 ↔ 팜뮤트 ↔ 하모닉스 preserves G1/G2 data and later manual edits.
  - A same-pitch normal note sounding together with an articulated note: independent voices and no leak.
  - Stop during font loading or pending articulation voices: no stale voice.

- **Implementation review (Codex, during build):**
  - **Channel roles:** Melty `_drumChannels`, Android and `LoopAudio` kit, program, pan and CC caches must be cleared through an explicit channel-role switch whenever a channel changes role (drum → articulation → pitched; song switch; track delete). This needs a real-synth regression test.
  - **Pan reset:** `_applyPans` must mirror articulation channels and reset only truly unused channels.
  - **Palm-tone input range:** limited to verified GM 28 zone coverage. The preset keyRange is 0..118, so keys ≥ 119 are refused, as is anything not render-verified. Boundary render tests are required.
  - **GM 31 pitch check:** it is a **partial-structure proxy**, not a confirmed perceived pitch. Never word it as verified pitch.

- **Volume rule (Codex, during build):** live `playPitch` already folds the track volume into velocity (`noteVelocity`). Normal notes and every articulation role apply the **same gain rule exactly once**. Articulation channels do not mirror the track volume into CC7 (that would apply it twice); CC10 pan is mirrored. WAV and stem role jobs use the same volume mechanism as normal lane jobs. Tests at vol = 0, 0.5 and 1.

## r4 exception (owner approved 2026-10-22, overrides review ⑤ for `.mid` only)
- **Problem:** a normal note 52 sustaining 2 s plus a palm note 52 at 0.25 s were both written on the track channel, so the palm note-off cut the normal note.
- **Rule:** in `.mid`, `palmTone` and `harmonicTone` notes that have an `ArticulationPlan` channel are written on that **spare role channel**.
  - The channel gets a program change at t = 0 to the **owner track's GM fallback program**. The timbre stays the track's GM sound; GM 28/31 and S − 24 are not used in `.mid`.
  - Notes are written at sounding pitch S. Pan and volume follow the owner lane rules.
  - The same-role, same-pitch retrigger rule applies on that channel.
- **Unchanged:**
  - Staccato stays on the track channel.
  - With no plan channel, the note falls back to the track channel, the same as live and WAV.
  - Songs without articulations produce byte-identical `.mid` (goldens).
  - WAV and live keep the plan routing (GM 28/31 role jobs).
- **Conformance:** sounding pitch, start and gated length match across outputs, and the separate channel preserves overlapping articulated and normal notes. An actual render of the exported `.mid` is part of the tests.

## Implementation notes (2026-10-22, binding where they refine the rules above)
- **Code:** `music/guitar_articulation.dart` (constants, `realizeArticulation`, `ArticulationPlan`, `applyArticulation`, natural-harmonic info, grid marks). `models/loop_models.dart`: `Articulation`, `ArticulationKind`, `PitchNote.articulation` (JSON only when set; `withArticulation`; the constructor drops a kind whose range the pitch leaves, which is how pitch edits clear it). `state/loop_prefs.dart`: defaults for new applies. `music/midi_export.dart` (`articulations`, `articulationRole`), `music/wav_export.dart` (role jobs, stem groups, `articulationJobs`), `audio/loop_audio.dart` (`playArticulation`, `assignChannelRole`, `releaseChannel`), `audio/synth.dart` + `audio/melty_synth_backend.dart` (`releaseChannel`, serialized reset, role generations), `screens/edit_screen.dart`, `widgets/surfaces/step_grid.dart`, `widgets/surfaces/pitch_grid_surface.dart`, `widgets/sheets/guitar_stroke_panel.dart`, `widgets/sheets/export_drawer.dart`, `music/pitch_note_edit.dart` (articulated notes are never merged by paint), `music/guitar_stroke.dart` (no legacy auto strum on articulated notes).
- **Palm-tone range = 40..86** (standard guitar range, `kGuitarLowestMidi..kGuitarHighestMidi`). Keys 40..88 use the B2/B3/D#4/E4 samples; 89+ switch to an 8 kHz sample and are not verified, and 119+ are outside the preset. Render-checked in Melty at 40 and 86 (audible, structure fit ≥ 0.85 at f(K) with the GM 31 window 0.1–0.9 s); 39 and 87 are refused with the "지원 범위 밖" count.
- **Support is decided on the pitch that sounds** (e.g. raw-pitch preview); out of range renders normal, never clamped.
- **Gate base:** an articulated note gates from its own length (`soundingSteps`) in every path, then the articulation cap, then the range/section clip. Normal notes keep the legacy live gate exactly. Articulated notes never take the legacy auto strum (live and export).
- **Chase / seek / late P1 onsets:** the articulation gate counts from the note's original start; a gate already over stays silent, a running one plays only the rest.
- **Loop wraps:** every wrap first silences the articulation channels (a range-loop wrap silences every channel of its tracks, as before), then syncs the plan, schedules P1 onsets and chases, then triggers, so a voice started at the wrap is never cut.
- **Channel roles:** the editor gives every pooled channel a role (`drums:<id>`, `pitched:<id>`, `art:<id>:<role>`, `free`) before playback, audition, export and at each trigger. A changed role releases the channel (voices cut, controllers reset, bank 0 / program 0 in Melty; kit, program, pan caches cleared in `LoopAudio`, Melty and the Android engine) and sets the new owner's kit, program and pan. On Android the reset is serialized before later calls on that channel. A role generation drops late kit/font/program commits a role switch overtook (both engines).
- **Same key on one articulation channel:** export and WAV end the earlier note at the later onset (off before on at equal ticks); live sends a note-off before the new note.
- **Font still loading:** an articulation voice plays as normal on the track channel; Stop (channel epochs) leaves no queued voice.
- **Audition:** tapping an articulated note in the grid plays it through the same realize step (velocity, channel, gate as playback). Pad audition plays new notes, which are always normal.
- **Track deletion** happens only as the undo of an added track; it goes through the same role sync (release + re-setup).
- **WAV stems:** jobs carry a `group`; a lane's role jobs sum into its stem exactly as the mix sums them (`renderWavForExport`).

## v1 scope (minimal)
Per note `articulation`: **일반 (normal)**, **짧게 (staccato)**, **팜뮤트 근사 (palm-mute tone, GM 28)**, **하모닉스 근사 (harmonic tone, GM 31)**.
- **짧게:** same sample, same channel, gate = min(note, 120 ms), velocity unchanged. This is what the nylon can do faithfully. It is not labelled palm mute.
- **팜뮤트 근사:** GM 28 on an isolated articulation channel, same key, velocity × 0.85, gate = min(note, 250 ms). Label: "근사: GM 뮤트 기타 음색(일렉) — 실제 나일론 팜뮤트 녹음 아님".
- **하모닉스 근사:** GM 31 on an isolated articulation channel.
  - **MIDI pitch = sounding pitch S**; the engine key S − 24 is a render detail and is never stored.
  - **Supported only for S ∈ 74..110.** Outside that range the apply is refused for that note with a reason ("하모닉스 음색 지원 범위 밖"), and the note stays normal with its pitch unchanged.
  - Label: "근사: GM 하모닉스 음색".
  - If the note has a G2 string and S − open(string) ∈ {12, 19, 24}, the panel shows "자연 하모닉스 위치: n번 줄 m프렛" as information. Otherwise it shows "자연 하모닉스 위치 아님/미확인". The tone approximation is allowed either way and is never called a real natural harmonic.
- **Deferred:** a nylon-family palm mute with real darkening (needs recorded samples or a per-voice filter), artificial/pinch harmonics, dead notes, `.mid` timbre export, keyswitches.

## Principles (binding once approved)
1. **Opt-in and render-time only.** `PitchNote.articulation` (`null` = normal) is the only stored change. Pitch, timing, velocity, the G1 stroke tag and G2 ring fields are never rewritten. "일반으로" clears the field, so the user's later edits are never overwritten (review item 3). There are no base fields.
2. **One shared realize function** `realizeArticulation(note, ctx) → events (key, velocity, gateSteps, role)`. `role` is `track`, `muteVoice` or `harmonicVoice`. It is used by:
   - live trigger (plain and grooved paths, including the P1 later-cell strings)
   - pad and grid audition
   - `flattenSong` (MIDI, WAV, stems)
3. **No channel-state leaks.**
   - The track channel never receives a program, bank, soundfont or CC change from an articulation.
   - Articulated voices go to **articulation channels**, allocated from free `kExtraPitchChannels` slots: one per (track, role), only while the song contains such notes.
   - Each channel is bound to the GM font, its program (28/31) is set once before its first note, and CC10 mirrors the owner track's pan. Volume follows the volume rule above (the same gain rule as the track, applied once).
   - Base track, drum (9, 10) and click (15) channels are never taken.
4. **Resource shortage is explicit.**
   - If no channel is free, applying 팜뮤트/하모닉스 is refused with a message.
   - If an existing song needs more channels than are free (e.g. after adding tracks), the affected notes play as **normal** on the track channel, with a visible "음색 근사 불가 (채널 부족)" badge. They are never silent or dropped.
5. **Priorities:** `muted` > articulation. Staccato or palm gate caps the G2 ring. The stroke offset and velocity apply first, then the articulation's velocity scale.
6. **Exports:**
   - `.mid`: every note at its **sounding pitch** with staccato or palm gates applied; palm and harmonic notes with a plan channel go on that channel with the owner's GM program (r4). Articulation timbre is **not** encoded (the GM 28/31 mapping is font-specific); the export UI says so.
   - WAV and stems: one extra render job per (lane, role) using the GM font program 28/31 and the lane's volume and pan, mixed into that lane's stem and the full mix, so stems still sum to the mix.
7. **G0–G2 goldens stay byte-identical** for notes without `articulation`.

## User-visible behavior
- In the "기타 연주" panel (guitar tracks only) there is a new **연주법** row: 일반 / 짧게 / 팜뮤트 근사 / 하모닉스 근사.
  - Scope: the selection, or nothing selected = the whole track. Locked notes are skipped; muted notes are tagged but stay silent.
  - One apply = one undo.
  - The result line reports "적용 N, 지원 범위 밖 M, 채널 부족 K".
- Grid markers: short = small "s"; palm = "PM" plus a dotted outline; harmonic = ◇. Each shows its approximation badge in the panel.
- No new keyboard shortcut in v1 (avoids collisions; panel only).

## Data model (schema v3, unreleased)
- `PitchNote.articulation`: `null` or an immutable `Articulation{kind: staccato | palmTone | harmonicTone, gateMs: int?, velScale: double}` snapshot taken at apply (review ①). Unknown kinds load as `null`; the field is written only when set.
- **Inheritance:** kept by copy/paste, duplicate, linked sections, save/load, undo/redo, timing edits and stroke apply/revert. Split/chop parts inherit it; glue takes the earliest part's value. A pitch edit that moves a `harmonicTone` note outside 74..110 clears it to `null`, with a hint.
- `LoopPrefs` stores only the **defaults for new applies** (staccato 120 ms; palm 250 ms × 0.85), tunable after the demo. Existing notes keep their snapshot.

## Edge cases (tests required)
- An articulated note overlapping a sustaining normal note of another or the same pitch: the normal note's channel gets no events from the articulation, and the voices are independent. Same pitch on the same articulation channel follows the G2 rule (the earlier note ends at the later onset).
- Slow stroke plus palm: every string is routed and gated. Grooved lane: articulation events equal export. Rapid repeated applies: idempotent.
- Stop, seek, loop wrap, section change, track Solo/Mute/delete: articulation channels are silenced and their epochs reset, and no pending voice or release remains.
- Audition while the GM font is still loading: plays as normal, with no queued stale voice after Stop.
- Track instrument changed away from guitar: the data is kept, the controls are hidden, and notes render as normal.

## Acceptance tests (tick at implementation)
- [x] Goldens: G0–G2 and pre-G3 outputs are unchanged without `articulation`.
- [x] Apply / 일반으로 give an exact JSON round trip. Inheritance as listed; undo/redo; save/load. *(Undo is tested in the editor; redo uses the same snapshot path and is not separately tested.)*
- [x] Range: harmonic apply refused outside 74..110 with the pitch unchanged and the counts reported. Natural-node info is correct for valid and invalid string/fret cases.
- [x] **Two-engine pitch regression:** Melty renders of GM31 at key S−24 for S ∈ {74, 76, 83, 88, 95, 110} pass the structure fit at f(S) ≥ 0.85, and GM28 at key K passes the fit at f(K) ≥ 0.85 for K ∈ {40, 52, 64, 76}. FluidSynth evidence logs are kept (Android path; not run in CI). *(The fit is a partial-structure proxy, not a confirmed perceived pitch. Melty half in `articulation_engine_test.dart`, same window and ±35-cent method as `analyze_melty.py`.)*
- [x] Isolation: per-channel event log shows the program set before the first note-on, no events on the track channel from articulations, CC7/CC10 mirroring, and base, drum and click channels untouched. *(Per the volume rule: CC10 mirrors the lane pan; CC7 on a WAV role job equals the lane channel's CC7, live keeps CC7 at its reset value on both and applies the track volume once through velocity.)*
- [x] Shortage: with the pool full, apply is refused; with an existing song over capacity, notes play normal with the badge, and nothing is dropped.
- [x] Live = audition = WAV events per role from the same `ArticulationPlan`. MIDI conforms by rule (sounding pitch, start, gated length; review ⑤). Stems sum to the mix including the articulation jobs. A plan without a channel gives the identical fallback in every output.
- [x] Stop, seek, loop, section change, Solo/Mute/delete track and loading-font cases. *(Stop, seek, plain and range loop wraps, mute, solo and a role release are tested in a real EditScreen. Section change and track delete use the same silence / role-sync paths and are not separately tested. Loading-font and the Android reset are unit-tested with a fake plugin, not on a device.)*
- [x] UI: the 연주법 row only on guitar tracks, inside "기타 연주"; approximation labels and result counts are shown.
- [x] Demo (lead builds it after implementation) (own 8 bars, nylon 1001, level-matched): A3 strum normal / 짧게 / 팜뮤트 근사; B3 arpeggio normal / 하모닉스 근사 on chord tones in range. A README states what is real and what is approximated. *(`mobile/test/looptap/guitar_articulation_demo_test.dart`; output in `artifacts/guitar-articulation-demo-20261022/`. A3 uses the gt-001 folk stroke on all three files so only the articulation differs; B3 adds an octave-up high line, harmonic applied 14 / out of range 50. Plus a same-pitch overlap case checked in WAV and in a render of the exported `.mid`. Listening not verified.)*

## Open questions for review
1. Palm mute: GM 28 electric tone (measurably darker and shorter) versus nylon "short and soft" (not darker, so effectively staccato). Proposed: GM 28 as **팜뮤트 근사** plus nylon **짧게**.
2. Harmonic support limited to S 74..110 (proven range, both engines). Lower harmonics are refused rather than faked.
3. Constants: 짧게 120 ms; palm gate 250 ms and velocity × 0.85. Tune after listening to the demo.
