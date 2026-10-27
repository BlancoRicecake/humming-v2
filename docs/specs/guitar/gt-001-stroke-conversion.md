# Guitar stroke conversion (G0 + G1)

- **ID:** gt-001
- **Status:** implemented (uncommitted) (2026-10-22) — approved 2026-10-22 (the user granted implementation authority; Codex reviewed the plan). Tests: `mobile/test/looptap/guitar_stroke_{golden,,ui}_test.dart`
- **Product source:** `docs/product/song-completion-plan.md`, §1 "기타 연주 표현"

## Sources
- HumTrack's own code: `theory.dart` `strumPlan` / `GuitarStrum` (28 ms, -18% falloff, down-only), `edit_screen.dart` `_trigger` guitar branch (~L936-980) and `_triggerGrooved`, `midi_export.dart` `addPitched` (~L162-214), and SoundLab `backend/app/guitar_lab.py` (our own research renderer; documents strum_ms, direction, velocity falloff and jitter)
- General playing knowledge: a down stroke sweeps low string → high string, an up stroke sweeps high → low (usually fewer strings and lighter). No other product's code, binaries or `C:/src/re-lab` material.

## Principles (Codex review 2026-10-22, binding)
1. **Opt-in, no silent change.** Existing songs and imported precise MIDI keep their current output. Nothing changes a note's velocity or offset unless the user explicitly applies a stroke.
2. **Legacy path preserved byte-for-byte.** The automatic strum (`strumPlan` on untouched GM-guitar chords) stays exactly as it is for notes that were never converted. A golden test pins it.
3. **Stable note identity.** Never key notes by `midi` (the current `byMidi` maps overwrite duplicates). Use list indices or object identity.
4. **No program changes, no channel allocation** in this unit.
5. **Shortcuts never collide with the desktop instrument keys** (`DesktopInstrument` grabs A S D F G H J K L ; ' \ and the drum keys unless Ctrl/Cmd/Alt is held; StepGrid ignores Alt).

## Review amendments (Codex checklist `docs/product/guitar-review-checklist.md`, 2026-10-22, binding)
- **Exact restore (item 1):** the tag stores the complete pre-conversion timing **including null-ness**: `baseDur` (int), `baseDurationSteps` (double?, null preserved), `baseOffsetSteps`, `baseVelocity` (int?, null preserved). Revert must reproduce the original note's JSON exactly (test: `toJson()` equality before → convert → revert).
- **No legacy re-strum after tag loss (item 2):** conversion always writes an explicit `velocity` **and** explicit `durationSteps` on every converted note. The legacy predicate (`velocity == null && offsetSteps == 0 && durationSteps == null`) then never matches a converted note, even after split/quantize drops the tag. Add a test: convert → quantize (tag dropped) → assert the legacy strum does not run on that hit.
- **Same pitch (item 3):** data keeps every duplicate note. Output on one MIDI channel cannot sound two overlapping same-pitch notes independently; tests and docs must not claim it does.
- **Pitch/instrument changes (item 6):** transpose, octave and scale-snap edits keep the tag but recompute nothing. Pasting into a non-guitar track keeps the data, but the UI hides guitar controls there.

- **Chord-hit grouping for the new conversion (mid-implementation review, 2026-10-22):** the legacy auto strum keeps its integer-`step` grouping unchanged (golden). The explicit stroke conversion groups by **actual start** (`step + offsetSteps`) with a tolerance of **0.05 step**, anchored on the hit's earliest note (no unbounded chaining). Re-apply and revert of a converted hit group by its **base** start (`step + baseOffsetSteps` from the tag), so it returns to its original group. Required tests: a fast monophonic line inside one step is not strummed; a micro-offset chord (0, .02, .04) is one hit; same-pitch duplicates; re-apply via base timing.

## User-visible behavior
1. On a pitched track, the user selects notes (or nothing = the whole track, matching other tools) and chooses **Stroke ↓ (down)**, **Stroke ↑ (up)** or a **pattern preset**.
2. Each *chord hit* (selected, non-muted, non-locked notes sharing the same start, grouped by actual start within 0.05 step — see the grouping amendment; the legacy auto strum keeps its integer-step grouping) is rewritten into real note data:
   - start offset per string: string order × spread (ms → steps at the song BPM), ordered low→high for down, high→low for up;
   - velocity per string: base × accent × (1 − falloff × position), clamped 1..127;
   - durations: every string of the hit ends where the chord originally ended (later strings get correspondingly shorter `durationSteps`; never ≤ 0, minimum 1/16 of a step).
3. The result plays, exports to MIDI and renders to WAV identically, because all three read the same note data (no playback-time strum for converted notes, and the legacy auto strum must not run on top: "기존 자동 스트로크를 중복 적용하지 않는다").
4. **Pattern presets** assign ↓/↑ to successive chord hits in time order (e.g. `↓`, `↓↑`, `↓ ↓↑ ↑↓↑`). Up strokes default to lighter accent and a shorter spread.
5. **Re-apply / revert:** applying again replaces the previous stroke (no accumulation). "일반으로 되돌리기" restores each note's pre-stroke offset/velocity/duration exactly.
6. **Basic vs expanded UI:** basic = one "기타 스트로크" control in the step-grid inspector, shown only for guitar tracks, with ↓ / ↑ / pattern chips. Expanded (▸) = spread ms (5–60, default 28 down / 18 up), falloff (0–40%, default 18%), accent (50–130%, default 100% down / 80% up), and a revert button.
7. Converted hits show a small ↓/↑ mark on the grid.

## Data model (schema v3, unreleased — stays v3)
- `PitchNote.stroke`: `StrokeTag?`, default `null`. Fields: `dir` (down/up), `spreadMs`, `falloff`, `accent`, `order` (string position within the hit), plus the **base** values before conversion: `baseDur`, `baseOffsetSteps`, `baseVelocity` (nullable), `baseDurationSteps` (nullable) — null-ness preserved. Written to JSON only when non-null.
- `Song.guitarStyle` is **not** needed for this unit (the per-hit tag carries its parameters). Preset/default choices live in `LoopPrefs`.
- Inheritance rules for existing operations:
  - copy/paste, duplicate, section duplicate and linked sections: keep the tag
  - split/chop/quantize/humanize/legato: drop the tag but keep the resulting concrete timing
  - glue: earliest part's tag
  - chord stamp: added notes get no tag
  - arpeggiate: drop the tag
  - note mute: keep the tag
  - Undo snapshots: deep-copy the tag

## Decision after implementation (lead, 2026-10-22)
- **Pitch-only edits keep the tag; timing and velocity edits drop it.** Pitch-only: transpose, octave, scale snap, mute. Timing and velocity: a move that changes start, resize, velocity-lane or velocity ± edits, humanize. A stale base would otherwise make "되돌리기" overwrite the user's later edit. A note without a tag still has explicit velocity and durationSteps, so the legacy strum never re-applies.
- Up strokes keep every string (no note is silently dropped).
- Same-pitch duplicates are verified as separate note events, not independent voices.
- Implemented (uncommitted): `movePitchNotes` drops the tag when the start changes (whole-step or fractional; a pitch-only move keeps it), `resizePitchNotes` and humanize drop it (`_withBounds`), `shiftPitchVelocities` / `setPitchVelocity` drop it. Duplicate and copy/paste keep it (the base offset is relative to the note's cell, so it stays valid). Tests: `mobile/test/looptap/guitar_stroke_edit_test.dart`. Each dropped note is checked to keep explicit velocity + durationSteps, with no legacy strum (live predicate and MIDI export).

## String order with gt-002 (lead, 2026-10-22)
- When every note of a hit has an assigned `guitarString`, the explicit stroke strikes in string order (`strokeConversionOrder`): down = string 6 to 1, up = 1 to 6, ties by list index. If any note is unassigned, the whole hit uses pitch order (no partial mixing). The gt-002 "줄 없음" flag shows the unassigned notes. The legacy auto strum (`strumPairs`) keeps pitch order, and golden output is unchanged. Applying or reverting a stroke first undoes a gt-002 ring on those notes. Tests: `guitar_strings_test.dart` "stroke order follows the assigned strings".

## P1 fix: strings stored in an earlier cell (lead, 2026-10-22)
- **Problem:** a slow spread can put a string's actual onset one or more cells after the hit's `step` (`offsetSteps >= 1`). Live playback triggers notes cell by cell, so a seek, play-start or range-loop pass that begins after the hit's cell skipped those strings.
- **Rule:** a note with `offsetSteps >= 1` (`onsetInLaterCell`) whose actual onset is inside the active play range, at or after the pass start, is triggered **exactly once per pass**, whatever cell it is stored in. Only explicit stroke conversion writes such offsets. Imported, drawn and edited notes keep offsets inside their own cell, so legacy output and schedules do not change. At play start, or at each pass start (loop wrap, after its timer reset), `laterCellOnsets` lists the notes whose trigger cell is before the pass's first cell. The editor schedules them with delay = onset − current position. The cell pass never reaches them, so they cannot trigger twice. Stop cancels them like any other scheduled note. Grooved lanes use the grooved onset and slot. Their range check uses the onset, not the stored cell, for these notes. Chase semantics are unchanged: strings already sounding at the start are still chased.
- **Known gap (pre-existing, unchanged):** a sub-step note (`offsetSteps < 1`) whose cell starts before a *fractional* seek position and whose onset falls after it is still not played. Fixing this would change legacy schedules.
- **Tests:** `mobile/test/looptap/guitar_stroke_p1_test.dart` (a real EditScreen on a fake clock). It covers the pure rule, a seek into a hit (the not-yet-struck strings play once at the correct delays, and MIDI export onsets match), a fractional seek, Stop mid-hit, a range loop over three passes (plain and grooved), and a grooved fractional seek.

## Edge cases
- A hit with a single note: a down/up stroke only applies the accent (no spread).
- Duplicate same-pitch notes in one hit: both are kept and ordered stably by index.
- Locked notes: unchanged, but they still occupy their string position. Muted notes are skipped.
- Spread longer than the chord length is clamped so the last string still starts before the chord ends.
- BPM changed after conversion: offsets are stored in steps, so the spread scales with tempo. The tag keeps `spreadMs`, so re-apply recomputes. Document this.
- Section end / loop wrap / Stop: a string whose offset falls past the section end is not scheduled (same rule as other offset notes). Stop cancels pending strings.
- Grooved tracks: the groove applies on top of the converted offsets, the same way live and export already treat offset notes.
- Legacy fix allowed without changing non-duplicate output: replace `byMidi` maps in the legacy strum paths (`edit_screen` and `midi_export`) with index-stable handling. For chords without duplicate pitches, output must stay byte-identical.

## HumTrack design
- New `lib/looptap/music/guitar_stroke.dart`: pure `applyGuitarStroke(notes, selection, StrokeSpec, bpm) → notes`, `revertGuitarStroke`, `applyStrokePattern`, chord-hit grouping and preset definitions.
- `models/loop_models.dart`: `StrokeTag` + `PitchNote.stroke` (JSON, copyWith, deepCopy).
- `music/pitch_note_edit.dart` and `pitch_clipboard.dart`: the inheritance rules above.
- `screens/edit_screen.dart` and `music/midi_export.dart`: the legacy auto strum must skip hits that contain any stroke-tagged note, and the index-stable fix. Converted notes then go through the normal offset/velocity path.
- `widgets/surfaces/step_grid.dart`: inspector control (guitar tracks only), ↓/↑ marks. Shortcuts `Ctrl/Cmd+Shift+↓` / `Ctrl/Cmd+Shift+↑`, taking precedence over the chance-lane `Ctrl+↑/↓`.
- New `widgets/sheets/guitar_stroke_panel.dart`: the expanded controls.
- One edit = one undo through the existing `_commit` → `onEdit` path.

## Acceptance tests
- [x] Golden: songs and imported precise MIDI without stroke tags produce byte-identical `.mid` and identical live schedules to the pre-change code (legacy strum included).
- [x] Down stroke: offsets increase low→high by spread, velocities follow falloff × accent, and all strings end at the original chord end.
- [x] Up stroke: reverse order; parameters as given.
- [x] Re-apply does not accumulate; revert restores exact base values (round-trip equality).
- [x] Duplicate same-pitch notes in one hit are both converted and both sound (index-stable). *(Verified as two separate note events; per the amendment, not as independent voices on one channel.)*
- [x] Locked notes keep their position; muted notes are skipped; nothing selected = whole track.
- [x] Legacy auto strum does not run on hits containing converted notes. Live schedule == MIDI export events (pitch, tick-rounded start, velocity) for converted hits; WAV renders from the same `buildMidi` events.
- [x] Integration: Stop cancels pending strings; strings past the section end are not scheduled; grooved track live == export; section duplicate and linked section keep tags; save/load round-trip; undo/redo; copy/paste keep tags.
- [x] UI: the control appears only on guitar tracks; applying a pattern is one undo; shortcuts reach the grid while a DesktopInstrument is mounted and do not play notes.

## Out of scope
- Real string assignment, ringing and choke (gt-002). Palm mute, harmonics, program or channel changes (G3, later and separately). Playback-time humanize of strokes.
