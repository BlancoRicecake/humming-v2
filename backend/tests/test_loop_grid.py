"""Stage 6c loop-grid snapping (_apply_loop_grid).

Runs standalone (`python tests/test_loop_grid.py`) or under pytest. Verifies that
notes hard-snap to integer steps, durations become whole steps, swung input maps
back to the correct linear step, collisions dedup, and out-of-loop notes drop.
"""
import os
import sys

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

from app.analyze import _apply_loop_grid, _swung_step_time, _estimate_grid_phase  # noqa: E402
from app.schemas import AnalyzeOptions, Note  # noqa: E402


def _note(start, dur, pitch=60, conf=0.9, kind="pitched", drum=None):
    return Note(
        start=start, end=start + dur, duration=dur,
        pitch=pitch, pitch_raw=float(pitch), pitch_hz=440.0,
        velocity=100, confidence=conf, voiced_ratio=1.0, kind=kind, drum=drum,
    )


def _opts(bpm=120, bars=2, swing=0.0, grid=16, spb=16, as_drums=False):
    return AnalyzeOptions(
        loop_quantize=True, loop_bars=bars, steps_per_bar=spb,
        tempo_bpm=bpm, quantize_grid=grid, swing=swing, as_drums=as_drums,
    )


def _cell(o):
    return (60.0 / o.tempo_bpm) * 4.0 / o.quantize_grid


def test_basic_snapping():
    o = _opts()
    cell = _cell(o)  # 0.125s at 120 BPM / grid 16
    # near-grid onsets with small jitter → steps 0, 2, 4, 6
    notes = [_note(0.004, cell), _note(2 * cell - 0.01, cell),
             _note(4 * cell + 0.012, cell), _note(6 * cell - 0.006, cell)]
    out = _apply_loop_grid(notes, o, duration=2 * cell * 16)
    assert [n.step for n in out] == [0, 2, 4, 6], [n.step for n in out]
    for n in out:
        assert isinstance(n.step, int) and 0 <= n.step < 32
        assert isinstance(n.dur_steps, int) and n.dur_steps >= 1


def test_out_of_loop_dropped():
    o = _opts(bars=2)  # 32 steps total
    cell = _cell(o)
    notes = [_note(0.0, cell), _note(40 * cell, cell)]  # second is past loop end
    out = _apply_loop_grid(notes, o, duration=2 * cell * 16)
    assert all(0 <= n.step < 32 for n in out)
    assert len(out) == 1


def test_duration_clamped_to_loop():
    o = _opts(bars=2)
    cell = _cell(o)
    n = _note(31 * cell, cell * 10)  # huge dur near loop end
    out = _apply_loop_grid([n], o, duration=2 * cell * 16)
    assert out[0].step == 31
    assert out[0].dur_steps == 1  # clamped to remaining steps


def test_dedup_pitched_keeps_most_confident():
    o = _opts()
    cell = _cell(o)
    a = _note(2 * cell, cell, pitch=60, conf=0.4)
    b = _note(2 * cell + 0.005, cell, pitch=62, conf=0.95)  # same step, more confident
    out = _apply_loop_grid([a, b], o, duration=2 * cell * 16)
    assert len(out) == 1
    assert out[0].pitch == 62


def test_dedup_drums_per_kind():
    o = _opts(as_drums=True)
    cell = _cell(o)
    k1 = _note(0.0, cell, kind="percussive", drum=36)
    k2 = _note(0.004, cell, kind="percussive", drum=36)  # same kick, same step
    s1 = _note(0.004, cell, kind="percussive", drum=38)  # snare same step, kept
    out = _apply_loop_grid([k1, k2, s1], o, duration=2 * cell * 16)
    drums = sorted((n.drum, n.step) for n in out)
    assert drums == [(36, 0), (38, 0)], drums


def test_swing_roundtrip():
    o = _opts(swing=0.5)
    cell = _cell(o)
    phase = 0.0
    # place notes exactly at the swung playback time of steps 1,3,5 (odd → delayed)
    notes = [_note(_swung_step_time(k, cell, phase, 0.5), cell) for k in (1, 3, 5)]
    out = _apply_loop_grid(notes, o, duration=2 * cell * 16)
    assert [n.step for n in out] == [1, 3, 5], [n.step for n in out]


def test_storage_is_linear():
    # stored start/end must be linear grid positions (swing applied at playback),
    # so n.start == step * cell within rounding.
    o = _opts(swing=0.4)
    cell = _cell(o)
    n = _note(_swung_step_time(3, cell, 0.0, 0.4), cell)
    out = _apply_loop_grid([n], o, duration=2 * cell * 16)
    assert out[0].step == 3
    assert abs(out[0].start - 3 * cell) < 1e-6


def _run():
    fns = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    for fn in fns:
        fn()
        print(f"ok  {fn.__name__}")
    print(f"\n{len(fns)} passed")


if __name__ == "__main__":
    _run()
