"""Stage 9 — MIDI file output, using ``mido`` (≪ pretty_midi)."""
from __future__ import annotations

import io
from typing import Iterable, Sequence

import mido

from .schemas import Note


def _build_inst_track(
    notes: Iterable[Note],
    program: int,
    channel: int,
    sec_per_tick: float,
) -> mido.MidiTrack:
    """노트 한 묶음을 단일 MidiTrack 으로 변환 (program_change + note_on/off)."""
    track = mido.MidiTrack()
    # 드럼 채널(9)에는 program_change 가 의미 없지만 호환을 위해 그대로 둠.
    track.append(mido.Message("program_change", program=int(program),
                              channel=int(channel), time=0))
    events: list[tuple[float, int, int, int, int]] = []  # (time, kind_rank, pitch, vel, channel)
    for n in notes:
        if n.end <= n.start:
            continue
        pitch = max(0, min(127, int(n.pitch)))
        vel = max(1, min(127, int(n.velocity)))
        # 노트가 percussive 면 트랙 채널과 무관하게 GM 드럼 채널(9) 강제.
        ch = 9 if getattr(n, "kind", "pitched") == "percussive" else int(channel)
        events.append((float(n.start), 1, pitch, vel, ch))
        events.append((float(n.end),   0, pitch, 0,  ch))
    events.sort(key=lambda e: (e[0], e[1]))

    cursor_ticks = 0
    for t_sec, kind, pitch, vel, ch in events:
        abs_ticks = int(round(t_sec / sec_per_tick))
        delta = max(0, abs_ticks - cursor_ticks)
        cursor_ticks = abs_ticks
        msg = (mido.Message("note_on",  note=pitch, velocity=vel, channel=ch, time=delta)
               if kind == 1 else
               mido.Message("note_off", note=pitch, velocity=0,   channel=ch, time=delta))
        track.append(msg)
    track.append(mido.MetaMessage("end_of_track", time=0))
    return track


def tracks_to_midi_bytes(
    tracks: Sequence[dict],   # [{"notes": [Note...], "program": int, "channel": int}, ...]
    tempo_bpm: float = 120.0,
    ticks_per_beat: int = 480,
) -> bytes:
    """멀티트랙 Type-1 MIDI 빌드 — 트랙별 별도 MidiTrack + 자체 channel.

    각 트랙 dict 키: ``notes`` (List[Note]), ``program`` (int), ``channel`` (int).
    채널 충돌 방지/드럼 채널 강제는 호출 측에서 결정한 channel 을 그대로 사용.
    """
    mid = mido.MidiFile(type=1, ticks_per_beat=ticks_per_beat)
    sec_per_tick = 60.0 / (tempo_bpm * ticks_per_beat)

    # tempo 트랙 (conductor)
    tempo_track = mido.MidiTrack()
    tempo_track.append(mido.MetaMessage("set_tempo",
                                        tempo=mido.bpm2tempo(tempo_bpm),
                                        time=0))
    tempo_track.append(mido.MetaMessage("end_of_track", time=0))
    mid.tracks.append(tempo_track)

    for tr in tracks:
        notes = tr.get("notes") or []
        if not notes:
            continue
        mid.tracks.append(_build_inst_track(
            notes,
            program=int(tr.get("program") or 0),
            channel=int(tr.get("channel") or 0),
            sec_per_tick=sec_per_tick,
        ))

    buf = io.BytesIO()
    mid.save(file=buf)
    return buf.getvalue()


def notes_to_midi_bytes(
    notes: Iterable[Note],
    program: int = 0,         # 0 = Acoustic Grand Piano (GM)
    tempo_bpm: float = 120.0,
    ticks_per_beat: int = 480,
) -> bytes:
    """Build a Type-1 MIDI file from analyzed notes.

    Times in ``Note`` are absolute seconds; we convert to MIDI ticks using
    ``ticks_per_beat`` and ``tempo_bpm``. We do NOT emit pitch bends — Phase F
    decided velocity + integer pitch is enough; bend can be added later.
    """
    mid = mido.MidiFile(type=1, ticks_per_beat=ticks_per_beat)

    # --- tempo track
    tempo_track = mido.MidiTrack()
    tempo_track.append(mido.MetaMessage("set_tempo",
                                        tempo=mido.bpm2tempo(tempo_bpm),
                                        time=0))
    tempo_track.append(mido.MetaMessage("end_of_track", time=0))
    mid.tracks.append(tempo_track)

    # --- instrument track. Melodic notes → channel 0 (selected program);
    # percussive notes → channel 9 (GM drum channel 10, bank is implicit).
    inst_track = mido.MidiTrack()
    inst_track.append(mido.Message("program_change", program=int(program),
                                   channel=0, time=0))

    sec_per_tick = 60.0 / (tempo_bpm * ticks_per_beat)
    # Sort by start so we can emit deltas in order. We need to interleave
    # note_on/note_off events from possibly overlapping notes (chords) — flatten then sort.
    events: list[tuple[float, int, int, int, int]] = []  # (time, kind_rank, pitch, vel, channel)
    for n in notes:
        if n.end <= n.start:
            continue
        pitch = max(0, min(127, int(n.pitch)))
        vel = max(1, min(127, int(n.velocity)))
        ch = 9 if getattr(n, "kind", "pitched") == "percussive" else 0
        events.append((float(n.start), 1, pitch, vel, ch))    # note_on
        events.append((float(n.end),   0, pitch, 0,  ch))     # note_off (rank 0 before note_on so same-time release first)
    events.sort(key=lambda e: (e[0], e[1]))

    cursor_ticks = 0
    for t_sec, kind, pitch, vel, ch in events:
        abs_ticks = int(round(t_sec / sec_per_tick))
        delta = max(0, abs_ticks - cursor_ticks)
        cursor_ticks = abs_ticks
        msg = (mido.Message("note_on",  note=pitch, velocity=vel, channel=ch, time=delta)
               if kind == 1 else
               mido.Message("note_off", note=pitch, velocity=0,   channel=ch, time=delta))
        inst_track.append(msg)
    inst_track.append(mido.MetaMessage("end_of_track", time=0))
    mid.tracks.append(inst_track)

    buf = io.BytesIO()
    mid.save(file=buf)
    return buf.getvalue()
