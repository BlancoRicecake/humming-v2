# Guitar strings: assignment, ringing arpeggio, same-string choke (G2)

- **ID:** gt-002
- **Status:** implemented (uncommitted) (2026-10-22). Approved 2026-10-22. Code: `mobile/lib/looptap/music/guitar_strings.dart` and `guitar_tuning.dart`. Tests: `mobile/test/looptap/guitar_strings_test.dart` and `guitar_strings_ui_test.dart`.
- **Product source:** `docs/product/song-completion-plan.md`, §1

## Sources
- General guitar facts: standard tuning, low to high, is E2 A2 D3 G3 B3 E4 (MIDI 40 45 50 55 59 64). A string sounds one pitch at a time, so plucking it again stops its previous note. Different strings ring independently. Fret range is 0–22 for v1 (configurable constant).
- HumTrack's own code: `kGuitarLo`/`kGuitarHi` and `guitarVoicing` in `theory.dart`, gt-001's `StrokeTag`, and the hm-002 arpeggiate tool.

## Principles (binding)
- **Real assignment or an explicit "unassignable" state.** Pitch order alone is not treated as knowing the string. **Never** move a note's octave or drop a note to make it fit; report it instead.
- **Opt-in:** existing notes are unchanged until the user runs an assignment or a ring conversion.
- **No program changes or channel allocation.**
- **Live, MIDI and WAV identity:** the ring and choke results are written into note durations, so every path reads the same data.

## Review amendments (Codex checklist `docs/product/guitar-review-checklist.md`, 2026-10-22, binding)
- **Exact restore (item 1):** replace `ringBase: double?` with `ringBaseDur` (int) + `ringBaseDurationSteps` (double?, null preserved). Revert reproduces the original JSON exactly (`toJson()` equality test). Never delete a note; same-pitch overlaps are shortened in realized durations only, and the originals stay restorable.
- **Grouping vs actual start (item 4):** a *chord hit* is identified by its pre-stroke start (`StrokeTag.baseOffsetSteps` and step) when tagged, otherwise by its start. Notes of one hit must get distinct strings even though stroke conversion staggered their actual starts. Separately, any two notes whose **sounding intervals overlap** must be on different strings unless the later one is meant to choke the earlier one. Do not treat every overlap as a simultaneous strum.
- **Ring range (item 5):** a note's ring end = the next onset on the **same string** (or the next same-pitch onset), searched across the **whole track** including unselected notes, capped by the range or section end. Only selected, unlocked, unmuted notes are modified; data outside the selection is never changed. Boundary values: an onset exactly equal to the end counts as a choke (half-open intervals).
- **Pitch changes (item 6):** if transpose, octave, scale-snap, chord-stamp or paste makes a note unplayable on its stored string, clear `guitarString` (it becomes unassigned and is flagged in the UI). Never show a stale or impossible string or fret. `stringLocked` is cleared too.
- **Groove (item 7):** ring and choke are computed on the note data. A groove shifts onsets at playback and export, so with a groove a choke boundary can drift by up to the groove's shift. v1 documents this as a limitation, shows a hint on grooved guitar tracks, and tests that MIDI export orders same-tick note-off **before** note-on for the same pitch.
- **Performance (item 8):** assignment is bounded: at most 6 notes per hit are searched (the extras are unassignable), with a per-hit candidate cap (prune by span) and an O(n·k) sweep over the track. Test that 5,000 notes assign in under 1 second on the test machine, and that invalid or NaN values are rejected.

## User-visible behavior
1. **Assign strings** (automatic): for the selection (or the whole track), each note gets a string 1–6 and a fret. Simultaneous notes must be on different strings. Within a hit, prefer the lowest total fret span (≤ 4 frets when possible), then lower frets, then continuity with the previous hit. Notes that cannot be placed (out of range, or more simultaneous notes than strings or a feasible span) are marked **unassignable**. The UI shows a count and highlights them. They are not moved.
2. **Manual override:** the user can set a specific note's string (only to strings where that pitch is playable). The fret is computed. Invalid choices are refused with a message.
3. **Ringing arpeggio ("울림 아르페지오")**: for assigned notes in the selection, each note's duration is extended until the next onset **on the same string** (choke) or until the end of the selection range / section, whichever is first. A note on another string keeps ringing. Unassigned notes keep their duration.
4. **Same-string re-pluck**: whenever two assigned notes on the same string overlap (after any edit or conversion), the earlier one is cut at the later one's onset. This runs as part of assignment and ring conversion. It is an explicit conversion, not a background rule, so old songs never change silently.
5. **Same pitch on two strings** (unison): allowed in data. Because one MIDI channel cannot hold two overlapping notes of the same pitch reliably, the earlier one is ended at the later one's onset in the realized durations. This is a documented limitation shown as a hint, not hidden.
6. Grid display: a small string number on assigned notes (expanded mode), a warning mark on unassignable notes.

## Data model (schema v3)
- `PitchNote.guitarString` (`int?` 1–6, 1 = high E, matching guitar convention; document it) and `PitchNote.stringLocked` (`bool`, user-chosen versus auto). The fret is derived, not stored.
- `PitchNote.ringBaseDur` (`int?`) + `PitchNote.ringBaseDurationSteps` (`double?`): the exact pre-ring `dur` and `durationSteps`, with null-ness kept. A null `ringBaseDur` means no ring is applied. Every length that ring or choke changes (including a choke made by assignment) stores them, so "울림 되돌리기" restores the exact JSON. They are written only when set.
- The constructor never keeps an impossible string. Any pitch change (transpose, octave, scale snap, fit to scale, arpeggiate, or a loaded file) that makes `guitarString` unplayable clears it together with `stringLocked`.
- The unassignable state is derived at assignment time and returned to the UI. A persisted flag is not needed. While the string view is on, the grid flags every sounding note without a string. That covers notes a later pitch edit made unplayable.
- Inheritance follows gt-001: copy/paste, duplicate and linked sections keep these fields. Re-timing edits (split, chop, glue, quantize, legato, humanize, resize, erase) keep `guitarString` and drop the ring base, so the new length becomes the note's own. Moves and velocity edits keep both. Undo deep-copies them.
- Schema stays v3 (all fields optional).

## Implementation decisions (2026-10-22, after Codex code review)
- **Assignment search:** at most 6 notes per hit, taken in pitch order. The rest are `tooMany`. A bounded DFS (at most 4,000 nodes per hit) picks, in order: more notes placed, fewer chokes, lowest fretted span (open strings excluded, hard cap 5, so a span of 4 or less wins when possible), lowest fret sum, then the mean fret closest to the previous hit. Unassignable reasons are `outOfRange`, `tooMany`, `noString`, `locked` (a locked note without a string; locked notes are never changed) and `invalid` (NaN, infinite or non-positive timing).
- **Fixed notes:** assigned notes outside the selection, locked notes and user-chosen strings (`stringLocked`) keep their string and constrain the search. Muted notes are ignored.
- **Overlap and choke:** each string keeps one interval list sorted by actual start on insert. Hits are processed in pre-stroke order, so a slow stroke's late strings can start after the next hit. The check covers every interval sounding over the new note, not only the latest-started one. A new note may take a string that is still sounding only if the sounding note may be cut (it is inside the edit). Each such choke counts against the choice. A note outside the edit is never cut, so its string is blocked while it sounds. The backward scan is bounded by the string's longest note. Typical tracks stay near O(n log n). A track with one very long note per string degrades toward O(n) per check (5,000 random notes: well under 1 s in the test).
- **Choke after assignment:** `enforceStringChoke` cuts edited, assigned notes at the next onset on their string or at their pitch, searched across the whole track. The original is kept in the ring base.
- **Ring cap:** a ring never extends past `rangeEnd`. That is the latest base end of the selected sounding notes, or the section end when nothing is selected, and never past the section. A note whose original already ends past the cap is left as it is: ring only extends, and only a same-string or same-pitch onset shortens. The section clip in flatten, export and live still truncates it at the section end (tested). Intervals are half-open: an onset exactly at the cap or at a note's end does not extend it.
- **Ring and stroke layering:** a ring keeps the gt-001 stroke tag. Applying, re-applying or reverting a stroke first undoes the ring, because its base length would be stale. Run the ring again afterwards. Ring revert is exact (JSON round trip) for stroke, then ring, then revert ring.
- **Stroke order with strings (lead decision):** when every note of a hit has a string, an explicit stroke strikes by string: down 6 to 1, up 1 to 6, ties by list index. If any note is unassigned, the whole hit uses pitch order. The legacy auto strum always keeps pitch order (golden unchanged).
- **MIDI export:** within one tick, the note-off ending an earlier note of a channel and pitch is written before a note-on of the same channel and pitch. Ticks without such a pair keep their exact byte order (golden unchanged).
- **Manual override:** offered only for strings where every selected note is playable. A note is refused, and counted in a message, if its pitch cannot sound on that string or another note of the same hit already holds it. "자동" clears the user mark and keeps the string.
- **UI:** the actions live in the expanded guitar panel (▸, guitar tracks only): 줄 배정, 울림 아르페지오, 울림 되돌리기, 줄 번호 보기/숨기기, 줄 직접 지정 (1–6) / 자동, a unison hint, and a groove hint on grooved tracks. Assignment turns the string view on. In that view the grid draws string numbers, outlines notes without a string in amber with "!", and shows a "줄 없음 N" count chip that selects them. Shortcuts: Ctrl/Cmd+Shift+G = assign strings (the workspace's Ctrl/Cmd+G groove has no Shift), Ctrl/Cmd+Shift+I = ringing arpeggio (I is unbound). Guitar tracks only.
- **Groove:** tested as it actually behaves. With a groove, both onsets move and lengths are kept, so the choke boundary moves by the difference of the two notes' shifts. A same-pitch choke still never cuts the new note (off before on).

## Edge cases
- Notes outside 40..(64+22) are unassignable on a standard-tuned 6-string, and nothing is octave-shifted.
- More than 6 simultaneous notes: the extras are unassignable.
- Locked notes are assigned only if they already fit, and they are never re-timed.
- Muted notes are silent, so they neither choke other notes nor get extended by ring. They keep their data.
- Section boundary and loop wrap: ringing stops at the section end (no ring across sections in v1). Stop silences everything immediately.
- A gt-001 stroke-converted hit plus ring: ring extends from each string's actual (offset) start; choke uses actual starts.

## HumTrack design
- New `lib/looptap/music/guitar_strings.dart`: tuning constants, `assignStrings(notes, selection) → (notes, unassignable)`, `applyRing(notes, selection, rangeEnd)`, `revertRing`, `enforceStringChoke`.
- `models/loop_models.dart`: the fields above (JSON only when set).
- `widgets/surfaces/step_grid.dart` + `widgets/sheets/guitar_stroke_panel.dart`: "줄 배정" and "울림 아르페지오" actions in the guitar section (expanded mode), string override menu, marks and warnings. Shortcuts only with Ctrl/Cmd combinations that are not already used (verify against step_grid and desktop_workspace).
- Arpeggiate (hm-002) is not changed. The user can run "울림 아르페지오" after it.

## Acceptance tests
- [x] Assignment: an open E major (40 47 52 56 59 64) gets six distinct strings with a valid span; a C-shape gets a plausible assignment; 7 simultaneous notes leave 1 unassignable; an out-of-range note is unassignable and its pitch is unchanged.
- [x] Never alters pitch or deletes notes (property test over random inputs).
- [x] Ring: on different strings, an earlier note's end becomes the next same-string onset or the range end. On the same string, it is cut at the re-pluck. Unison same pitch on two strings ends at the later onset.
- [x] Revert ring restores exact durations.
- [x] Live schedule == MIDI events for ring/choke results. WAV is built from the same events. *(MIDI on/off ticks == note data; live gates in a real EditScreen == exported lengths, plain and grooved. WAV renders from `buildMidi`. No separate WAV render test.)*
- [x] Integration: section end truncation, Stop, grooved track, duplicate and linked sections, save/load, undo/redo, copy/paste keep the fields, and muted/locked behavior as specified.
- [x] UI: actions appear only on guitar tracks; unassignable notes are highlighted with a count; each action is one undo; shortcuts don't collide with instrument keys.

## Out of scope
- Alternate tunings, capo, fret-hand fingering display/tab view, slides/bends/hammer-ons, palm mute and harmonics (G3+), program changes, and real per-string sample selection.
