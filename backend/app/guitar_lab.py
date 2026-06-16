"""기타 연구소 (Guitar Lab) — strummed-guitar audition renderer.

A research/tuning space for SoundLab: synthesize a guitar chord or power chord
through an arbitrary SF2 with the articulation parameters that make MIDI guitar
sound real — **strum timing**, **up/down stroke direction**, **per-string
velocity curve + humanization**, **string ring / palm-mute decay**, and
optional **continuous strum patterns** with chord-change damping.

Why this lives in the backend (and why it transfers to the app):
SoundLab's backend uses the SAME FluidSynth engine as the Android app, so every
parameter tuned here maps 1:1 to Android. iOS (MeltySynth) shares the same SF2
and the same note scheduling, so it transfers too. Crucially, every parameter
is expressed only as **noteOn time / velocity / noteOff time / SF2 selection** —
never as a runtime SF2-ADSR edit — so it is portable to both engines.

Reuses ``render.py``'s event-scheduling pattern (noteon/noteoff at sample
offsets, accumulate get_samples between events, peak-normalize, write WAV).
"""
from __future__ import annotations

import io
import random
from pathlib import Path
from typing import Dict, List, Optional, Tuple

import numpy as np
import soundfile as sf

from . import render as render_mod

# --- voicings ----------------------------------------------------------------
# Semitone offsets from the chord root, listed low string -> high string. These
# cover the three priority targets: acoustic chords, power chords, clean chords.
VOICINGS: Dict[str, List[int]] = {
    "power":      [0, 7],            # root + 5th
    "power_oct":  [0, 7, 12],        # root + 5th + octave (the classic power chord)
    "triad_maj":  [0, 4, 7],         # major triad
    "triad_min":  [0, 3, 7],         # minor triad
    "open_E_maj": [0, 7, 12, 16, 19, 24],  # full 6-string E-shape barre (major)
    "open_E_min": [0, 7, 12, 15, 19, 24],  # 6-string E-shape barre (minor)
    "barre_A_maj": [0, 7, 12, 16, 19],     # 5-string A-shape barre (major)
}

# Real 6-string guitar range, standard tuning (sounding pitch): open low E
# (E2 = MIDI 40) up to the 24th fret of the high E string (E6 = MIDI 88). Every
# rendered note is clamped into this window so the lab only ever produces sounds
# a real guitar can actually make — the testing standard.
GUITAR_LO = 40   # E2
GUITAR_HI = 88   # E6

DEFAULT_PARAMS = {
    "root": 40,            # E2 — open low-E, real open-position register
    "voicing": "open_E_maj",
    "strum_ms": 28.0,      # gap between successive strings
    "direction": "down",   # "down" = low->high, "up" = high->low
    "velocity": 100,       # base MIDI velocity
    "velocity_falloff": 18.0,   # % the last-struck string is quieter than the first
    "velocity_jitter": 8.0,     # +/- random velocity per string (humanize)
    "timing_jitter_ms": 4.0,    # +/- random onset jitter per string (humanize)
    "ring_ms": 1400.0,     # how long each string is allowed to ring
    "palm_mute": False,    # shortens ring + lowers velocity
    "let_ring": False,     # if False, a new strum dampens the previous chord
    "pattern": "",         # e.g. "D", "DU", "DUUDU"; empty = single down strum
    "bpm": 96.0,
    "repeats": 1,
    "reverb": 0.25,        # 0..1 -> CC91 send level
}

_CH = 0
_TAIL_SEC = 0.9


def _clamp_vel(v: float) -> int:
    return max(1, min(127, int(round(v))))


def _strum_onsets(params: dict) -> List[Tuple[float, str]]:
    """(time_sec, direction) for every strum, expanding any pattern + repeats."""
    pattern = str(params.get("pattern") or "").upper().strip()
    bpm = float(params.get("bpm") or 96.0)
    repeats = max(1, int(params.get("repeats") or 1))
    if not pattern:
        return [(0.0, str(params.get("direction") or "down"))]
    eighth = 60.0 / max(1.0, bpm) / 2.0  # one stroke per eighth note
    strokes = [c for c in pattern] * repeats
    out: List[Tuple[float, str]] = []
    for i, c in enumerate(strokes):
        if c == "D":
            out.append((i * eighth, "down"))
        elif c == "U":
            out.append((i * eighth, "up"))
        # any other char (space, '-', 'x') is a rest
    return out


def render_guitar_strum(
    sf2_path: str,
    sf_bank: int,
    sf_program: int,
    *,
    sample_rate: int = 44100,
    seed: Optional[int] = None,
    **params,
) -> bytes:
    """Render a strummed guitar phrase through ``sf2_path`` → WAV bytes.

    Raises ``FileNotFoundError`` if the SF2 is missing, ``RuntimeError`` if the
    engine is unavailable / fails to load the font.
    """
    render_mod.initialize()
    state = render_mod.get_state()
    if state.fluidsynth_module is None:
        raise RuntimeError(state.error or "SoundFont engine unavailable")
    if not Path(sf2_path).is_file():
        raise FileNotFoundError(sf2_path)

    p = {**DEFAULT_PARAMS, **{k: v for k, v in params.items() if v is not None}}
    rng = random.Random(seed)

    root = int(p["root"])
    offsets = VOICINGS.get(str(p["voicing"]), VOICINGS["triad_maj"])
    # Keep only notes within the real guitar range (E2..E6); a voicing note that
    # would fall outside is dropped rather than clamped, so we never pile two
    # strings onto the same boundary pitch.
    midis = sorted({n for o in offsets if GUITAR_LO <= (n := root + o) <= GUITAR_HI})  # low -> high
    if not midis:
        midis = [max(GUITAR_LO, min(GUITAR_HI, root))]

    strum_ms = max(0.0, float(p["strum_ms"]))
    base_vel = float(p["velocity"])
    falloff = float(p["velocity_falloff"]) / 100.0
    vel_jitter = float(p["velocity_jitter"])
    time_jitter = float(p["timing_jitter_ms"]) / 1000.0
    ring = float(p["ring_ms"]) / 1000.0
    palm = bool(p["palm_mute"])
    let_ring = bool(p["let_ring"])
    if palm:
        ring = min(ring, 0.18)       # palm mute = quick choke
        base_vel *= 0.82

    onsets = _strum_onsets(p)
    strum_times = [t for (t, _d) in onsets]

    events: List[Tuple[float, int, int, int]] = []  # (time, rank, pitch, vel)
    n = len(midis)
    for k, (t0, direction) in enumerate(onsets):
        order = list(midis) if direction == "down" else list(reversed(midis))
        # hard cutoff when the NEXT strum re-strikes (chord-change damping),
        # unless the user chose let-ring (strings overlap and decay naturally).
        next_t = strum_times[k + 1] if k + 1 < len(strum_times) else None
        for i, pitch in enumerate(order):
            onset = max(0.0, t0 + i * (strum_ms / 1000.0) + rng.uniform(-time_jitter, time_jitter))
            curve = 1.0 - falloff * (i / (n - 1) if n > 1 else 0.0)
            vel = _clamp_vel(base_vel * curve + rng.uniform(-vel_jitter, vel_jitter))
            off = onset + ring
            if next_t is not None and not let_ring:
                off = min(off, next_t - 0.004)
            if off <= onset:
                off = onset + 0.02
            events.append((onset, 1, pitch, vel))
            events.append((off, 0, pitch, 0))

    events.sort(key=lambda e: (e[0], e[1]))  # note-off (rank 0) before note-on at a tie

    fluidsynth = state.fluidsynth_module
    synth = fluidsynth.Synth(samplerate=float(sample_rate), gain=0.5)
    try:
        sfid = synth.sfload(sf2_path)
        if sfid == -1:
            raise RuntimeError(f"sfload failed for {sf2_path}")
        synth.program_select(_CH, sfid, int(sf_bank), int(sf_program))
        # reverb send (CC91) — FluidSynth's reverb unit is on by default
        synth.cc(_CH, 91, _clamp_vel(float(p["reverb"]) * 127))

        out: List[np.ndarray] = []
        cursor = 0.0
        for t_sec, kind, pitch, vel in events:
            n_samples = int(round((t_sec - cursor) * sample_rate))
            if n_samples > 0:
                out.append(np.asarray(synth.get_samples(n_samples), dtype=np.int16))
            if kind == 1:
                synth.noteon(_CH, pitch, vel)
            else:
                synth.noteoff(_CH, pitch)
            cursor = t_sec
        tail = int(round(_TAIL_SEC * sample_rate))
        if tail > 0:
            out.append(np.asarray(synth.get_samples(tail), dtype=np.int16))

        audio = np.concatenate(out) if out else np.zeros(int(0.1 * sample_rate), dtype=np.int16)
        if audio.size % 2 != 0:
            audio = audio[:-1]
        stereo = audio.reshape(-1, 2)
        peak = float(np.max(np.abs(stereo))) or 1.0
        scale = min(8.0, 32000.0 / peak)
        stereo = (stereo.astype(np.float32) * scale).astype(np.int16)
        buf = io.BytesIO()
        sf.write(buf, stereo, sample_rate, format="WAV", subtype="PCM_16")
        return buf.getvalue()
    finally:
        try:
            synth.delete()
        except Exception:
            pass


# --- sound list --------------------------------------------------------------
# GM guitar family (programs 24-31) lives in the global SF2; labels come live
# from the loaded font. Catalog guitar SF2s (downloaded CC0 fonts) are listed
# too so the user can A/B them against GM in the lab.
GM_GUITAR_RANGE = range(24, 32)


def list_guitar_sounds() -> List[dict]:
    """Guitar sounds available to audition: GM programs 24-31 + catalog fonts.

    Each item mirrors the audition-item shape used elsewhere so the existing
    ``_resolve_audition_source`` can resolve it to an sf2 path.
    """
    from . import soundfonts as soundfonts_mod

    names: Dict[Tuple[int, int], str] = {}
    try:
        for pr in render_mod.list_presets():
            names[(int(pr["bank"]), int(pr["program"]))] = str(pr["name"])
    except Exception:
        pass

    items: List[dict] = []
    for prog in GM_GUITAR_RANGE:
        items.append({
            "key": f"gm:0:{prog}",
            "source": "gm",
            "label": names.get((0, prog), f"Program {prog}"),
            "category": "GM Guitars",
            "bank": 0,
            "program": prog,
            "soundfont_id": None,
        })
    # catalog guitar fonts (role == "melody" guitars, or anything tagged guitar)
    try:
        for e in soundfonts_mod.load_catalog():
            label = str(e.get("label", e["id"]))
            cat = str(e.get("category") or "")
            if "guitar" not in label.lower() and "guitar" not in cat.lower():
                continue
            items.append({
                "key": f"catalog:{e['id']}",
                "source": "catalog",
                "label": label,
                "category": "Catalog Guitars",
                "bank": int(e.get("sf_bank", 0)),
                "program": int(e.get("sf_program", 0)),
                "soundfont_id": str(e["id"]),
            })
    except Exception:
        pass
    return items
