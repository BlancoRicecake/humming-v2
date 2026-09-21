"""Feature-flagged adapter for a future symbolic arrangement provider."""
from __future__ import annotations

import httpx
from fastapi import APIRouter, Header, HTTPException

from ..arrangement import ArrangementRequest, ArrangementResponse, enforce_locks
from ..auth import extract_user_id
from ..settings import get_settings

router = APIRouter(prefix="/arrangements", tags=["arrangements"])


@router.get("/capabilities")
def capabilities() -> dict:
    settings = get_settings()
    ready = bool(
        settings.arrangement_enabled
        and settings.arrangement_provider != "disabled"
        and settings.arrangement_base_url
    )
    return {
        "enabled": ready,
        "provider": settings.arrangement_provider if ready else "disabled",
        "schema": "humtrack.song-spec",
        "version": 1,
        "max_variations": 3,
        "melody_lock": True,
    }


@router.post("/generate", response_model=ArrangementResponse)
async def generate(
    payload: ArrangementRequest,
    authorization: str | None = Header(default=None),
) -> ArrangementResponse:
    settings = get_settings()
    if not settings.arrangement_enabled:
        raise HTTPException(503, "arrangement generation is disabled")
    if settings.arrangement_provider == "disabled" or not settings.arrangement_base_url:
        raise HTTPException(503, "arrangement provider is not configured")
    # Generation is an authenticated paid-resource boundary once enabled.
    # Feature-flag checks remain first so a disabled deployment exposes no auth
    # configuration details and continues to fail safely in local development.
    extract_user_id(authorization, tag="arrangements")

    headers = {"content-type": "application/json"}
    if settings.arrangement_api_key:
        headers["authorization"] = f"Bearer {settings.arrangement_api_key}"
    try:
        async with httpx.AsyncClient(timeout=settings.arrangement_timeout_sec) as client:
            response = await client.post(
                settings.arrangement_base_url.rstrip("/") + "/v1/arrangements",
                headers=headers,
                json=payload.model_dump(by_alias=True),
            )
            response.raise_for_status()
        result = ArrangementResponse.model_validate(response.json())
        if len(result.candidates) > payload.variation_count:
            raise ValueError("provider returned more candidates than requested")
        enforce_locks(payload.song, result.candidates)
        return result
    except (httpx.HTTPError, ValueError) as exc:
        raise HTTPException(502, f"arrangement provider rejected: {exc}") from exc
