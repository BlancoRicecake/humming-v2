"""SoundLab — minimal FastAPI surface.

Endpoints (one per pipeline boundary):
- GET  /health               — liveness
- GET  /samples              — auto-discovered audio files in the samples dir
- GET  /samples/{slug}       — serve a sample file by slug
- POST /analyze              — Stage 2-7 (returns notes + debug data)
- POST /export_midi          — Stage 9 (writes a .mid via mido)
"""
from __future__ import annotations

import asyncio
import base64
import contextlib
import functools
import json
import logging
import math
import os
import re
from pathlib import Path
from typing import Dict, List, Tuple

import anyio
from fastapi import FastAPI, File, Form, HTTPException, Request, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, JSONResponse, Response

from .analyze import analyze_audio, process_vocal
from . import soundfonts as soundfonts_mod
from . import audition_palette as audition_palette_mod
from . import guitar_lab as guitar_lab_mod
from .assistant import run_key_and_assistant
from .midi_build import notes_to_midi_bytes, tracks_to_midi_bytes
from . import render as render_mod
from .schemas import AnalyzeOptions, AnalyzeResponse, DetectedKey, Note
from .settings import get_settings
from .routes import projects as projects_routes
from .routes import storage as storage_routes
from .routes import iap as iap_routes
from .routes import health as health_routes
from .routes import account as account_routes

logger = logging.getLogger("soundlab")
logging.basicConfig(level=logging.INFO)

_settings = get_settings()

# --- Sentry (optional) ------------------------------------------------------
if _settings.sentry_dsn:
    try:
        import sentry_sdk
        from sentry_sdk.integrations.fastapi import FastApiIntegration
        from sentry_sdk.integrations.starlette import StarletteIntegration
        def _traces_sampler(sampling_context):
            # /health is hit every few seconds by Fly's internal health checker
            # (private 172.x source). Tracing it wastes quota AND on *sampled*
            # requests the Sentry transaction instrumentation + SlowAPIMiddleware's
            # per-request anyio task groups nest deep enough to trip a
            # RecursionError (same mechanism as the BodySizeLimitMiddleware note
            # below; middleware_spans=False alone wasn't enough). Never sample it.
            scope = sampling_context.get("asgi_scope") or {}
            if str(scope.get("path", "")).startswith("/health"):
                return 0.0
            return _settings.sentry_traces_sample_rate

        sentry_sdk.init(
            dsn=_settings.sentry_dsn,
            environment=_settings.environment,
            # traces_sampler (takes precedence over traces_sample_rate) so we can
            # exclude /health — see _traces_sampler.
            traces_sampler=_traces_sampler,
            # middleware_spans=False: Sentry's per-middleware span instrumentation
            # wraps every BaseHTTPMiddleware.__call__ (plus the receive/send
            # callbacks) on *sampled* requests, multiplying stack frames per
            # middleware layer. Combined with the per-request task groups that
            # BaseHTTPMiddleware spins up, deep enough nesting tripped a
            # RecursionError on sampled requests (seen intermittently even on
            # /health). We don't rely on middleware spans — turn them off.
            integrations=[
                FastApiIntegration(),
                StarletteIntegration(middleware_spans=False),
            ],
            send_default_pii=False,
        )
        logger.info("Sentry initialised env=%s", _settings.environment)
    except ImportError:
        logger.warning("SENTRY_DSN set but sentry-sdk not installed")

# --- Startup: learned-model availability log (B9) ---------------------------
def _learned_model_status() -> Dict[str, bool]:
    """Cheap startup probe: does each learned-correction .npz exist AND load?

    Production once shipped without ``models/`` in the image and silently ran
    the heuristic fallbacks; this makes that state loud in the boot log.
    """
    from . import drum_classifier, offset_correction, pitch_correction

    probes = (
        ("pitch_correction", (pitch_correction.MODEL_PATH,), pitch_correction._load_model),
        ("offset_correction", (offset_correction.MODEL_PATH,), offset_correction._load_model),
        ("drum_classifier", tuple(drum_classifier.MODEL_PATHS), drum_classifier._load),
    )
    status: Dict[str, bool] = {}
    for name, paths, loader in probes:
        present = [str(p) for p in paths if Path(p).is_file()]
        loaded = False
        if present:
            try:
                loaded = loader() is not None
            except Exception:
                logger.exception("learned model %s: load raised", name)
        if loaded:
            logger.info("learned model %s: loaded (%s)", name, present[0])
        else:
            logger.warning(
                "learned model %s: MISSING or failed to load — analysis runs on heuristics only "
                "(looked in %s)", name, [str(p) for p in paths],
            )
        status[name] = loaded
    return status


@contextlib.asynccontextmanager
async def _lifespan(_app: FastAPI):
    try:
        _learned_model_status()
    except Exception:
        logger.exception("learned model status probe failed")
    yield


app = FastAPI(title="Humming V2 backend", version="0.3.0", lifespan=_lifespan)


def _client_ip(request: Request) -> str:
    """Rate-limit key (B15).

    uvicorn runs with ``--forwarded-allow-ips '*'`` so ``request.client.host``
    (what slowapi's ``get_remote_address`` returns) is the *leftmost*
    X-Forwarded-For entry — which the client controls. Prefer the header the
    edge proxy itself stamps (Fly: ``fly-client-ip``; Cloudflare:
    ``cf-connecting-ip``) and only then fall back to the socket/forwarded peer.
    """
    for h in ("fly-client-ip", "cf-connecting-ip"):
        v = request.headers.get(h)
        if v:
            return v.strip()
    return request.client.host if request.client else "127.0.0.1"


# --- Rate limit (slowapi) ---------------------------------------------------
try:
    from slowapi import Limiter
    from slowapi.errors import RateLimitExceeded
    from slowapi.middleware import SlowAPIMiddleware

    limiter = Limiter(key_func=_client_ip, default_limits=[])
    app.state.limiter = limiter
    app.add_middleware(SlowAPIMiddleware)

    @app.exception_handler(RateLimitExceeded)
    async def _rate_limit_handler(request: Request, exc: RateLimitExceeded):
        return JSONResponse(status_code=429, content={"detail": "rate limit exceeded"})
except ImportError:
    logger.warning("slowapi not installed — no per-IP limit on /analyze")
    limiter = None  # type: ignore


# --- Body-size cap middleware -----------------------------------------------
class BodySizeLimitMiddleware:
    """Reject requests whose Content-Length exceeds the configured cap.

    Implemented as a *pure ASGI* middleware (not BaseHTTPMiddleware) on purpose:
    BaseHTTPMiddleware spins up a per-request anyio task group and, under
    Sentry's middleware-span instrumentation, deep enough nesting tripped a
    RecursionError on sampled requests. A Content-Length check needs none of
    that machinery, so we keep the middleware stack shallow.

    Streaming uploads without Content-Length are NOT capped here (rare on
    mobile); the upload endpoints additionally count bytes while reading the
    upload (see _read_upload_capped).
    """

    def __init__(self, app, max_bytes: int):
        self.app = app
        self.max_bytes = max_bytes

    async def __call__(self, scope, receive, send):
        if scope["type"] == "http":
            cl = next((v for k, v in scope.get("headers", []) if k.lower() == b"content-length"), None)
            if cl is not None:
                try:
                    if int(cl) > self.max_bytes:
                        response = JSONResponse(
                            status_code=413,
                            content={"detail": f"body too large (>{self.max_bytes} bytes)"},
                        )
                        await response(scope, receive, send)
                        return
                except ValueError:
                    pass
        await self.app(scope, receive, send)


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
app.include_router(account_routes.router)


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


# --- runtime soundfont catalog ----------------------------------------------
# Instruments the app downloads on demand (no app release to add a sound). See
# app/soundfonts.py for the catalog.json schema + the add-a-sound recipe.
@app.get("/soundfonts")
def list_soundfonts() -> List[dict]:
    return soundfonts_mod.load_catalog()


@app.get("/soundfonts/{entry_id}")
def get_soundfont(entry_id: str):
    path = soundfonts_mod.entry_file(entry_id)
    if path is None:
        raise HTTPException(404, f"unknown soundfont: {entry_id}")
    return FileResponse(
        str(path),
        media_type="audio/x-soundfont",
        filename=path.name,
    )


# --- analysis + export ------------------------------------------------------
async def _read_upload_capped(upload: UploadFile, max_bytes: int) -> bytes:
    """Read an UploadFile in chunks, raising 413 once more than ``max_bytes``
    have been received (B16). Chunked uploads carry no Content-Length, so
    BodySizeLimitMiddleware can't cap them — this is the backstop.
    """
    chunks: list[bytes] = []
    total = 0
    while True:
        chunk = await upload.read(256 * 1024)
        if not chunk:
            break
        total += len(chunk)
        if total > max_bytes:
            raise HTTPException(413, f"body too large (>{max_bytes} bytes)")
        chunks.append(chunk)
    return b"".join(chunks)


# Cap concurrent CPU-bound DSP jobs (/analyze, /process_vocal, /process_fx,
# /autotune). Each runs off the event loop via anyio.to_thread so /health (Fly
# check, 3 s timeout) stays responsive during multi-second analysis (B8); the
# semaphore bounds peak RAM on the 1 GB VM (WORLD jobs peak ~200 MB float64).
_dsp_sem = asyncio.Semaphore(2)
_autotune_sem = _dsp_sem  # legacy name
# FluidSynth renders load a whole SF2 into the throwaway synth (GeneralUser GS
# ~30 MB; catalog fonts up to hundreds of MB) — never run two at once.
_render_sem = asyncio.Semaphore(1)

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
    raw = await _read_upload_capped(audio, _settings.max_body_bytes)
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
        async with _dsp_sem:
            return await anyio.to_thread.run_sync(functools.partial(analyze_audio, raw, opts))
    except HTTPException:  # undecodable input etc. are already 4xx — don't mask as 500
        raise
    except Exception:
        logger.exception("analyze failed")
        raise HTTPException(500, "analyze failed")


@app.post("/process_vocal")
async def process_vocal_ep(audio: UploadFile = File(...), denoise: str = Form("1")):
    """보컬 트랙 — 악기 변환 없이 목소리 그대로. 가벼운 정리 후 정리된 WAV(base64) +
    표시용 파형 peaks + duration 반환. (믹스는 클라이언트에서 악기 믹스와 동시재생)"""
    raw = await _read_upload_capped(audio, _settings.max_body_bytes)
    if not raw:
        raise HTTPException(400, "empty audio upload")
    try:
        async with _dsp_sem:
            wav, peaks, dur, sr = await anyio.to_thread.run_sync(
                functools.partial(process_vocal, raw, denoise=(denoise != "0")))
    except HTTPException:  # undecodable input is already 4xx — don't mask as 500
        raise
    except Exception:
        logger.exception("process_vocal failed")
        raise HTTPException(500, "process_vocal failed")
    return {
        "duration": dur,
        "sample_rate": sr,
        "peaks": peaks,
        "audio_b64": base64.b64encode(wav).decode("ascii"),
    }


@app.post("/process_fx")
async def process_fx_ep(
    audio: UploadFile = File(...),
    fx_type: str = Form(...),
    params: str = Form("{}"),
):
    """보컬 사운드 가공 — eq/reverb/comp/delay/stretch/pitch 중 하나를 적용.
    [params]는 이펙트별 파라미터 JSON. 반환 형식은 /process_vocal·/autotune 과
    동일: 가공된 WAV(base64) + 표시용 peaks + duration. (CPU 작업은 WORLD 잡과
    같은 세마포어로 직렬화해 메모리 폭주를 막는다.)"""
    from .fx import apply_fx

    raw = await _read_upload_capped(audio, _settings.max_body_bytes)
    if not raw:
        raise HTTPException(400, "empty audio upload")
    try:
        p = json.loads(params or "{}")
        if not isinstance(p, dict):
            raise ValueError("params must be a JSON object")
    except (ValueError, json.JSONDecodeError) as e:
        raise HTTPException(400, f"invalid params: {e}")
    try:
        async with _dsp_sem:
            wav, peaks, dur, sr = await anyio.to_thread.run_sync(
                functools.partial(apply_fx, raw, fx_type, p))
    except HTTPException:  # decode failures are already 4xx — don't mask as 500
        raise
    except ValueError as e:  # unknown fx_type / empty audio
        raise HTTPException(400, str(e))
    except Exception:
        logger.exception("process_fx failed")
        raise HTTPException(500, "process_fx failed")
    return {
        "duration": dur,
        "sample_rate": sr,
        "peaks": peaks,
        "audio_b64": base64.b64encode(wav).decode("ascii"),
    }


@app.post("/autotune")
@_apply(_analyze_decorators)
async def autotune_ep(
    request: Request,
    audio: UploadFile = File(...),
    key: str = Form(...),
    scale: str = Form(...),
    strength: str = Form("1.0"),
    retune_ms: str = Form("80"),
    denoise: str = Form("1"),
):
    """보컬 오토튠 — WORLD 보코더로 곡의 키/스케일에 피치 보정 (포먼트 보존).
    strength 0..1 (보정 강도), retune_ms (보정 속도 시정수). 반환 형식은
    /process_vocal 과 동일: 보정된 WAV(base64) + 표시용 peaks + duration."""
    from .autotune import autotune_vocal

    raw = await _read_upload_capped(audio, _settings.max_body_bytes)
    if not raw:
        raise HTTPException(400, "empty audio upload")
    try:
        s = min(max(float(strength), 0.0), 1.0)
        r = min(max(float(retune_ms), 1.0), 1000.0)
    except ValueError:
        raise HTTPException(400, "invalid strength/retune_ms")
    if not math.isfinite(s) or not math.isfinite(r):  # NaN survives min/max clamping
        raise HTTPException(400, "invalid strength/retune_ms")
    try:
        async with _dsp_sem:
            wav, peaks, dur, sr = await anyio.to_thread.run_sync(functools.partial(
                autotune_vocal, raw, key, scale,
                strength=s, retune_ms=r, denoise=(denoise != "0")))
    except HTTPException:  # decode failures are already 4xx — don't mask as 500
        raise
    except ValueError as e:  # unknown tonic/scale, over-long input
        raise HTTPException(400, str(e))
    except Exception:
        logger.exception("autotune failed")
        raise HTTPException(500, "autotune failed")
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
        assist_aggressive=bool(opts_raw.get("assist_aggressive", True)),
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


def _render_sample_rate(payload: dict) -> int:
    """Whitelist ``sample_rate`` (B17) → 400 on anything but 22050/44100/48000."""
    try:
        return render_mod.validate_sample_rate(payload.get("sample_rate") or 44100)
    except ValueError as e:
        raise HTTPException(400, str(e))


def _check_render_notes(notes) -> None:
    """Note-count / timeline-length budget (B17) → 400 on violation."""
    try:
        render_mod.validate_notes(notes)
    except ValueError as e:
        raise HTTPException(400, str(e))


def _require_render_available() -> None:
    if not render_mod.is_available():
        raise HTTPException(503, render_mod.get_state().error or "SoundFont preview unavailable")


def _require_render_engine() -> None:
    if not render_mod.is_engine_available():
        raise HTTPException(503, render_mod.get_state().error or "SoundFont engine unavailable")


async def _run_render(fn, *args, **kwargs) -> bytes:
    """Run a FluidSynth render off the event loop, one at a time (see _render_sem)."""
    async with _render_sem:
        return await anyio.to_thread.run_sync(functools.partial(fn, *args, **kwargs))


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


@app.get("/soundfont_presets")
def soundfont_presets():
    """Every preset present in the loaded SF2 (for the 'audition all' button)."""
    if not render_mod.is_available():
        state = render_mod.get_state()
        raise HTTPException(503, state.error or "SoundFont preview unavailable")
    return {"presets": render_mod.list_presets()}


@app.post("/render_demo")
async def render_demo(payload: dict):
    """Render the fixed audition phrase through one SF2 preset → WAV."""
    sample_rate = _render_sample_rate(payload)
    bank = int(payload.get("bank") or 0)
    program = int(payload.get("program") or 0)
    _require_render_available()
    try:
        wav = await _run_render(render_mod.render_demo_to_wav, bank, program, sample_rate=sample_rate)
    except ValueError as e:
        raise HTTPException(400, str(e))
    except Exception:
        logger.exception("render_demo failed")
        raise HTTPException(500, "render_demo failed")
    return Response(content=wav, media_type="audio/wav")


# --- sound picker (Space B): per-track-type audition ------------------------
@app.get("/audition_palette")
def audition_palette(role: str):
    """Ordered, categorized audition items for a track type (melody|bass|drums).

    Unifies GM programs, downloaded catalog soundfonts, and the 808/hip-hop
    sentinels. See app/audition_palette.py for the item shape.
    """
    if role not in audition_palette_mod.ROLES:
        raise HTTPException(400, "role must be melody|bass|drums")
    if not render_mod.is_engine_available():
        raise HTTPException(503, render_mod.get_state().error or "SoundFont engine unavailable")
    return {"role": role, "items": audition_palette_mod.build_palette(role)}


def _resolve_audition_source(source: str, payload: dict) -> Tuple[str, int, int]:
    """(sf2_path, sf_bank, sf_program) for an audition render request.

    Raises ValueError on a bad request shape and KeyError on an unknown id /
    missing file (mapped to 400 / 404 by the endpoint).
    """
    if source == "gm":
        return (render_mod.get_state().sf2_path,
                int(payload.get("bank") or 0), int(payload.get("program") or 0))
    if source == "catalog":
        sid = str(payload.get("soundfont_id") or "")
        path = soundfonts_mod.entry_file(sid)
        if path is None:
            raise KeyError(f"unknown soundfont: {sid}")
        entry = next((e for e in soundfonts_mod.load_catalog() if e["id"] == sid), None)
        if entry is None:
            raise KeyError(f"unknown soundfont: {sid}")
        return (str(path), int(entry.get("sf_bank", 0)), int(entry.get("sf_program", 0)))
    if source == "sentinel":
        sid = str(payload.get("sentinel_id") or "")
        path = audition_palette_mod.sentinel_sf2_path(sid)
        meta = audition_palette_mod.SENTINELS.get(sid)
        if path is None or meta is None:
            raise KeyError(f"unknown or missing sentinel: {sid}")
        return (str(path), int(meta["sf_bank"]), int(meta["sf_program"]))
    raise ValueError(f"unknown source: {source}")


@app.post("/audition_render")
async def audition_render(payload: dict):
    """Render the per-track-type audition phrase through a GM / catalog /
    sentinel sound → WAV. The sound is selected by ``source``; see
    _resolve_audition_source."""
    sample_rate = _render_sample_rate(payload)
    source = str(payload.get("source") or "gm")
    track_type = str(payload.get("track_type") or "melody")
    piece = payload.get("piece")
    if track_type not in audition_palette_mod.ROLES:
        raise HTTPException(400, "track_type must be melody|bass|drums")
    if piece is not None and piece not in ("kick", "snare", "hat"):
        raise HTTPException(400, "piece must be kick|snare|hat")
    _require_render_engine()
    try:
        sf2_path, sf_bank, sf_program = _resolve_audition_source(source, payload)
    except KeyError as e:
        raise HTTPException(404, str(e))
    except ValueError as e:
        raise HTTPException(400, str(e))
    if not sf2_path:
        raise HTTPException(503, "global SoundFont unavailable")
    try:
        wav = await _run_render(
            render_mod.render_demo_through_sf2,
            sf2_path, sf_bank, sf_program, track_type=track_type,
            sample_rate=sample_rate, piece=piece)
    except FileNotFoundError:
        raise HTTPException(404, "soundfont file missing")
    except ValueError as e:
        raise HTTPException(400, str(e))
    except Exception:
        logger.exception("audition_render failed")
        raise HTTPException(500, "audition_render failed")
    return Response(content=wav, media_type="audio/wav")


# --- guitar lab (기타 연구소): strummed-guitar audition ----------------------
@app.get("/guitar_lab_sounds")
def guitar_lab_sounds():
    """Guitar sounds available in the lab: GM programs 24-31 + catalog fonts."""
    if not render_mod.is_engine_available():
        raise HTTPException(503, render_mod.get_state().error or "SoundFont engine unavailable")
    return {"items": guitar_lab_mod.list_guitar_sounds()}


@app.post("/guitar_lab_render")
async def guitar_lab_render(payload: dict):
    """Render a strummed guitar chord with the lab's articulation params → WAV.

    Body: ``{source, bank/program | soundfont_id, ...articulation params}``.
    Articulation params (all optional, see guitar_lab.DEFAULT_PARAMS): root,
    voicing, strum_ms, direction, velocity, velocity_falloff, velocity_jitter,
    timing_jitter_ms, ring_ms, palm_mute, let_ring, pattern, bpm, repeats, reverb.
    """
    sample_rate = _render_sample_rate(payload)
    source = str(payload.get("source") or "gm")
    seed = payload.get("seed")
    keys = (
        "root", "voicing", "strum_ms", "direction", "velocity", "velocity_falloff",
        "velocity_jitter", "timing_jitter_ms", "ring_ms", "palm_mute", "let_ring",
        "pattern", "bpm", "repeats", "reverb",
    )
    art = {k: payload[k] for k in keys if k in payload}
    # Bound rendered length (B17): strokes = len(pattern) * repeats at 60/bpm/2 s each.
    try:
        repeats = int(art.get("repeats") or 1)
        bpm = float(art.get("bpm") or 96.0)
    except (TypeError, ValueError):
        raise HTTPException(400, "invalid repeats/bpm")
    if not (1 <= repeats <= 64) or not math.isfinite(bpm) or not (20.0 <= bpm <= 400.0):
        raise HTTPException(400, "repeats must be 1..64 and bpm 20..400")
    if len(str(art.get("pattern") or "")) > 256:
        raise HTTPException(400, "pattern too long (max 256 strokes)")
    _require_render_engine()
    # reuse the sound-picker source resolution (gm / catalog / sentinel -> sf2)
    try:
        sf2_path, sf_bank, sf_program = _resolve_audition_source(source, payload)
    except KeyError as e:
        raise HTTPException(404, str(e))
    except ValueError as e:
        raise HTTPException(400, str(e))
    if not sf2_path:
        raise HTTPException(503, "global SoundFont unavailable")
    try:
        wav = await _run_render(
            guitar_lab_mod.render_guitar_strum,
            sf2_path, sf_bank, sf_program,
            sample_rate=sample_rate,
            seed=int(seed) if seed is not None else None,
            **art,
        )
    except FileNotFoundError:
        raise HTTPException(404, "soundfont file missing")
    except ValueError as e:
        raise HTTPException(400, str(e))
    except Exception:
        logger.exception("guitar_lab_render failed")
        raise HTTPException(500, "guitar_lab_render failed")
    return Response(content=wav, media_type="audio/wav")


@app.post("/render_audio")
async def render_audio(payload: dict):
    """단일 트랙 notes → SoundFont 합성 WAV.

    역할 (Task 6-6, 2026-05-31): **WAV bounce / 호환 보조 전용**.
    모바일 일상 재생·단음 미리듣기는 온디바이스 SoundFont 합성
    (`SynthEngine`, `SynthPlayer`, 커밋 ``6de9bec``) 으로 이전됨.
    클라이언트의 ``EngineApi.renderAudio`` 는 ``@Deprecated`` 마킹되어
    실호출처가 없으며, 향후 제거 가능.
    """
    sample_rate = _render_sample_rate(payload)
    notes_raw = payload.get("notes")
    if not isinstance(notes_raw, list):
        raise HTTPException(400, "missing notes[]")
    if len(notes_raw) > render_mod.MAX_RENDER_NOTES:
        raise HTTPException(400, f"too many notes ({len(notes_raw)} > {render_mod.MAX_RENDER_NOTES})")
    try:
        notes = [Note(**n) for n in notes_raw]
    except Exception as e:
        raise HTTPException(400, f"invalid note: {e}")
    _check_render_notes(notes)
    program = int(payload.get("program") or 0)
    bank = int(payload.get("bank") or 0)
    _require_render_available()
    try:
        wav = await _run_render(
            render_mod.render_notes_to_wav, notes, program=program, sample_rate=sample_rate, bank=bank)
    except ValueError as e:
        raise HTTPException(400, str(e))
    except Exception:
        logger.exception("render failed")
        raise HTTPException(500, "render failed")
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
    sample_rate = _render_sample_rate(payload)
    tracks_raw = payload.get("tracks")
    if not isinstance(tracks_raw, list):
        raise HTTPException(400, "missing tracks[]")
    total_raw = sum(len(tr.get("notes") or []) for tr in tracks_raw if isinstance(tr, dict))
    if total_raw > render_mod.MAX_RENDER_NOTES:
        raise HTTPException(400, f"too many notes ({total_raw} > {render_mod.MAX_RENDER_NOTES})")
    tracks = []
    try:
        for tr in tracks_raw:
            notes = [Note(**n) for n in (tr.get("notes") or [])]
            tracks.append({"notes": notes, "program": int(tr.get("program") or 0)})
    except Exception as e:
        raise HTTPException(400, f"invalid track: {e}")
    _check_render_notes([n for tr in tracks for n in tr["notes"]])
    _require_render_available()
    try:
        wav = await _run_render(render_mod.render_tracks_to_wav, tracks, sample_rate=sample_rate)
    except ValueError as e:
        raise HTTPException(400, str(e))
    except Exception:
        logger.exception("render_mix failed")
        raise HTTPException(500, "render_mix failed")
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
        bank = int(payload.get("bank") or 0)
        data = notes_to_midi_bytes(notes, program=program, tempo_bpm=tempo, bank=bank)
    return Response(
        content=data,
        media_type="audio/midi",
        headers={"Content-Disposition": 'attachment; filename="soundlab.mid"'},
    )
