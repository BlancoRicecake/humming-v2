"""Python mirror of LoopTap's Dart engine→app note mapping.

Faithful 1:1 port of the conversion the app applies AFTER the engine returns
notes, so the offline eval (eval_looptap.py) can reproduce the EXACT notes the
LoopTap UI produces. Sources:
  - mobile/lib/looptap/screens/edit_screen.dart : _phraseOctaveShift,
    _snapToLadder, _drumKind, _humConvert (the pitched/drum placement loops)
  - mobile/lib/looptap/music/theory.dart : buildLadder / Rung / kScales / rootMidi

KEEP IN SYNC with the Dart source. backend/tests/test_looptap_map.py emits a
golden-vector JSON that the Dart parity test (mobile/test/looptap/
hum_map_parity_test.dart) checks against, so drift between the two is caught.

Pure-Python (no numpy) and duck-typed on the note object (needs .step,
.dur_steps, .pitch, .kind, .drum, .drum_name) so it imports without the heavy
analysis stack and is trivially unit-testable.
"""
from __future__ import annotations

import math
from dataclasses import dataclass
from typing import List, Optional, Sequence

# theory.dart kNoteNames
NOTE_NAMES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

# theory.dart kScales — LoopTap's LADDER scale vocabulary. NOTE: this is the
# app's own 4-scale set, distinct from backend app/scales.py's 13-scale literal.
# 'pentatonic' here is the minor pentatonic.
SCALE_STEPS = {
    "minor": [0, 2, 3, 5, 7, 8, 10],
    "major": [0, 2, 4, 5, 7, 9, 11],
    "pentatonic": [0, 3, 5, 7, 10],
    "dorian": [0, 2, 3, 5, 7, 9, 10],
}


def _round_dart(x: float) -> int:
    """Dart num.round(): nearest int, ties rounded AWAY from zero.

    Python's built-in round() is banker's rounding (half-to-even), which would
    disagree on .5 cases — so we replicate Dart's behaviour explicitly.
    """
    return int(math.floor(x + 0.5)) if x >= 0 else int(math.ceil(x - 0.5))


@dataclass(frozen=True)
class Rung:
    """theory.dart Rung (freq omitted — eval only needs midi/name/degree/index)."""
    midi: int
    name: str
    degree: int
    index: int


def root_midi(name: str, oct: int) -> int:
    """theory.dart rootMidi: 12*(oct+1) + noteIndex (C4 = 60)."""
    return 12 * (oct + 1) + NOTE_NAMES.index(name)


def build_ladder(name: str, mode: str, oct: int, count: int = 8) -> List[Rung]:
    """theory.dart buildLadder — `count` ascending in-key scale degrees."""
    steps = SCALE_STEPS.get(mode, SCALE_STEPS["minor"])
    base = root_midi(name, oct)
    out: List[Rung] = []
    for i in range(count):
        deg = i % len(steps)
        oct_shift = i // len(steps)
        midi = base + steps[deg] + 12 * oct_shift
        out.append(Rung(midi=midi, name=NOTE_NAMES[midi % 12], degree=deg, index=i))
    return out


def phrase_octave_shift(midis: Sequence[int], ladder: List[Rung]) -> int:
    """hum_map.dart phraseOctaveShift — whole-octave shift centering the
    phrase MEAN on the ladder's range.

    Mean, not median: the shift must agree between the engine's notes and the
    intended melody, and the median is a knife-edge statistic — when the phrase
    center sits near the ÷12 rounding boundary, a 1-semitone median difference
    flips the WHOLE phrase by an octave (HumTrans dev: 6% of samples, each one
    scoring ~0 pitch). The mean moves smoothly with small note differences
    (dev100 shift agreement 0.94 → 0.96, app_note_f1_t1 0.871 → 0.890)."""
    lst = list(midis)
    if not lst:
        return 0
    mean = sum(lst) / len(lst)                        # Dart reduce(+) / length
    center = (ladder[0].midi + ladder[-1].midi) // 2  # Dart (first+last) ~/ 2
    return _round_dart((center - mean) / 12) * 12


def snap_to_ladder(midi: int, ladder: List[Rung]) -> Rung:
    """edit_screen.dart _snapToLadder — fold into ladder range by octaves, then
    nearest rung (ties → lower index, matching Dart's strict `< bestD`)."""
    lo, hi = ladder[0].midi, ladder[-1].midi
    m = midi
    while m < lo - 6:
        m += 12
    while m > hi + 6:
        m -= 12
    best = ladder[0]
    best_d = 9999
    for r in ladder:
        d = abs(r.midi - m)
        if d < best_d:
            best_d = d
            best = r
    return best


def drum_kind(drum: Optional[int], drum_name: Optional[str], pitch: int) -> Optional[str]:
    """edit_screen.dart _drumKind — GM/name → 'kick' | 'snare' | 'hihat'."""
    name = (drum_name or "").lower()
    if "kick" in name:
        return "kick"
    if "snare" in name:
        return "snare"
    if "hat" in name:
        return "hihat"
    d = drum if drum is not None else pitch
    if d == 36:
        return "kick"
    if d in (38, 40):
        return "snare"
    if d in (42, 44, 46):
        return "hihat"
    return None


def map_engine_notes_to_app(notes, ladder: List[Rung], *, drums: bool, steps: int):
    """edit_screen.dart _humConvert placement loops (loop_quantize path).

    Pitched → list of {step, midi, dur}; drums → list of {step, kind}. Mirrors
    the app exactly: octave-fold + ladder-snap for pitched, GM→kind + per
    (kind, step) dedup for drums, with the same `0 <= step < steps` guard. The
    engine already deduped pitched notes per step, so no extra pitched dedup.
    """
    if drums:
        out = []
        seen = set()
        for n in notes:
            step = n.step
            if step is None or step < 0 or step >= steps:
                continue
            kind = drum_kind(getattr(n, "drum", None), getattr(n, "drum_name", None), n.pitch)
            if kind is None:
                continue
            key = (kind, step)
            if key in seen:
                continue
            seen.add(key)
            out.append({"step": int(step), "kind": kind})
        return out

    pitched = [n for n in notes if getattr(n, "kind", "pitched") != "percussive"]
    shift = phrase_octave_shift([n.pitch for n in pitched], ladder)
    out = []
    for n in pitched:
        step = n.step
        if step is None or step < 0 or step >= steps:
            continue
        raw_dur = n.dur_steps if n.dur_steps is not None else 1
        dur = max(1, min(int(raw_dur), steps - int(step)))
        rung = snap_to_ladder(int(n.pitch) + shift, ladder)
        out.append({"step": int(step), "midi": rung.midi, "dur": dur})
    return out
