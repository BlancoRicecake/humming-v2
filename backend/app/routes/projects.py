"""/projects CRUD — nested tracks / chunks / notes.

Storage strategy: a project write fully replaces the tracks-tree atomically
(simple, predictable for a 4-week MVP). For PUT, we delete existing tracks
(cascades down) then re-insert from payload. R2 audio_url cleanup happens
on DELETE.
"""
from __future__ import annotations

import logging
from typing import List, Optional
from urllib.parse import urlparse

from fastapi import APIRouter, Depends, HTTPException

from ..deps import CurrentUser, get_current_user, require_supabase, get_r2_client
from ..models import (
    ChunkIn, ChunkOut, NoteIn, NoteOut, ProjectCreate, ProjectOut,
    ProjectSummary, ProjectUpdate, TrackIn, TrackOut,
)
from ..settings import get_settings

logger = logging.getLogger("humming.projects")
router = APIRouter(prefix="/projects", tags=["projects"])


def _project_to_out(row: dict, tracks: List[TrackOut]) -> ProjectOut:
    return ProjectOut(
        id=row["id"], name=row["name"], bpm=row["bpm"],
        created_at=row["created_at"], updated_at=row["updated_at"],
        tracks=tracks,
    )


def _load_tracks(sb, project_id: str) -> List[TrackOut]:
    tr_rows = sb.table("tracks").select("*").eq("project_id", project_id).order("position").execute().data or []
    if not tr_rows:
        return []
    track_ids = [t["id"] for t in tr_rows]
    ch_rows = sb.table("chunks").select("*").in_("track_id", track_ids).execute().data or []
    chunk_ids = [c["id"] for c in ch_rows]
    nt_rows = (
        sb.table("notes").select("*").in_("chunk_id", chunk_ids).execute().data
        if chunk_ids else []
    ) or []

    notes_by_chunk: dict = {}
    for n in nt_rows:
        notes_by_chunk.setdefault(n["chunk_id"], []).append(
            NoteOut(id=n["id"], pitch=n["pitch"], start=n["start"],
                    duration=n["duration"], velocity=n["velocity"])
        )
    chunks_by_track: dict = {}
    for c in ch_rows:
        chunks_by_track.setdefault(c["track_id"], []).append(
            ChunkOut(
                id=c["id"], timeline_start=c["timeline_start"],
                in_point=c["in_point"], out_point=c["out_point"],
                original_length=c["original_length"], audio_url=c.get("audio_url"),
                notes=notes_by_chunk.get(c["id"], []),
            )
        )
    return [
        TrackOut(
            id=t["id"], role=t["role"], program=t["program"],
            options=t.get("options") or {}, position=t["position"],
            chunks=chunks_by_track.get(t["id"], []),
        )
        for t in tr_rows
    ]


def _insert_tracks_tree(sb, project_id: str, tracks: List[TrackIn]) -> None:
    for idx, tr in enumerate(tracks):
        tr_row = sb.table("tracks").insert({
            "project_id": project_id, "role": tr.role, "program": tr.program,
            "options": tr.options, "position": tr.position or idx,
        }).execute().data[0]
        for ch in tr.chunks:
            ch_row = sb.table("chunks").insert({
                "track_id": tr_row["id"],
                "timeline_start": ch.timeline_start,
                "in_point": ch.in_point, "out_point": ch.out_point,
                "original_length": ch.original_length,
                "audio_url": ch.audio_url,
            }).execute().data[0]
            if ch.notes:
                sb.table("notes").insert([
                    {"chunk_id": ch_row["id"], "pitch": n.pitch, "start": n.start,
                     "duration": n.duration, "velocity": n.velocity}
                    for n in ch.notes
                ]).execute()


@router.get("", response_model=List[ProjectSummary])
def list_projects(user: CurrentUser = Depends(get_current_user)):
    sb = require_supabase()
    rows = sb.table("projects").select("*").eq("user_id", user.id).order("updated_at", desc=True).execute().data or []
    return [ProjectSummary(**r) for r in rows]


@router.post("", response_model=ProjectOut, status_code=201)
def create_project(payload: ProjectCreate, user: CurrentUser = Depends(get_current_user)):
    sb = require_supabase()
    row = sb.table("projects").insert({
        "user_id": user.id, "name": payload.name, "bpm": payload.bpm,
    }).execute().data[0]
    if payload.tracks:
        _insert_tracks_tree(sb, row["id"], payload.tracks)
    return _project_to_out(row, _load_tracks(sb, row["id"]))


@router.get("/{project_id}", response_model=ProjectOut)
def get_project(project_id: str, user: CurrentUser = Depends(get_current_user)):
    sb = require_supabase()
    res = sb.table("projects").select("*").eq("id", project_id).eq("user_id", user.id).maybe_single().execute()
    row = getattr(res, "data", None)
    if not row:
        raise HTTPException(404, "project not found")
    return _project_to_out(row, _load_tracks(sb, project_id))


@router.put("/{project_id}", response_model=ProjectOut)
def update_project(project_id: str, payload: ProjectUpdate,
                   user: CurrentUser = Depends(get_current_user)):
    sb = require_supabase()
    res = sb.table("projects").select("*").eq("id", project_id).eq("user_id", user.id).maybe_single().execute()
    row = getattr(res, "data", None)
    if not row:
        raise HTTPException(404, "project not found")
    updates: dict = {}
    if payload.name is not None: updates["name"] = payload.name
    if payload.bpm is not None: updates["bpm"] = payload.bpm
    if updates:
        row = sb.table("projects").update(updates).eq("id", project_id).execute().data[0]
    if payload.tracks is not None:
        # full replace
        sb.table("tracks").delete().eq("project_id", project_id).execute()
        _insert_tracks_tree(sb, project_id, payload.tracks)
    return _project_to_out(row, _load_tracks(sb, project_id))


def _r2_keys_for_project(sb, project_id: str) -> List[str]:
    """Collect chunk audio_url values that point into our R2 bucket."""
    s = get_settings()
    tracks = sb.table("tracks").select("id").eq("project_id", project_id).execute().data or []
    if not tracks:
        return []
    track_ids = [t["id"] for t in tracks]
    chunks = sb.table("chunks").select("audio_url").in_("track_id", track_ids).execute().data or []
    keys: List[str] = []
    base = (s.r2_public_base_url or "").rstrip("/")
    for c in chunks:
        url = c.get("audio_url")
        if not url:
            continue
        if base and url.startswith(base + "/"):
            keys.append(url[len(base) + 1:])
        else:
            parsed = urlparse(url)
            if parsed.path:
                keys.append(parsed.path.lstrip("/"))
    return keys


@router.delete("/{project_id}", status_code=204)
def delete_project(project_id: str, user: CurrentUser = Depends(get_current_user)):
    sb = require_supabase()
    res = sb.table("projects").select("id").eq("id", project_id).eq("user_id", user.id).maybe_single().execute()
    if not getattr(res, "data", None):
        raise HTTPException(404, "project not found")

    # collect R2 objects before cascade
    keys = _r2_keys_for_project(sb, project_id)
    sb.table("projects").delete().eq("id", project_id).execute()

    # best-effort cleanup — never fail the API on storage hiccups
    r2 = get_r2_client()
    if r2 and keys:
        s = get_settings()
        try:
            r2.delete_objects(
                Bucket=s.r2_bucket,
                Delete={"Objects": [{"Key": k} for k in keys][:1000]},
            )
        except Exception:
            logger.exception("R2 cleanup failed for project %s", project_id)
    return None
