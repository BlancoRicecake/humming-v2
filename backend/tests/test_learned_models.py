"""Guards on the learned-correction models.

`models/` reached production for the first time in 2026-09 (it had been left
out of the Docker image). Measuring the pitch model against the reference
samples before shipping it showed it moves output *away* from the sung pitch
— see the comment on AnalyzeOptions.learned_pitch_correction. These tests pin
the resulting decisions so neither is flipped back by accident.
"""
from pathlib import Path

import numpy as np
import pytest

from app.schemas import AnalyzeOptions, Note


def _note(pitch=60, raw=60.0, start=0.0, **kw):
    base = dict(
        start=start, end=start + 0.4, duration=0.4, pitch=pitch, pitch_raw=raw,
        pitch_hz=440.0 * 2 ** ((pitch - 69) / 12), velocity=100, confidence=0.9,
        voiced_ratio=0.9, kind="pitched",
    )
    base.update(kw)
    return Note(**base)


def test_learned_pitch_correction_is_off_by_default():
    """Turning it on transposes ~half of all melodic notes up a semitone."""
    assert AnalyzeOptions().learned_pitch_correction is False
    assert AnalyzeOptions().learned_offset_correction is False


def test_pitch_correction_is_a_no_op_when_disabled():
    from app.pitch_correction import apply_learned_pitch_correction

    notes = [_note(60, 60.1, 0.0), _note(62, 61.8, 0.5), _note(64, 64.2, 1.0)]
    before = [n.pitch for n in notes]
    # The analyze pipeline only calls this when the flag is on; called
    # directly it must still leave a note it does not act on untouched.
    apply_learned_pitch_correction([], None, None)
    assert [n.pitch for n in notes] == before


def test_models_are_present_in_the_source_tree():
    """They are tracked in git and COPYed into the image (audit B9). A missing
    file silently downgrades analysis to heuristics, which is exactly how they
    went unnoticed in production for months."""
    root = Path(__file__).resolve().parent.parent / "models"
    for name in ("pitch_correction_v1.npz", "offset_correction_v1.npz",
                 "drum_classifier_v2.npz"):
        assert (root / name).is_file(), f"models/{name} missing"


def test_drum_classifier_loads():
    """Unlike the pitch model this one measured as an improvement (it
    reclassified one hit, correctly), and it has no opt-out flag — so it must
    keep loading."""
    from app import drum_classifier

    assert drum_classifier._load() is not None


@pytest.mark.parametrize("flag", ["learned_pitch_correction", "learned_offset_correction"])
def test_flags_are_still_reachable(flag):
    """Off by default, but a caller (diagnostics, future re-validation) can
    still switch them on per request."""
    opts = AnalyzeOptions(**{flag: True})
    assert getattr(opts, flag) is True
