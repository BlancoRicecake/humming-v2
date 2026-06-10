"""ACE-Step adapter for the ace-fusion lab.

Pluggable music-generation backend. Two engines behind one ``generate`` call:

- ``AceStepGen`` — talks to a locally-running ACE-Step 1.5 REST server
  (``acestep-api``, default :8001). Submits a ``cover``/``complete`` task that
  conditions on the supplied source audio (our clean re-synthesized melody),
  polls for completion, downloads the resulting WAV.
- ``MockGen`` — pure-numpy fallback that fabricates a "fuller" track from the
  source audio (melody + soft kick pulse + low pad). Used whenever ACE-Step is
  not enabled / not reachable so the whole lab pipeline still runs end-to-end.

The lab NEVER hard-depends on ACE-Step. ``generate`` returns ``(wav_bytes,
engine)`` where ``engine`` is ``"acestep"`` or ``"mock"`` so the UI can label it.

NOTE on the ACE-Step request shape: the exact field names for source-audio
conditioning vary between ACE-Step builds. The mapping below follows the public
API docs (task enum: text2music/cover/repaint/lego/extract/complete; fields
prompt/bpm/key_scale/audio_duration/thinking/audio_format). If your installed
build differs, adjust ``_build_task_body`` / ``_submit`` only — nothing else in
the lab needs to change. ``thinking`` is forced False to dodge the LLM-VRAM
retention OOM (issue #198) on small GPUs.
"""
from __future__ import annotations

import io
import os
import json
import asyncio
from typing import Optional, Tuple

import numpy as np
import soundfile as sf

try:  # httpx is only needed for the real ACE path
    import httpx
except Exception:  # pragma: no cover
    httpx = None  # type: ignore


ACE_BASE_URL = os.environ.get("ACE_BASE_URL", "http://127.0.0.1:8001")
# "auto" = use ACE-Step when its /health responds, else mock.
# "1"/"on" = force ACE (error surfaces as mock fallback if unreachable).
# "0"/"off" = always mock.
ACE_ENABLE = os.environ.get("ACE_ENABLE", "auto").lower()
ACE_TIMEOUT = float(os.environ.get("ACE_TIMEOUT", "600"))  # seconds, whole gen


# --- audio helpers ----------------------------------------------------------
def _load_mono(wav_bytes: bytes) -> Tuple[np.ndarray, int]:
    y, sr = sf.read(io.BytesIO(wav_bytes), dtype="float32", always_2d=True)
    mono = y.mean(axis=1)
    return mono, int(sr)


def _to_wav_bytes(y: np.ndarray, sr: int) -> bytes:
    buf = io.BytesIO()
    peak = float(np.max(np.abs(y))) or 1.0
    sf.write(buf, (y / peak * 0.97).astype(np.float32), sr, format="WAV", subtype="PCM_16")
    return buf.getvalue()


def _rms_env(y: np.ndarray, sr: int, win_sec: float = 0.03) -> np.ndarray:
    win = max(1, int(sr * win_sec))
    pad = np.pad(np.abs(y), (win, win), mode="edge")
    kernel = np.ones(win) / win
    env = np.convolve(pad, kernel, mode="same")[win:-win]
    m = float(env.max()) or 1.0
    return env / m


# --- Mock engine ------------------------------------------------------------
def mock_generate(source_wav: bytes, prompt: str, bpm: float, duration: Optional[float]) -> bytes:
    """Fabricate a 'fuller' track from the source melody (no ML).

    Keeps the melody dominant (so downstream CREPE transcription still recovers a
    sensible line) while layering a soft kick pulse at the BPM and a quiet low
    pad gated by the melody envelope. Purely illustrative of the pipeline.
    """
    y, sr = _load_mono(source_wav)
    if duration and duration > 0:
        want = int(duration * sr)
        y = y[:want] if len(y) > want else np.pad(y, (0, want - len(y)))
    n = len(y)
    t = np.arange(n) / sr
    env = _rms_env(y, sr)

    # melody, normalized and kept up front
    peak = float(np.max(np.abs(y))) or 1.0
    melody = (y / peak) * 0.80

    # soft kick on each beat
    beat = max(0.2, 60.0 / max(bpm, 1.0))
    kick = np.zeros(n)
    klen = int(0.09 * sr)
    kdecay = np.exp(-np.linspace(0, 6, klen))
    kt = np.arange(klen) / sr
    ktone = np.sin(2 * np.pi * 55.0 * kt) * kdecay * 0.35
    pos = 0.0
    while pos < (n / sr):
        i = int(pos * sr)
        end = min(i + klen, n)
        kick[i:end] += ktone[: end - i]
        pos += beat

    # quiet low pad following the melody envelope (fixed low root, mock only)
    pad = 0.10 * np.sin(2 * np.pi * 110.0 * t) * env
    pad += 0.06 * np.sin(2 * np.pi * 164.81 * t) * env  # a fifth, very quiet

    mix = melody + kick + pad
    return _to_wav_bytes(mix.astype(np.float32), sr)


# --- ACE-Step engine --------------------------------------------------------
# Request shape verified against ACE-Step 1.5 docs/en/API.md:
#  - POST /release_task is multipart/form-data: form fields + an uploaded
#    `src_audio` file (cover/repaint/complete condition on source audio).
#  - task selector field is `task_type` (cover/complete/repaint/...).
#  - cover/repaint/extract auto-skip the LM regardless of `thinking`; we still
#    send thinking=false. On <=4GB the LM is disabled entirely (Tier 1).
#  - POST /query_result takes {"task_id_list": [id]}; each item's `result` is a
#    JSON *string* → [{"file": "/v1/audio?path=...", "status": 1, ...}].
_VALID_TASKS = {"cover", "complete", "repaint", "text2music", "lego", "extract"}


def _build_form(prompt: str, task: str, bpm: float, key_scale: Optional[str],
                duration: Optional[float]) -> dict:
    form: dict = {
        "task_type": task if task in _VALID_TASKS else "cover",
        "prompt": prompt or "warm instrumental backing",
        "audio_format": "wav",
        "thinking": "false",
    }
    if bpm:
        form["bpm"] = str(int(bpm))
    if duration:
        form["audio_duration"] = str(int(duration))
    if key_scale:
        form["key_scale"] = key_scale
    return form


async def ace_health(base_url: str = ACE_BASE_URL) -> bool:
    """True only if a real ACE-Step server answers.

    Probes ``/v1/models`` (ACE-specific) rather than ``/health`` — the Humming
    backend also answers ``/health`` and could squat :8001, so a generic health
    check gives false positives.
    """
    if httpx is None:
        return False
    try:
        async with httpx.AsyncClient(timeout=3.0) as c:
            r = await c.get(f"{base_url}/v1/models")
            return r.status_code == 200
    except Exception:
        return False


async def ace_generate(source_wav: bytes, prompt: str, task: str, bpm: float,
                       key_scale: Optional[str], duration: Optional[float],
                       base_url: str = ACE_BASE_URL) -> bytes:
    """Submit a cover/complete task and return the generated WAV bytes.

    Raises on any failure so the caller can fall back to the mock engine.
    """
    if httpx is None:
        raise RuntimeError("httpx not installed")
    form = _build_form(prompt, task, bpm, key_scale, duration)
    files = {"src_audio": ("melody.wav", source_wav, "audio/wav")}
    async with httpx.AsyncClient(timeout=ACE_TIMEOUT) as c:
        sub = await c.post(f"{base_url}/release_task", data=form, files=files)
        sub.raise_for_status()
        j = sub.json()
        data = j.get("data") if isinstance(j, dict) else None
        task_id = None
        for src in (data, j):
            if isinstance(src, dict):
                task_id = src.get("task_id") or src.get("id")
                if task_id:
                    break
        if not task_id:
            raise RuntimeError(f"no task_id in ACE response: {sub.text[:200]}")

        # poll /query_result until the task item reports success
        waited = 0.0
        while waited < ACE_TIMEOUT:
            await asyncio.sleep(3.0)
            waited += 3.0
            q = await c.post(f"{base_url}/query_result", json={"task_id_list": [task_id]})
            q.raise_for_status()
            items = (q.json().get("data") or []) if isinstance(q.json(), dict) else []
            if not items:
                continue
            item = items[0]
            status = item.get("status")
            if status in (2, "2"):
                raise RuntimeError(f"ACE task failed: {str(item)[:200]}")
            if status in (1, "1"):
                raw = item.get("result")
                recs = json.loads(raw) if isinstance(raw, str) else raw
                rec = recs[0] if isinstance(recs, list) and recs else recs
                file_url = rec.get("file") if isinstance(rec, dict) else None
                if not file_url:
                    raise RuntimeError("ACE success but no file URL")
                # `file` is already a relative URL like "/v1/audio?path=..."
                audio = await c.get(f"{base_url}{file_url}")
                audio.raise_for_status()
                return audio.content
        raise TimeoutError("ACE generation timed out")


# --- public entry -----------------------------------------------------------
async def generate(source_wav: bytes, prompt: str, task: str, bpm: float,
                   key_scale: Optional[str], duration: Optional[float]) -> Tuple[bytes, str, Optional[str]]:
    """Return (wav_bytes, engine, note). ``note`` carries a fallback reason."""
    use_ace = ACE_ENABLE in ("1", "on", "true", "auto")
    if use_ace:
        healthy = await ace_health()
        if healthy or ACE_ENABLE in ("1", "on", "true"):
            try:
                wav = await ace_generate(source_wav, prompt, task, bpm, key_scale, duration)
                return wav, "acestep", None
            except Exception as e:  # graceful fallback to mock
                return mock_generate(source_wav, prompt, bpm, duration), "mock", f"ACE-Step error → mock: {e}"
        # not healthy + auto
        return mock_generate(source_wav, prompt, bpm, duration), "mock", "ACE-Step not reachable (auto → mock)"
    return mock_generate(source_wav, prompt, bpm, duration), "mock", "ACE disabled (ACE_ENABLE=off)"
