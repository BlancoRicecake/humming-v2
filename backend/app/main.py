"""SoundLab — minimal FastAPI surface.

Endpoints (one per pipeline boundary):
- GET  /health               — liveness
- GET  /samples              — auto-discovered audio files in the samples dir
- GET  /samples/{slug}       — serve a sample file by slug
- POST /analyze              — Stage 2-7 (returns notes + debug data)
- POST /export_midi          — Stage 9 (writes a .mid via mido)
"""
from __future__ import annotations

import base64
import json
import logging
import os
import re
from pathlib import Path
from typing import Dict, List, Tuple

from fastapi import FastAPI, File, Form, HTTPException, Request, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, JSONResponse, Response
from starlette.middleware.base import BaseHTTPMiddleware

from .analyze import analyze_audio, process_vocal
from .assistant import run_key_and_assistant
from .midi_build import notes_to_midi_bytes, tracks_to_midi_bytes
from . import render as render_mod
from .schemas import AnalyzeOptions, AnalyzeResponse, DetectedKey, Note
from .settings import get_settings
from .routes import projects as projects_routes
from .routes import storage as storage_routes
from .routes import iap as iap_routes
from .routes import health as health_routes

logger = logging.getLogger("soundlab")
logging.basicConfig(level=logging.INFO)

_settings = get_settings()

# --- Sentry (optional) ------------------------------------------------------
if _settings.sentry_dsn:
    try:
        import sentry_sdk
        from sentry_sdk.integrations.fastapi import FastApiIntegration
        from sentry_sdk.integrations.starlette import StarletteIntegration
        sentry_sdk.init(
            dsn=_settings.sentry_dsn,
            environment=_settings.environment,
            traces_sample_rate=_settings.sentry_traces_sample_rate,
            integrations=[FastApiIntegration(), StarletteIntegration()],
            send_default_pii=False,
        )
        logger.info("Sentry initialised env=%s", _settings.environment)
    except ImportError:
        logger.warning("SENTRY_DSN set but sentry-sdk not installed")

app = FastAPI(title="Humming V2 backend", version="0.3.0")

# --- Rate limit (slowapi) ---------------------------------------------------
try:
    from slowapi import Limiter
    from slowapi.errors import RateLimitExceeded
    from slowapi.middleware import SlowAPIMiddleware
    from slowapi.util import get_remote_address

    limiter = Limiter(key_func=get_remote_address, default_limits=[])
    app.state.limiter = limiter
    app.add_middleware(SlowAPIMiddleware)

    @app.exception_handler(RateLimitExceeded)
    async def _rate_limit_handler(request: Request, exc: RateLimitExceeded):
        return JSONResponse(status_code=429, content={"detail": "rate limit exceeded"})
except ImportError:
    logger.warning("slowapi not installed — no per-IP limit on /analyze")
    limiter = None  # type: ignore


# --- Body-size cap middleware -----------------------------------------------
class BodySizeLimitMiddleware(BaseHTTPMiddleware):
    """Reject requests whose Content-Length exceeds the configured cap.

    Streaming uploads without Content-Length are NOT capped here (rare on
    mobile); /analyze additionally counts bytes when reading the upload.
    """

    def __init__(self, app, max_bytes: int):
        super().__init__(app)
        self.max_bytes = max_bytes

    async def dispatch(self, request: Request, call_next):
        cl = request.headers.get("content-length")
        if cl is not None:
            try:
                if int(cl) > self.max_bytes:
                    return JSONResponse(status_code=413,
                                        content={"detail": f"body too large (>{self.max_bytes} bytes)"})
            except ValueError:
                pass
        return await call_next(request)


app.add_middleware(BodySizeLimitMiddleware, max_bytes=_settings.max_body_bytes)
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # local dev only — tighten in production via env
    allow_methods=["*"],
    allow_headers=["*"],
)

# --- New P0 routers ---------------------------------------------------------
app.include_router(health_routes.router)
app.include_router(projects_routes.router)
app.include_router(storage_routes.router)
app.include_router(iap_routes.router)


# --- sample library --------------------------------------------------------
DEFAULT_SAMPLES_DIR = str(Path(__file__).resolve().parent.parent / "samples")
SAMPLES_DIR = Path(os.environ.get("HUMMING_SAMPLES_DIR", DEFAULT_SAMPLES_DIR))
AUDIO_EXTENSIONS = {".m4a", ".wav", ".mp3", ".flac", ".ogg", ".aif", ".aiff"}
MEDIA_TYPE_BY_EXT = {
    ".m4a": "audio/mp4", ".mp3": "audio/mpeg", ".wav": "audio/wav",
    ".flac": "audio/flac", ".ogg": "audio/ogg",
    ".aif": "audio/aiff", ".aiff": "audio/aiff",
}


def _slugify(name: str) -> str:
    s = name.strip().replace(".", "_").replace(" ", "_")
    s = re.sub(r"[^\w가-힣]", "_", s, flags=re.UNICODE)
    s = re.sub(r"_+", "_", s).strip("_")
    return s or "sample"


def _scan_samples() -> Dict[str, Tuple[str, str]]:
    out: Dict[str, Tuple[str, str]] = {}
    if not SAMPLES_DIR.is_dir():
        return out
    seen: set[str] = set()
    for p in sorted(SAMPLES_DIR.iterdir()):
        if not p.is_file() or p.suffix.lower() not in AUDIO_EXTENSIONS:
            continue
        slug = base = _slugify(p.stem)
        n = 2
        while slug in seen:
            slug = f"{base}_{n}"; n += 1
        seen.add(slug)
        out[slug] = (p.stem, p.name)
    return out


@app.get("/samples")
def list_samples() -> List[dict]:
    out: List[dict] = []
    for slug, (label, fname) in _scan_samples().items():
        path = SAMPLES_DIR / fname
        if path.is_file():
            out.append({
                "slug": slug, "label": label, "filename": fname,
                "size_bytes": path.stat().st_size,
            })
    return out


@app.get("/samples/{slug}")
def get_sample(slug: str):
    table = _scan_samples()
    if slug not in table:
        raise HTTPException(404, f"unknown sample slug: {slug}")
    _label, fname = table[slug]
    path = SAMPLES_DIR / fname
    if not path.is_file():
        raise HTTPException(404, f"sample file missing: {path}")
    return FileResponse(
        str(path),
        media_type=MEDIA_TYPE_BY_EXT.get(path.suffix.lower(), "application/octet-stream"),
        filename=fname,
    )


# --- analysis + export ------------------------------------------------------
_analyze_decorators = []
if limiter is not None:
    _analyze_decorators.append(limiter.limit("10/minute"))


def _apply(decorators):
    def wrap(fn):
        for d in reversed(decorators):
            fn = d(fn)
        return fn
    return wrap


@app.post("/analyze", response_model=AnalyzeResponse)
@_apply(_analyze_decorators)
async def analyze(
    request: Request,
    audio: UploadFile = File(...),
    options: str | None = Form(None),
):
    raw = await audio.read()
    if not raw:
        raise HTTPException(400, "empty audio upload")
    # DEBUG: HUMMING_DEBUG_DUMP=1 이면 업로드된 WAV를 _debug_uploads/ 에 저장 →
    # 폰 실녹음을 PC에서 직접 분석(연음/청크 진단)하기 위함.
    if os.environ.get("HUMMING_DEBUG_DUMP") == "1":
        try:
            dump_dir = os.path.join(os.path.dirname(__file__), "..", "_debug_uploads")
            os.makedirs(dump_dir, exist_ok=True)
            n = len([f for f in os.listdir(dump_dir) if f.endswith(".wav")])
            with open(os.path.join(dump_dir, f"upload_{n:03d}.wav"), "wb") as fh:
                fh.write(raw)
            logger.info("debug-dumped upload_%03d.wav (%d bytes)", n, len(raw))
        except Exception:
            logger.exception("debug dump failed")
    try:
        opts = AnalyzeOptions(**json.loads(options)) if options else AnalyzeOptions()
    except Exception as e:
        raise HTTPException(400, f"invalid options json: {e}")
    try:
        return analyze_audio(raw, opts)
    except Exception as e:
        logger.exception("analyze failed")
        raise HTTPException(500, f"analyze failed: {e}")


@app.post("/process_vocal")
async def process_vocal_ep(audio: UploadFile = File(...), denoise: str = Form("1")):
    """보컬 트랙 — 악기 변환 없이 목소리 그대로. 가벼운 정리 후 정리된 WAV(base64) +
    표시용 파형 peaks + duration 반환. (믹스는 클라이언트에서 악기 믹스와 동시재생)"""
    raw = await audio.read()
    if not raw:
        raise HTTPException(400, "empty audio upload")
    try:
        wav, peaks, dur, sr = process_vocal(raw, denoise=(denoise != "0"))
    except Exception as e:
        logger.exception("process_vocal failed")
        raise HTTPException(500, f"process_vocal failed: {e}")
    return {
        "duration": dur,
        "sample_rate": sr,
        "peaks": peaks,
        "audio_b64": base64.b64encode(wav).decode("ascii"),
    }


@app.post("/assist")
async def assist(payload: dict):
    """Fast re-run of Auto Key + Pitch Assistant on already-analyzed notes.

    No audio / no pYIN — operates purely on the notes' ``pitch_raw``. Powers
    the client's key-change and assistant-toggle without a full re-analyze.
    """
    notes_raw = payload.get("notes")
    if not isinstance(notes_raw, list):
        raise HTTPException(400, "missing notes[]")
    try:
        notes = [Note(**n) for n in notes_raw]
    except Exception as e:
        raise HTTPException(400, f"invalid note: {e}")
    opts_raw = payload.get("options") or {}
    res = run_key_and_assistant(
        notes,
        bool(opts_raw.get("auto_key", True)),
        bool(opts_raw.get("pitch_assistant", True)),
        opts_raw.get("key_tonic"),
        opts_raw.get("scale"),
    )
    return {
        "notes": [n.model_dump() for n in notes],
        "detected_key": DetectedKey(
            tonic=res["tonic"], scale=res["scale"], confidence=float(res["confidence"]),
            key_tier=res["key_tier"], key_applied=res["key_applied"],
        ).model_dump(),
        "assist_applied_count": res["applied"],
        "key_candidates": res["top3"],
    }


@app.get("/render_capabilities")
def render_capabilities():
    render_mod.initialize()
    state = render_mod.get_state()
    return {
        "soundfont_available": render_mod.is_available(),
        "sf2_path": state.sf2_path,
        "error": state.error,
        "available_programs": [{"id": pid, "name": name} for pid, name in render_mod.GM_PROGRAMS],
    }


@app.post("/render_audio")
async def render_audio(payload: dict):
    """단일 트랙 notes → SoundFont 합성 WAV.

    역할 (Task 6-6, 2026-05-31): **WAV bounce / 호환 보조 전용**.
    모바일 일상 재생·단음 미리듣기는 온디바이스 SoundFont 합성
    (`SynthEngine`, `SynthPlayer`, 커밋 ``6de9bec``) 으로 이전됨.
    클라이언트의 ``EngineApi.renderAudio`` 는 ``@Deprecated`` 마킹되어
    실호출처가 없으며, 향후 제거 가능.
    """
    if not render_mod.is_available():
        state = render_mod.get_state()
        raise HTTPException(503, state.error or "SoundFont preview unavailable")
    notes_raw = payload.get("notes")
    if not isinstance(notes_raw, list):
        raise HTTPException(400, "missing notes[]")
    try:
        notes = [Note(**n) for n in notes_raw]
    except Exception as e:
        raise HTTPException(400, f"invalid note: {e}")
    program = int(payload.get("program") or 0)
    sample_rate = int(payload.get("sample_rate") or 44100)
    try:
        wav = render_mod.render_notes_to_wav(notes, program=program, sample_rate=sample_rate)
    except Exception as e:
        logger.exception("render failed")
        raise HTTPException(500, f"render failed: {e}")
    return Response(content=wav, media_type="audio/wav")


@app.post("/render_mix")
async def render_mix(payload: dict):
    """여러 트랙을 하나의 WAV로 믹스 렌더.

    역할 (Task 6-6, 2026-05-31): **WAV export / 공유 전용**.
    모바일 일상 재생은 온디바이스 ``SynthPlayer`` 가 처리하며 (커밋
    ``6de9bec``), 본 엔드포인트는 ``ProjectStore.exportMixWav()`` 의 공유
    시트 경로에서만 호출됨. 향후 export 도 온디바이스 PCM bounce 로 옮기면
    deprecate 가능.
    """
    if not render_mod.is_available():
        state = render_mod.get_state()
        raise HTTPException(503, state.error or "SoundFont preview unavailable")
    tracks_raw = payload.get("tracks")
    if not isinstance(tracks_raw, list):
        raise HTTPException(400, "missing tracks[]")
    tracks = []
    try:
        for tr in tracks_raw:
            notes = [Note(**n) for n in (tr.get("notes") or [])]
            tracks.append({"notes": notes, "program": int(tr.get("program") or 0)})
    except Exception as e:
        raise HTTPException(400, f"invalid track: {e}")
    sample_rate = int(payload.get("sample_rate") or 44100)
    try:
        wav = render_mod.render_tracks_to_wav(tracks, sample_rate=sample_rate)
    except Exception as e:
        logger.exception("render_mix failed")
        raise HTTPException(500, f"render_mix failed: {e}")
    return Response(content=wav, media_type="audio/wav")


@app.post("/export_midi")
async def export_midi(payload: dict):
    """MIDI 파일 빌드.

    두 가지 페이로드 형식을 지원 (하위호환):
    - 단일 트랙(legacy): ``{notes: [...], program: int, tempo_bpm?: float}``
    - 멀티트랙(신규):    ``{tracks: [{notes: [...], program: int, channel: int}, ...],
                            tempo_bpm?: float}``
    """
    tempo = float(payload.get("tempo_bpm") or 120.0)
    tracks_raw = payload.get("tracks")
    if isinstance(tracks_raw, list):
        tracks: list[dict] = []
        try:
            for tr in tracks_raw:
                notes = [Note(**n) for n in (tr.get("notes") or [])]
                tracks.append({
                    "notes": notes,
                    "program": int(tr.get("program") or 0),
                    "channel": int(tr.get("channel") or 0),
                })
        except Exception as e:
            raise HTTPException(400, f"invalid track: {e}")
        data = tracks_to_midi_bytes(tracks, tempo_bpm=tempo)
    else:
        notes_raw = payload.get("notes")
        if not isinstance(notes_raw, list):
            raise HTTPException(400, "missing notes[] or tracks[]")
        try:
            notes = [Note(**n) for n in notes_raw]
        except Exception as e:
            raise HTTPException(400, f"invalid note: {e}")
        program = int(payload.get("program") or 0)
        data = notes_to_midi_bytes(notes, program=program, tempo_bpm=tempo)
    return Response(
        content=data,
        media_type="audio/midi",
        headers={"Content-Disposition": 'attachment; filename="soundlab.mid"'},
    )
