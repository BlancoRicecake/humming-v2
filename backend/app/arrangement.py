"""Provider-neutral contract for optional AI arrangement.

HumTrack owns this small symbolic schema. Providers may be swapped without
changing saved projects, and a locked melody is verified after every call.
"""
from __future__ import annotations

from typing import Dict, List, Literal, Optional

from pydantic import BaseModel, ConfigDict, Field, model_validator


class SongSpecNote(BaseModel):
    midi: int = Field(ge=0, le=127)
    step: int = Field(ge=0)
    duration: int = Field(gt=0)
    sourceMidi: Optional[int] = Field(default=None, ge=0, le=127)
    confidence: float = Field(default=1.0, ge=0.0, le=1.0)
    locked: bool = False


class SongSpecTrack(BaseModel):
    notes: List[SongSpecNote] = Field(default_factory=list, max_length=4096)


class SongSpecSection(BaseModel):
    id: str = Field(min_length=1, max_length=80)
    name: str = Field(default="Section", max_length=120)
    bars: int = Field(ge=1, le=128)
    repeats: int = Field(default=1, ge=1, le=64)
    tracks: Dict[str, SongSpecTrack] = Field(default_factory=dict)


class SongSpec(BaseModel):
    model_config = ConfigDict(extra="forbid")

    schema_: Literal["humtrack.song-spec"] = Field(alias="schema")
    version: Literal[1]
    title: str = Field(default="Untitled", max_length=200)
    tonic: str = Field(default="C", max_length=8)
    scale: str = Field(default="major", max_length=32)
    bpm: int = Field(ge=30, le=300)
    swing: float = Field(default=0.0, ge=0.0, le=1.0)
    locks: Dict[str, bool] = Field(default_factory=lambda: {"melody": True})
    sections: List[SongSpecSection] = Field(min_length=1, max_length=64)

    @model_validator(mode="after")
    def validate_note_bounds(self) -> "SongSpec":
        for section in self.sections:
            max_step = section.bars * 16
            for track in section.tracks.values():
                if any(n.step + n.duration > max_step for n in track.notes):
                    raise ValueError(
                        f"note exceeds section {section.id!r} length ({max_step} steps)"
                    )
        return self


class ArrangementRequest(BaseModel):
    song: SongSpec
    style: str = Field(default="keep-current", min_length=1, max_length=80)
    variation_count: int = Field(default=3, ge=1, le=3)


class ArrangementResponse(BaseModel):
    provider: str
    candidates: List[SongSpec] = Field(min_length=1, max_length=3)


def melody_signature(song: SongSpec) -> tuple:
    """Canonical melody identity used for the non-destructive lock invariant."""
    return tuple(
        (
            section.id,
            tuple(
                (n.midi, n.step, n.duration, n.sourceMidi)
                for n in section.tracks.get("melody", SongSpecTrack()).notes
            ),
        )
        for section in song.sections
    )


def enforce_locks(source: SongSpec, candidates: List[SongSpec]) -> None:
    if not source.locks.get("melody", False):
        return
    expected = melody_signature(source)
    for index, candidate in enumerate(candidates):
        if melody_signature(candidate) != expected:
            raise ValueError(f"candidate {index} modified the locked melody")
