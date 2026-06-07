"""ace-fusion lab — orchestrator (FastAPI, default :8200).

Glues three things together WITHOUT touching the main app/backend:
  1. existing backend (:8000) for humming→notes (/analyze, CREPE), clean
     melody re-synthesis (/render_audio), and MIDI export (/export_midi);
  2. ACE-Step (or mock) for text-prompt music generation (ace_client.py);
  3. a second /analyze(CREPE) pass to transcribe the generated audio back to notes.

The web UI (:5273) talks ONLY to this orchestrator (via its Vite /api proxy).
This server in turn calls the backend over HTTP. Nothing here imports or edits
the backend or frontend source.

Run:  uvicorn main:app --port 8200 --reload   (from labs/ace-fusion/server)
"""
from __future__ import annotations

import io
import json
import os
import re
import uuid
from pathlib import Path
from typing import Optional

import httpx
from fastapi import FastAPI, Form, HTTPException, UploadFile, File
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, Response, JSONResponse

import ace_client

BACKEND_URL = os.environ.get("HUMMING_BACKEND_URL", "http://127.0.0.1:8000")
HERE = Path(__file__).resolve().parent
SAMPLES_DIR = HERE / "samples"
OUT_DIR = (HERE.parent / "out")
OUT_DIR.mkdir(parents=True, exist_ok=True)

# friendlier labels for the 3 HumTrans picks (gender/length hints)
SAMPLE_LABELS = {
    "F03_0305_0001_2_D": "여성 보컬 · 긴 멜로디 (F03)",
    "M02_0253_0002_1": "남성 보컬 · 짧은 프레이즈 (M02)",
    "M04_0298_0001_1": "남성 보컬 · 중간 길이 (M04)",
}

app = FastAPI(title="ace-fusion lab orchestrator", version="0.1.0")
app.add_middleware(
    CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"],
)


# --- sample registry --------------------------------------------------------
def _list_sample_files() -> list[Path]:
    return sorted(p for p in SAMPLES_DIR.glob("*.wav"))


def _sample_path(sample_id: str) -> Path:
    # sample_id is the stem; reject anything with path separators
    if not re.fullmatch(r"[A-Za-z0-9_\-]+", sample_id or ""):
        raise HTTPException(400, "bad sample_id")
    p = SAMPLES_DIR / f"{sample_id}.wav"
    if not p.is_file():
        raise HTTPException(404, f"unknown sample: {sample_id}")
    return p


# --- backend helpers (httpx) ------------------------------------------------
async def _analyze(client: httpx.AsyncClient, wav: bytes, *, crepe: bool, bpm: float) -> dict:
    """Call backend /analyze. Tries CREPE first; falls back to pYIN on failure."""
    async def _call(model: str) -> httpx.Response:
        opts = {
            "pitch_model": model,
            "auto_key": True,
            "pitch_assistant": True,
            "assist_aggressive": True,
            "tempo_bpm": float(bpm),
        }
        return await client.post(
            f"{BACKEND_URL}/analyze",
            files={"audio": ("input.wav", wav, "audio/wav")},
            data={"options": json.dumps(opts)},
        )

    model = "crepe" if crepe else "pyin"
    r = await _call(model)
    if r.status_code != 200 and crepe:
        # CREPE may be unavailable (no torch/torchcrepe) — degrade to pYIN
        r = await _call("pyin")
    if r.status_code != 200:
        raise HTTPException(502, f"backend /analyze failed ({r.status_code}): {r.text[:300]}")
    return r.json()


async def _render_melody(client: httpx.AsyncClient, notes: list[dict], program: int) -> Optional[bytes]:
    """Re-synthesize notes → clean melody WAV via backend /render_audio.

    Returns None if SoundFont rendering is unavailable (503) so the caller can
    fall back to the raw humming audio.
    """
    r = await client.post(
        f"{BACKEND_URL}/render_audio",
        json={"notes": notes, "program": program, "bank": 0, "sample_rate": 44100},
    )
    if r.status_code == 503:
        return None
    if r.status_code != 200:
        raise HTTPException(502, f"backend /render_audio failed ({r.status_code}): {r.text[:200]}")
    return r.content


def _key_scale_str(detected_key: Optional[dict]) -> Optional[str]:
    if not detected_key:
        return None
    tonic, scale = detected_key.get("tonic"), detected_key.get("scale")
    if tonic and scale:
        return f"{tonic} {scale}"
    return None


def _save_out(wav: bytes, tag: str) -> str:
    name = f"{tag}_{uuid.uuid4().hex[:10]}.wav"
    (OUT_DIR / name).write_bytes(wav)
    return name


# --- routes -----------------------------------------------------------------
@app.get("/health")
async def health():
    return {"status": "ok", "service": "ace-fusion-lab"}


@app.get("/config")
async def config():
    backend_ok = False
    render_available = False
    try:
        async with httpx.AsyncClient(timeout=4.0) as c:
            h = await c.get(f"{BACKEND_URL}/health")
            backend_ok = h.status_code == 200
            rc = await c.get(f"{BACKEND_URL}/render_capabilities")
            if rc.status_code == 200:
                render_available = bool(rc.json().get("soundfont_available"))
    except Exception:
        pass
    ace_healthy = await ace_client.ace_health()
    return {
        "backend_url": BACKEND_URL,
        "backend_ok": backend_ok,
        "render_available": render_available,
        "ace_enabled": ace_client.ACE_ENABLE,
        "ace_healthy": ace_healthy,
    }


@app.get("/samples")
async def samples():
    out = []
    for p in _list_sample_files():
        out.append({
            "id": p.stem,
            "label": SAMPLE_LABELS.get(p.stem, p.stem),
            "filename": p.name,
            "size_bytes": p.stat().st_size,
        })
    return out


@app.get("/sample_audio/{sample_id}")
async def sample_audio(sample_id: str):
    return FileResponse(str(_sample_path(sample_id)), media_type="audio/wav")


@app.get("/out/{name}")
async def out_audio(name: str):
    if not re.fullmatch(r"[A-Za-z0-9_\-.]+", name) or ".." in name:
        raise HTTPException(400, "bad name")
    p = OUT_DIR / name
    if not p.is_file():
        raise HTTPException(404, "not found")
    return FileResponse(str(p), media_type="audio/wav")


@app.post("/fuse")
async def fuse(params: str = Form(...), audio: Optional[UploadFile] = File(None)):
    """Run the full hum→notes→ACE→transcribe→merge pipeline.

    Multipart form:
      - params: JSON string {sample_id?, prompt, bpm, ace_task, source_mode, lead_program?}
      - audio:  optional uploaded WAV (overrides sample_id)
    """
    try:
        p = json.loads(params)
    except Exception as e:
        raise HTTPException(400, f"bad params json: {e}")

    prompt = str(p.get("prompt") or "")
    bpm = float(p.get("bpm") or 90.0)
    ace_task = p.get("ace_task") or "cover"          # "cover" | "complete"
    source_mode = p.get("source_mode") or "resynth"  # "resynth" | "raw"
    lead_program = int(p.get("lead_program") or 73)   # 73 = GM Flute (sustained → tracks well)

    if audio is not None:
        humming = await audio.read()
        original_name = None
    else:
        sample_id = p.get("sample_id")
        if not sample_id:
            raise HTTPException(400, "need sample_id or uploaded audio")
        humming = _sample_path(sample_id).read_bytes()
        original_name = sample_id
    if not humming:
        raise HTTPException(400, "empty source audio")

    async with httpx.AsyncClient(timeout=120.0) as client:
        # 1) humming → melody notes (CREPE, fallback pYIN)
        melody_res = await _analyze(client, humming, crepe=True, bpm=bpm)
        melody_notes = melody_res.get("notes", [])
        detected_key = melody_res.get("detected_key")
        duration = (melody_res.get("waveform") or {}).get("duration") or 0.0
        if not melody_notes:
            raise HTTPException(422, "no notes detected in humming")

        # 2) build the audio we feed to ACE
        used_source_mode = source_mode
        melody_wav: Optional[bytes] = None
        if source_mode == "resynth":
            melody_wav = await _render_melody(client, melody_notes, lead_program)
            if melody_wav is None:
                used_source_mode = "raw (render unavailable)"
        ace_source = melody_wav if melody_wav is not None else humming

        # 3) text-prompt generation (ACE-Step or mock)
        key_scale = _key_scale_str(detected_key)
        gen_duration = max(10, int(duration) + 2) if duration else None
        ai_wav, engine, engine_note = await ace_client.generate(
            ace_source, prompt, ace_task, bpm, key_scale, gen_duration,
        )

        # 4) generated audio → AI notes (CREPE, fallback pYIN)
        ai_res = await _analyze(client, ai_wav, crepe=True, bpm=bpm)
        ai_notes = ai_res.get("notes", [])

    # 5) persist audio for playback
    src_name = _save_out(ace_source, "melodysrc")
    ai_name = _save_out(ai_wav, "ai")

    return JSONResponse({
        "melody_notes": melody_notes,
        "ai_notes": ai_notes,
        "detected_key": detected_key,
        "duration": duration,
        "engine": engine,
        "engine_note": engine_note,
        "source_mode_used": used_source_mode,
        "original_id": original_name,
        "melody_src_url": f"/api/out/{src_name}",
        "ai_wav_url": f"/api/out/{ai_name}",
    })


@app.post("/export_midi")
async def export_midi(payload: dict):
    """Passthrough to backend /export_midi so the web only talks to :8200.

    Expects the multi-track shape: {tracks:[{notes, program, channel}], tempo_bpm}.
    Returns the .mid bytes.
    """
    async with httpx.AsyncClient(timeout=60.0) as client:
        r = await client.post(f"{BACKEND_URL}/export_midi", json=payload)
    if r.status_code != 200:
        raise HTTPException(502, f"backend /export_midi failed ({r.status_code}): {r.text[:200]}")
    return Response(
        content=r.content,
        media_type="audio/midi",
        headers={"Content-Disposition": 'attachment; filename="ace_fusion.mid"'},
    )
