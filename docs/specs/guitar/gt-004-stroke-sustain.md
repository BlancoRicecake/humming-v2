# Guitar: per-string sustain for strummed chords (줄별 울림 유지)

- **ID:** gt-004
- **Status:** implemented (uncommitted) (2026-10-23). Approved 2026-10-23 after the A/B listening test ("적용본이 좀 더 자연스럽네"); Codex manages and verifies. Code: `mobile/lib/looptap/music/guitar_sustain.dart` (+ `ringNoteToEnd` in `guitar_strings.dart`, panel button, `step_grid.dart` wiring). Tests: `mobile/test/looptap/guitar_sustain_test.dart`, `guitar_sustain_ui_test.dart`. Logs: `artifacts/guitar-sustain-20261023/`.
- **Evidence:** `artifacts/guitar-stroke-ring-20261022/` (BEFORE/AFTER, README, levels.json); `docs/product/guitar-listening-evaluation.md` (last section, user evaluation).
- **Builds on:** gt-001 (StrokeTag, `strokeGroupStart`, base timing), gt-002 (`assignStrings`, `applyRing`, `revertRing`, ring base fields), gt-003 (articulations).

## Review amendments (Codex, 2026-10-23, binding; override the rule below where they conflict)
Principle: a narrower, safe supported range over complex widening; refuse and explain when unclear.
1. **Assignment never leaks lengths.** `assignStrings` may choke internally (`enforceStringChoke`). Only its string numbers are used. A note whose length the assignment would change is refused (줄 배정 불가) and gets no string; a target whose length it would change is not used (줄 배정 불가). Already-long, articulated and outside-scope notes are never altered.
2. **Temporary analysis copy.** Strings are assigned on a temporary copy of the whole track (sounding, unlocked, not user-chosen notes without a string), so outside notes are judged with strings but never written: their JSON stays byte-identical.
3. **Selection boundaries.** With a selection, if A or B is only partly inside the scope the pair is refused (**부분 선택**). B must be the immediate next hit on the whole track and fully inside the scope; if it lies outside, the pair is refused (**선택 경계**). Separated selected regions are never bridged.
4. **Per-note rest check.** A note is extended only if *its own* original end (StrokeTag base end) reaches B's base start within 0.05 step. One string cut short on purpose stays cut (쉼/끊김); the hit is not force-extended.
5. **Micro-timing preserved.** Only the end of an eligible note moves, to the exact onset of the same-string, same-pitch note in B.
6. **Explicit strokes only, both hits.** A pair connects only if **every** sounding note of A and of B is stroke-tagged. An untagged member (legacy auto strum at playback, so its stored onset is not the real strike) refuses the whole pair (스트로크 미적용), as A or as B.
7. **Narrowest metadata rule.** An automatic string is written **only to a note that is actually extended**. Targets, refused, locked, muted, articulated, untagged and outside-scope notes keep byte-identical JSON.
8. **Collisions (implementation).** If another onset on the same string or at the same pitch (whole track, analysis strings) lies between the note's onset and the target, the note is refused with the extra reason **충돌**. This keeps the MIDI rule "no same-pitch overlap on a channel" (e.g. unison strings).

Reason codes added by the amendments: **부분 선택**, **선택 경계**, **충돌**. Other refusals map as: no string or an assignment choke = 줄 배정 불가; same pitch but on another string in B = 화음 변경; next hit at or after the section end, or a target past it = 섹션 끝; a note or a member of A/B with an articulation = 연주법.

## User-visible behavior
1. The "기타 연주" panel gets a new action, **[줄별 울림 유지]**, separate from [울림 아르페지오]. Description: "같은 화음을 다시 칠 때까지 각 줄을 자연스럽게 이어 줍니다. 화음이 바뀌거나 쉼이 있으면 그대로 둡니다."
2. Scope: the selection, or the whole track if nothing is selected. Only notes in scope are modified. Notes outside the scope are still considered when finding the next hit and checking collisions.
3. One press = one undo. That undo includes any automatic string assignment.
4. Result message: `연장 N · 그대로 M` plus reasons. The reason codes are:

   | Code | Meaning |
   |---|---|
   | 화음 변경 | the next chord differs |
   | 쉼/끊김 | intentional rest or gap |
   | 스트로크 미적용 | the note has no stroke conversion |
   | 연주법 | staccato/palm/harmonic articulation, kept |
   | 잠김/음소거 | locked or muted note |
   | 줄 배정 불가 | no string could be assigned |
   | 이미 연결됨 | the note already reaches the target |
   | 섹션 끝 | the hit is last in the section |

   If nothing can be extended, it shows a hint instead of reporting success.
5. Nothing runs automatically. Existing songs and the default stroke are never converted in the background.

## Rule (pure function `applyStrokeSustain(notes, scope, ctx) → (notes, report)`)
- **Eligible note:** in scope, has `stroke != null` (explicit gt-001 conversion; **v1 is limited to stroked notes**), and is not muted, not locked and has no articulation.
- **Hits:** group the whole track's sounding (non-muted) notes into hits by `strokeGroupStart` (the base start, tolerance 0.05 step), as gt-001 does. Untagged notes form their own hits by actual start.
- **Next hit:** for hit A, the next hit B is the next hit on the whole track by base start. Selection is not considered here.
- **Same chord (conservative):** the multiset of sounding pitches of A equals that of B, **exactly** (same voicing; inversions or changed voicings count as different). Notes outside the scope count toward both multisets. If either hit contains an articulated note, they are not connected.
- **No rest:** A's latest original end (from the StrokeTag base end: `step + baseOffsetSteps + base length`, or the actual end for untagged notes) must be ≥ B's base start − 0.05 step. Otherwise it is a rest or cut and A is not connected.
- **Section end:** if B doesn't exist inside the section, nothing changes.
- **Connection:** for an eligible note n in A on string s, find the note in B on the **same string s with the same pitch**.
  - If it exists and its actual onset is later than n's current end, extend n's end to exactly that onset (via the existing `applyRing` machinery, so `ringBaseDur`/`ringBaseDurationSteps` record the original and [울림 되돌리기] restores it).
  - If n already reaches or passes it, n is unchanged (never shortened).
  - If there is no same-string, same-pitch note, n is unchanged.
- **Strings:** notes without `guitarString` in A or B are auto-assigned first by the existing `assignStrings`, limited to the scope plus what is needed. Explicit user string choices (`stringLocked`) are never changed. Unassignable notes are counted and left unchanged.
- **Preserved:**
  - note-on (step and offset), pitch, velocity, StrokeTag, articulation and note count
  - every note outside the scope
  - muted, locked and articulated notes, including their gates
  - chord changes, rests and the section end
  - same-key ordering: note-off before note-on at the same tick (MIDI export already does this)

Why this is safer than ringing every note: only exact repeats of the same voicing are joined. Anything ambiguous (changed voicing, partial selection that splits a hit, mixed arpeggio) is left as-is and reported.

## Review amendments (Codex, 2026-10-23, binding)
1. **Auto-assignment as preparation never leaks length changes.** Only the string fields are taken from `assignStrings`; its internal choke must not shorten anything. A note whose assignment would need a choke or length change is refused (reason 줄 배정 불가/충돌).
2. **Outside-scope notes get strings only on a temporary analysis copy.** Their JSON stays byte-identical.
3. **Partial selection:** a hit A or B that is only partly inside the scope is refused (reason 부분 선택). With a selection, B must be the immediate next hit on the whole track **and** fully inside the scope. Gaps between separate selected regions are never bridged (reason 선택 경계).
4. **Per-note rest check, not the hit maximum:** a note is extended only if its **own** original end reaches B's base start within 0.05 step. A single string intentionally cut short stays cut.
5. **Micro-timing:** intentional onsets and offsets are preserved. Only the end of an eligible note moves, and only to the exact same-string, same-pitch onset in B.

## HumTrack design
- New `lib/looptap/music/guitar_sustain.dart` with `applyStrokeSustain`, which reuses `strokeGroupStart`, `assignStrings` and `applyRing` (or `withRing`) from the existing modules. It adds no new analysis.
- UI: one button in `guitar_stroke_panel.dart` (next to the string actions) wired in `step_grid.dart` through the existing `_commit` path, with the result line and hint. No shortcut and no default change.
- No model or schema change: it reuses the existing string and ring fields.

## Acceptance tests
- [x] **Equivalence:** applying it to the A3-normal song (G2 demo data) reproduces the approved AFTER (`artifacts/guitar-stroke-ring-20261022/AFTER-A3-normal-ring.song.json`) exactly: identical durations for all 288 notes (200 extended), same onsets, velocities and tags. The AFTER files are read only, never modified.
- [x] **Hits 5→6 and 2→3:** every string's end equals the next same-string, same-pitch onset.
- [x] **Not connected:**
  - a chord change where the same pitch is in the next chord but the voicing differs
  - a voicing change
  - a rest gap
  - the section end
  - a partial selection (outside notes unchanged but considered)
  - a mixed arpeggio or untagged notes
  - articulated, muted or locked notes
  - a manually chosen string
- [x] An already-long note is neither extended nor shortened. Re-applying is idempotent.
- [x] **One undo** restores the exact JSON, including auto-assigned strings. Redo, save/load, [울림 되돌리기] and G1/G2/G3 layers are kept.
- [x] **MIDI:** same-key off-before-on, no same-pitch overlap on a channel. Live schedule equals export lengths for the extended notes.
- [x] **UI:** the button only on guitar tracks, inside "기타 연주"; result counts and reasons shown; hint when nothing applies.
- [x] G0–G3 goldens and the full suite pass; analyze is clean.

## Implementation notes (2026-10-23)
- `applyStrokeSustain(notes, selection, {sectionSteps})` returns `StrokeSustainResult` (notes, remapped selection, `extended`, `reasons` per `SustainReason`, `stringsAssigned`, `summary()` = "연장 N · 그대로 M (reasons)"). Every note in scope is counted once: extended, or kept with one reason. Nothing extended returns the input list itself (no edit, no strings).
- Extensions use `ringNoteToEnd` (a public wrapper of the `applyRing` end rewrite in `guitar_strings.dart`), so `ringBaseDur` / `ringBaseDurationSteps` keep the original and 울림 되돌리기 restores it. `applyRing` itself is not called: its range cap and "extend to the next onset" cannot express "only to the same-string, same-pitch re-strike, else unchanged".
- UI: **[줄별 울림 유지]** (`guitar-sustain`) next to 울림 아르페지오 in the "기타 연주" panel, the description text (`guitar-sustain-info`) and the last result (`guitar-sustain-result`); the result also shows as a snack bar. With nothing extended it shows the hint "이어 줄 음이 없습니다. 스트로크를 적용한 같은 화음을 같은 줄에서 다시 칠 때만 이어집니다." plus the counts, and makes no edit. One press = one `_commit` (the strings it writes are in the same undo). No shortcut.
- A3 equivalence: all 288 durations equal the approved AFTER (200 extended; 88 kept = 화음 변경 42, 섹션 끝 6, 이미 연결됨 40). Extended notes equal the AFTER JSON exactly; the 88 kept notes stay identical to BEFORE, so unlike the demo they get no `guitarString` (amendment 7).
- Test notes: undo/redo/save/load and live gates are verified in a real EditScreen; redo is one `redo()` call. Linked sections and copy/paste reuse the gt-002 fields (tested there), not re-tested here. The G0–G3 golden and articulation suites pass unchanged.

## Out of scope / limitations
- Untagged (legacy auto-strum) chords: v1 reports "스트로크 미적용". Apply a stroke first.
- No pitch-class or harmonic analysis: a different voicing of the same chord name is treated as a change. This is deliberately conservative.
- No automatic or background conversion, no new defaults, no listening claims.
