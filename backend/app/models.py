"""Pydantic schemas for P0 backend endpoints (projects / storage / iap).

DSP schemas (notes etc.) remain in ``schemas.py``; this module only covers
the new persistence + commerce surface so we don't tangle the analyzer.
"""
from __future__ import annotations

from datetime import datetime
from typing import List, Literal, Optional

from pydantic import BaseModel, Field

Role = Literal["vocal", "instrument", "drum", "chord"]
Store = Literal["app_store", "play_store"]
SubStatus = Literal["trial", "active", "cancelled", "expired"]


# --- Notes / chunks / tracks / projects (nested) ----------------------------
class NoteIn(BaseModel):
    pitch: int = Field(..., ge=0, le=127)
    start: float = 0.0
    duration: float = 0.0
    velocity: int = Field(100, ge=0, le=127)


class NoteOut(NoteIn):
    id: str


class ChunkIn(BaseModel):
    timeline_start: float = 0.0
    in_point: float = 0.0
    out_point: float = 0.0
    original_length: float = 0.0
    audio_url: Optional[str] = None
    notes: List[NoteIn] = Field(default_factory=list)


class ChunkOut(BaseModel):
    id: str
    timeline_start: float
    in_point: float
    out_point: float
    original_length: float
    audio_url: Optional[str]
    notes: List[NoteOut] = Field(default_factory=list)


class TrackIn(BaseModel):
    role: Role = "instrument"
    program: int = 0
    options: dict = Field(default_factory=dict)
    position: int = 0
    chunks: List[ChunkIn] = Field(default_factory=list)


class TrackOut(BaseModel):
    id: str
    role: Role
    program: int
    options: dict
    position: int
    chunks: List[ChunkOut] = Field(default_factory=list)


class ProjectCreate(BaseModel):
    name: str = "Untitled"
    bpm: int = Field(90, ge=20, le=320)
    tracks: List[TrackIn] = Field(default_factory=list)


class ProjectUpdate(BaseModel):
    name: Optional[str] = None
    bpm: Optional[int] = Field(None, ge=20, le=320)
    # Full replace of tracks tree (simple, atomic). Omit to leave untouched.
    tracks: Optional[List[TrackIn]] = None


class ProjectSummary(BaseModel):
    id: str
    name: str
    bpm: int
    created_at: datetime
    updated_at: datetime


class ProjectOut(ProjectSummary):
    tracks: List[TrackOut] = Field(default_factory=list)


# --- Storage ----------------------------------------------------------------
class PresignRequest(BaseModel):
    file_name: str = Field(..., min_length=1, max_length=200)
    content_type: str = "audio/wav"
    size_bytes: int = Field(..., gt=0, le=5 * 1024 * 1024)


class PresignResponse(BaseModel):
    upload_url: str
    method: Literal["PUT"] = "PUT"
    headers: dict = Field(default_factory=dict)
    public_url: str
    expires_in: int
    key: str


# --- IAP --------------------------------------------------------------------
class IapVerifyRequest(BaseModel):
    store: Store
    receipt_data: str = Field(..., min_length=1)
    product_id: Optional[str] = None


class IapVerifyResponse(BaseModel):
    status: SubStatus
    product_id: str
    expires_at: Optional[datetime]
    trial_ends_at: Optional[datetime]
    store: Store
