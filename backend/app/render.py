"""Stage 8 — optional SoundFont audio rendering via pyfluidsynth.

Listed as *optional* because it requires a system-level dependency
(FluidSynth DLL). We bundle a portable Windows build under ``backend/bin/``
and add it to PATH at import time. On systems without the DLL the
``/render_audio`` endpoint returns 503 and the UI button disables itself.
"""
from __future__ import annotations

import io
import os
import struct
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional, Sequence, Tuple

import numpy as np
import soundfile as sf

from .schemas import Note

DEFAULT_SF2 = r"C:\Users\jlion\Downloads\GeneralUser_GS_v2.0.3--doc_r6\GeneralUser-GS\GeneralUser-GS.sf2"
BUNDLED_FS_BIN = (
    Path(__file__).resolve().parent.parent
    / "bin" / "fluidsynth-2.5.4" / "fluidsynth-v2.5.4-win10-x64-cpp11" / "bin"
)


def _prepare_fluidsynth_path() -> None:
    """Inject the bundled DLL directory into PATH before fluidsynth is imported."""
    if not BUNDLED_FS_BIN.exists():
        return
    path_str = str(BUNDLED_FS_BIN)
    if sys.platform.startswith("win"):
        cur = os.environ.get("PATH", "")
        if path_str not in cur.split(os.pathsep):
            os.environ["PATH"] = path_str + os.pathsep + cur
        if hasattr(os, "add_dll_directory"):
            try:
                os.add_dll_directory(path_str)
            except (FileNotFoundError, OSError):
                pass


@dataclass
class RenderState:
    fluidsynth_module: object = None
    sf2_path: Optional[str] = None
    error: Optional[str] = None


_STATE = RenderState()


def initialize() -> None:
    if _STATE.fluidsynth_module is not None or _STATE.error is not None:
        return
    _prepare_fluidsynth_path()
    try:
        import fluidsynth  # type: ignore
    except Exception as e:
        _STATE.error = f"fluidsynth load failed: {e}"
        return
    _STATE.fluidsynth_module = fluidsynth
    sf2 = os.environ.get("HUMMING_SF2_PATH", DEFAULT_SF2)
    if sf2 and Path(sf2).is_file():
        _STATE.sf2_path = sf2
    else:
        _STATE.error = f"SF2 not found at {sf2!r}"


def get_state() -> RenderState:
    return _STATE


def is_available() -> bool:
    initialize()
    return _STATE.fluidsynth_module is not None and _STATE.sf2_path is not None


def is_engine_available() -> bool:
    """FluidSynth module loaded, regardless of the global SF2.

    The audition path passes its own sf2 path (GM / catalog / sentinel), so it
    only needs the synth engine — not ``_STATE.sf2_path``. Kept separate from
    ``is_available()`` so the existing /render_* endpoints are unaffected.
    """
    initialize()
    return _STATE.fluidsynth_module is not None


# Minimal GM list — the user asked specifically for piano, others are nice-to-have.
GM_PROGRAMS: List[Tuple[int, str]] = [
    (0,  "Acoustic Grand Piano"),
    (4,  "Electric Piano"),
    (16, "Drawbar Organ"),
    (24, "Nylon Guitar"),
    (32, "Acoustic Bass"),
    (40, "Violin"),
    (48, "String Ensemble"),
    (52, "Choir Aahs"),
    (56, "Trumpet"),
    (73, "Flute"),
    (80, "Lead 1 (square)"),
    (81, "Lead 2 (sawtooth)"),
]


# --- SF2 preset enumeration -------------------------------------------------
def list_presets() -> List[Dict[str, object]]:
    """Enumerate every preset in the loaded SF2 by parsing its ``phdr`` chunk.

    Robust + dependency-free: pyfluidsynth does not expose preset iteration,
    so we read the SoundFont's RIFF ``pdta/phdr`` directly. Each preset header
    is a fixed 38-byte record; the list terminates with a sentinel ("EOP").

    Returns dicts ``{bank, program, name}`` sorted by (bank, program). The
    GM melodic bank is 0; the GM percussion bank is 128.
    """
    initialize()
    if not _STATE.sf2_path:
        return []
    try:
        raw = Path(_STATE.sf2_path).read_bytes()
    except OSError:
        return []

    # Locate the 'phdr' subchunk: 4-byte tag, 4-byte little-endian size, body.
    idx = raw.find(b"phdr")
    if idx < 0:
        return []
    (size,) = struct.unpack_from("<I", raw, idx + 4)
    body = raw[idx + 8 : idx + 8 + size]

    presets: List[Dict[str, object]] = []
    for off in range(0, len(body) - 37, 38):
        name = body[off : off + 20].split(b"\x00", 1)[0]
        preset, bank = struct.unpack_from("<HH", body, off + 20)
        text = name.decode("latin-1", "replace").strip()
        if text == "EOP":  # terminal sentinel record
            break
        if not text:
            continue
        presets.append({"bank": int(bank), "program": int(preset), "name": text})

    presets.sort(key=lambda p: (p["bank"], p["program"]))
    return presets


# A short, instrument-agnostic audition phrase: C major arpeggio up + held
# octave. Times in seconds, pitches in MIDI. Drum presets (bank 128) get a
# simple kick/snare/hat pattern instead so they actually trigger.
_DEMO_MELODIC: List[Tuple[float, float, int]] = [  # (start, dur, pitch)
    (0.00, 0.28, 60), (0.30, 0.28, 64), (0.60, 0.28, 67),
    (0.90, 0.80, 72),
    (0.90, 0.80, 60), (0.90, 0.80, 64), (0.90, 0.80, 67),  # held triad
]
_DEMO_DRUM: List[Tuple[float, float, int]] = [  # GM drum map: 36 kick, 38 snare, 42 hat
    (0.00, 0.20, 36), (0.25, 0.15, 42), (0.50, 0.20, 38), (0.75, 0.15, 42),
    (1.00, 0.20, 36), (1.25, 0.15, 42), (1.50, 0.20, 38), (1.75, 0.15, 42),
]
_DEMO_BASS: List[Tuple[float, float, int]] = [  # low-register walk: C2 G2 C3 C2
    (0.00, 0.45, 36), (0.50, 0.45, 43), (1.00, 0.45, 48), (1.50, 0.60, 36),
]


def _phrase_for(track_type: str) -> List[Tuple[float, float, int]]:
    """Audition phrase per track type (the new audition path picks by role,
    not by ``bank == 128``)."""
    if track_type == "drums":
        return _DEMO_DRUM
    if track_type == "bass":
        return _DEMO_BASS
    return _DEMO_MELODIC


def render_demo_to_wav(bank: int, program: int, sample_rate: int = 44100) -> bytes:
    """Render the fixed audition phrase through one SF2 preset (bank+program)."""
    initialize()
    if not is_available():
        raise RuntimeError(_STATE.error or "SoundFont preview unavailable")

    fluidsynth = _STATE.fluidsynth_module
    synth = fluidsynth.Synth(samplerate=float(sample_rate), gain=0.5)
    try:
        sfid = synth.sfload(_STATE.sf2_path)
        if sfid == -1:
            raise RuntimeError(f"sfload failed for {_STATE.sf2_path}")
        synth.program_select(0, sfid, int(bank), int(program))

        phrase = _DEMO_DRUM if int(bank) == 128 else _DEMO_MELODIC
        events: List[Tuple[float, int, int, int]] = []  # (time, rank, pitch, vel)
        for start, dur, pitch in phrase:
            events.append((start, 1, pitch, 100))
            events.append((start + dur, 0, pitch, 0))
        events.sort(key=lambda e: (e[0], e[1]))

        out = []
        cursor = 0.0
        for t_sec, kind, pitch, vel in events:
            n_samples = int(round((t_sec - cursor) * sample_rate))
            if n_samples > 0:
                out.append(np.asarray(synth.get_samples(n_samples), dtype=np.int16))
            if kind == 1:
                synth.noteon(0, pitch, vel)
            else:
                synth.noteoff(0, pitch)
            cursor = t_sec
        tail = int(round(0.7 * sample_rate))
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
        try: synth.delete()
        except Exception: pass


def render_notes_to_wav(
    notes: Sequence[Note],
    program: int = 0,
    sample_rate: int = 44100,
    bank: int = 0,
) -> bytes:
    """Render notes via fluidsynth + SF2 directly (no pretty_midi).

    ``bank`` selects the SF2 bank for the melodic program (0 = GM melodic,
    8/11/12 = GeneralUser GS variation banks, 128 = drum kits). When
    ``bank == 128`` the chosen kit is loaded on ch10 and **all** notes are
    routed there — i.e. the user is auditioning a drum kit as the instrument.
    Otherwise ``Note.kind == "percussive"`` notes still fall through to the
    default GM drum kit on ch10.
    """
    initialize()
    if not is_available():
        raise RuntimeError(_STATE.error or "SoundFont preview unavailable")

    drum_kit = int(bank) == 128
    fluidsynth = _STATE.fluidsynth_module
    synth = fluidsynth.Synth(samplerate=float(sample_rate), gain=0.5)
    try:
        sfid = synth.sfload(_STATE.sf2_path)
        if sfid == -1:
            raise RuntimeError(f"sfload failed for {_STATE.sf2_path}")
        if drum_kit:
            synth.program_select(9, sfid, 128, int(program))  # selected drum kit on ch10
        else:
            synth.program_select(0, sfid, int(bank), int(program))  # melodic channel
            synth.program_select(9, sfid, 128, 0)                   # default GM kit on ch10

        events: List[Tuple[float, int, int, int, int]] = []  # (time, rank, pitch, vel, channel)
        for n in notes:
            if n.end <= n.start:
                continue
            v = max(1, min(127, int(n.velocity)))
            p = max(0, min(127, int(n.pitch)))
            ch = 9 if (drum_kit or n.kind == "percussive") else 0
            events.append((float(n.start), 1, p, v, ch))    # note_on (rank 1)
            events.append((float(n.end),   0, p, 0,  ch))   # note_off (rank 0 first)
        events.sort(key=lambda e: (e[0], e[1]))

        out = []
        cursor = 0.0
        for t_sec, kind, pitch, vel, ch in events:
            n_samples = int(round((t_sec - cursor) * sample_rate))
            if n_samples > 0:
                out.append(np.asarray(synth.get_samples(n_samples), dtype=np.int16))
            if kind == 1:
                synth.noteon(ch, pitch, vel)
            else:
                synth.noteoff(ch, pitch)
            cursor = t_sec

        tail = int(round(0.6 * sample_rate))
        if tail > 0:
            out.append(np.asarray(synth.get_samples(tail), dtype=np.int16))

        if not out:
            audio = np.zeros(int(0.1 * sample_rate), dtype=np.int16)
        else:
            audio = np.concatenate(out)
        if audio.size % 2 != 0:
            audio = audio[:-1]
        stereo = audio.reshape(-1, 2)

        # peak-normalize lightly
        peak = float(np.max(np.abs(stereo))) or 1.0
        scale = min(8.0, 32000.0 / peak)  # 작은 신호도 풀스케일로 증폭(상한 8x)
        stereo = (stereo.astype(np.float32) * scale).astype(np.int16)

        buf = io.BytesIO()
        sf.write(buf, stereo, sample_rate, format="WAV", subtype="PCM_16")
        return buf.getvalue()
    finally:
        try: synth.delete()
        except Exception: pass


def render_demo_through_sf2(
    sf2_path: str,
    sf_bank: int,
    sf_program: int,
    track_type: str = "melody",
    sample_rate: int = 44100,
) -> bytes:
    """Render the per-track-type audition phrase through an ARBITRARY .sf2.

    Used by the sound-picker (Space B) to audition GM, downloaded catalog, and
    the 808/hip-hop sentinel soundfonts alike. Loads ``sf2_path`` into a
    throwaway Synth — it never touches ``_STATE.sf2_path``, so it is
    concurrent-safe and leaves the engine-experiment space (Space A) untouched.

    Drums route to channel 9 (GM percussion); melody/bass to channel 0.

    Raises ``FileNotFoundError`` if ``sf2_path`` is missing and ``RuntimeError``
    if the soundfont fails to load.
    """
    initialize()
    if _STATE.fluidsynth_module is None:
        raise RuntimeError(_STATE.error or "SoundFont engine unavailable")
    if not Path(sf2_path).is_file():
        raise FileNotFoundError(sf2_path)

    fluidsynth = _STATE.fluidsynth_module
    channel = 9 if track_type == "drums" else 0
    synth = fluidsynth.Synth(samplerate=float(sample_rate), gain=0.5)
    try:
        sfid = synth.sfload(sf2_path)
        if sfid == -1:
            raise RuntimeError(f"sfload failed for {sf2_path}")
        synth.program_select(channel, sfid, int(sf_bank), int(sf_program))

        phrase = _phrase_for(track_type)
        events: List[Tuple[float, int, int, int]] = []  # (time, rank, pitch, vel)
        for start, dur, pitch in phrase:
            events.append((start, 1, pitch, 100))
            events.append((start + dur, 0, pitch, 0))
        events.sort(key=lambda e: (e[0], e[1]))

        out = []
        cursor = 0.0
        for t_sec, kind, pitch, vel in events:
            n_samples = int(round((t_sec - cursor) * sample_rate))
            if n_samples > 0:
                out.append(np.asarray(synth.get_samples(n_samples), dtype=np.int16))
            if kind == 1:
                synth.noteon(channel, pitch, vel)
            else:
                synth.noteoff(channel, pitch)
            cursor = t_sec
        tail = int(round(0.7 * sample_rate))
        if tail > 0:
            out.append(np.asarray(synth.get_samples(tail), dtype=np.int16))

        audio = np.concatenate(out) if out else np.zeros(int(0.1 * sample_rate), dtype=np.int16)
        if audio.size % 2 != 0:
            audio = audio[:-1]
        stereo = audio.reshape(-1, 2)
        peak = float(np.max(np.abs(stereo))) or 1.0
        scale = min(8.0, 32000.0 / peak)  # 작은 신호도 풀스케일로 증폭(상한 8x)
        stereo = (stereo.astype(np.float32) * scale).astype(np.int16)
        buf = io.BytesIO()
        sf.write(buf, stereo, sample_rate, format="WAV", subtype="PCM_16")
        return buf.getvalue()
    finally:
        try: synth.delete()
        except Exception: pass


def render_tracks_to_wav(
    tracks: Sequence[dict],
    sample_rate: int = 44100,
) -> bytes:
    """Render multiple tracks mixed into one WAV.

    Each track dict: ``{"notes": [Note...], "program": int}``. A track whose
    notes are percussive is routed to GM drum channel 9 (bank 128); melodic
    tracks each get their own channel + program. FluidSynth mixes them.
    """
    initialize()
    if not is_available():
        raise RuntimeError(_STATE.error or "SoundFont preview unavailable")

    fluidsynth = _STATE.fluidsynth_module
    synth = fluidsynth.Synth(samplerate=float(sample_rate), gain=0.5)
    try:
        sfid = synth.sfload(_STATE.sf2_path)
        if sfid == -1:
            raise RuntimeError(f"sfload failed for {_STATE.sf2_path}")

        events: List[Tuple[float, int, int, int, int]] = []  # (time, rank, pitch, vel, channel)
        melodic_ch = 0
        for tr in tracks:
            notes = tr.get("notes") or []
            program = int(tr.get("program") or 0)
            is_perc = bool(notes) and all(n.kind == "percussive" for n in notes)
            if is_perc:
                ch = 9
                synth.program_select(9, sfid, 128, program)
            else:
                if melodic_ch == 9:
                    melodic_ch += 1
                ch = melodic_ch
                melodic_ch += 1
                synth.program_select(ch, sfid, 0, program)
            for n in notes:
                if n.end <= n.start:
                    continue
                v = max(1, min(127, int(n.velocity)))
                p = max(0, min(127, int(n.pitch)))
                c = 9 if n.kind == "percussive" else ch
                events.append((float(n.start), 1, p, v, c))
                events.append((float(n.end), 0, p, 0, c))
        events.sort(key=lambda e: (e[0], e[1]))

        out = []
        cursor = 0.0
        for t_sec, kind, pitch, vel, ch in events:
            n_samples = int(round((t_sec - cursor) * sample_rate))
            if n_samples > 0:
                out.append(np.asarray(synth.get_samples(n_samples), dtype=np.int16))
            if kind == 1:
                synth.noteon(ch, pitch, vel)
            else:
                synth.noteoff(ch, pitch)
            cursor = t_sec
        tail = int(round(0.6 * sample_rate))
        if tail > 0:
            out.append(np.asarray(synth.get_samples(tail), dtype=np.int16))

        audio = np.concatenate(out) if out else np.zeros(int(0.1 * sample_rate), dtype=np.int16)
        if audio.size % 2 != 0:
            audio = audio[:-1]
        stereo = audio.reshape(-1, 2)
        peak = float(np.max(np.abs(stereo))) or 1.0
        scale = min(8.0, 32000.0 / peak)  # 작은 신호도 풀스케일로 증폭(상한 8x)
        stereo = (stereo.astype(np.float32) * scale).astype(np.int16)
        buf = io.BytesIO()
        sf.write(buf, stereo, sample_rate, format="WAV", subtype="PCM_16")
        return buf.getvalue()
    finally:
        try: synth.delete()
        except Exception: pass
