"""Unit tests for the Dart→Python app-mapping mirror (app/looptap_map.py).

Also emits a golden-vector JSON consumed by the Dart parity test
(mobile/test/looptap/fixtures/hum_map_golden.json) so the two implementations
cannot drift. Run `python tests/test_looptap_map.py` (or with REGEN_GOLDEN=1) to
(re)write the golden file; plain pytest only asserts the Python side.
"""
import json
import os
import sys
from types import SimpleNamespace

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

from app.looptap_map import (  # noqa: E402
    Rung, build_ladder, phrase_octave_shift, snap_to_ladder, drum_kind,
    map_engine_notes_to_app, _round_dart,
)

GOLDEN_PATH = os.path.abspath(os.path.join(
    os.path.dirname(__file__), "..", "..", "mobile", "test", "looptap", "fixtures",
    "hum_map_golden.json",
))


def test_round_dart_half_away_from_zero():
    assert _round_dart(2.5) == 3
    assert _round_dart(-2.5) == -3
    assert _round_dart(1.5) == 2
    assert _round_dart(2.4) == 2
    assert _round_dart(-2.4) == -2
    assert _round_dart(0.5) == 1


def test_build_ladder_c_minor():
    rungs = build_ladder("C", "minor", 4, 8)
    assert [r.midi for r in rungs] == [60, 62, 63, 65, 67, 68, 70, 72]
    assert rungs[0].name == "C" and rungs[2].name == "D#"


def test_build_ladder_a_major_bass_octave():
    # bass grid ladder uses octave 2
    rungs = build_ladder("A", "major", 2, 8)
    base = 12 * 3 + 9  # A2 = 45
    assert rungs[0].midi == base
    assert [r.midi for r in rungs] == [base + s for s in [0, 2, 4, 5, 7, 9, 11, 12]]


def test_phrase_octave_shift_folds_high_phrase_down():
    ladder = build_ladder("C", "minor", 4, 8)  # 60..72, center 66
    # mean 84 → (66-84)/12 = -1.5 → round-away → -2 → -24
    assert phrase_octave_shift([83, 84, 85], ladder) == -24
    # already centered → no shift
    assert phrase_octave_shift([66], ladder) == 0
    assert phrase_octave_shift([], ladder) == 0


def test_phrase_octave_shift_uses_mean_not_median():
    # Median knife-edge regression (HumTrans dev F01_0032_0001_1): median 60
    # would sit exactly on the 0.5 rounding boundary → +12, but the mean
    # (61.67) stays clearly on the no-shift side.
    ladder = build_ladder("C", "minor", 4, 8)  # 60..72, center 66
    assert phrase_octave_shift([60, 60, 65], ladder) == 0


def test_snap_to_ladder():
    ladder = build_ladder("C", "minor", 4, 8)
    assert snap_to_ladder(61, ladder).midi == 60   # tie 60/62 → lower index
    assert snap_to_ladder(64, ladder).midi == 63    # nearest in-key
    # out-of-range folds into the ladder octave first
    assert snap_to_ladder(48, ladder).midi == 60
    assert snap_to_ladder(84, ladder).midi == 72


def test_drum_kind_name_then_gm():
    assert drum_kind(None, "Acoustic Snare", 0) == "snare"
    assert drum_kind(36, None, 0) == "kick"
    assert drum_kind(42, None, 0) == "hihat"
    assert drum_kind(40, None, 0) == "snare"
    assert drum_kind(None, None, 99) is None


def _note(step, pitch, dur=1, kind="pitched", drum=None, drum_name=None):
    return SimpleNamespace(step=step, dur_steps=dur, pitch=pitch, kind=kind,
                           drum=drum, drum_name=drum_name)


def test_map_pitched_octave_fold_and_ladder_snap():
    ladder = build_ladder("C", "minor", 4, 8)
    notes = [_note(0, 84), _note(4, 87), _note(8, 91)]  # an octave+ above grid
    out = map_engine_notes_to_app(notes, ladder, drums=False, steps=32)
    assert [o["step"] for o in out] == [0, 4, 8]
    # all snapped notes must be in-key ladder pitches
    ladder_midis = {r.midi for r in ladder}
    assert all(o["midi"] in ladder_midis for o in out)


def test_map_pitched_drops_out_of_range_and_clamps_dur():
    ladder = build_ladder("C", "minor", 4, 8)
    notes = [_note(30, 60, dur=10), _note(40, 60)]  # 2nd is past 32-step loop
    out = map_engine_notes_to_app(notes, ladder, drums=False, steps=32)
    assert len(out) == 1
    assert out[0]["step"] == 30 and out[0]["dur"] == 2  # clamped to remaining


def test_map_drums_dedup_per_kind_step():
    notes = [_note(0, 36, kind="percussive", drum=36),
             _note(0, 36, kind="percussive", drum=36),   # dup kick @0 → dropped
             _note(0, 38, kind="percussive", drum=38)]    # snare @0 kept
    out = map_engine_notes_to_app(notes, [], drums=True, steps=32)
    assert sorted((o["kind"], o["step"]) for o in out) == [("kick", 0), ("snare", 0)]


# ── golden vectors for the Dart parity test ────────────────────────────────
def _golden():
    ladders = [
        {"name": "C", "mode": "minor", "oct": 4, "count": 8},
        {"name": "A", "mode": "major", "oct": 4, "count": 8},
        {"name": "F#", "mode": "dorian", "oct": 4, "count": 8},
        {"name": "D", "mode": "pentatonic", "oct": 2, "count": 8},
    ]
    cases = []
    for spec in ladders:
        ladder = build_ladder(spec["name"], spec["mode"], spec["oct"], spec["count"])
        cases.append({
            "ladder_spec": spec,
            "ladder_midis": [r.midi for r in ladder],
            "octave_shift": [
                {"midis": m, "out": phrase_octave_shift(m, ladder)}
                # [60, 60, 65] pins the mean rule (median would flip by +12
                # on the C-minor ladder — the knife-edge this rule replaced)
                for m in ([60, 62], [83, 84, 85], [40], [66], [], [60, 60, 65])
            ],
            "snap": [
                {"midi": x, "out": snap_to_ladder(x, ladder).midi}
                for x in range(spec_lo(ladder) - 8, spec_hi(ladder) + 9)
            ],
        })
    return {"version": 1, "cases": cases}


def spec_lo(ladder):
    return ladder[0].midi


def spec_hi(ladder):
    return ladder[-1].midi


def _write_golden():
    os.makedirs(os.path.dirname(GOLDEN_PATH), exist_ok=True)
    with open(GOLDEN_PATH, "w", encoding="utf-8") as fh:
        json.dump(_golden(), fh, indent=2)
    print(f"wrote golden → {GOLDEN_PATH}")


def test_golden_matches_file_if_present():
    # If the golden file exists, it must match what Python currently computes
    # (regenerate with REGEN_GOLDEN=1 after an intentional mapping change).
    if not os.path.exists(GOLDEN_PATH):
        return
    with open(GOLDEN_PATH, encoding="utf-8") as fh:
        on_disk = json.load(fh)
    assert on_disk == _golden(), "golden drifted — run REGEN_GOLDEN=1 and update Dart"


def _run():
    fns = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    for fn in fns:
        fn()
        print(f"ok  {fn.__name__}")
    print(f"\n{len(fns)} passed")


if __name__ == "__main__":
    if os.environ.get("REGEN_GOLDEN") == "1" or "--write-golden" in sys.argv:
        _write_golden()
    _run()
