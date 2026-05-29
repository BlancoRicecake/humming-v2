"""Stage 8 — optional SoundFont audio rendering via pyfluidsynth.

Listed as *optional* because it requires a system-level dependency
(FluidSynth DLL). We bundle a portable Windows build under ``backend/bin/``
and add it to PATH at import time. On systems without the DLL the
``/render_audio`` endpoint returns 503 and the UI button disables itself.
"""
from __future__ import annotations

import io
import os
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import List, Optional, Sequence, Tuple

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


def render_notes_to_wav(
    notes: Sequence[Note],
    program: int = 0,
    sample_rate: int = 44100,
) -> bytes:
    """Render notes via fluidsynth + SF2 directly (no pretty_midi).

    ``Note.kind == "percussive"`` notes are routed to GM drum channel 10
    (channel index 9) using the note's pitch as the drum kit selector.
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
        synth.program_select(0, sfid, 0, int(program))   # melodic channel
        synth.program_select(9, sfid, 128, 0)             # GM drum bank 128 on ch10

        events: List[Tuple[float, int, int, int, int]] = []  # (time, rank, pitch, vel, channel)
        for n in notes:
            if n.end <= n.start:
                continue
            v = max(1, min(127, int(n.velocity)))
            p = max(0, min(127, int(n.pitch)))
            ch = 9 if n.kind == "percussive" else 0
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
                synth.program_select(9, sfid, 128, 0)
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
