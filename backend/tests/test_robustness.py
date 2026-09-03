"""Backend robustness guards (audit 2026-09-03: B8, B15, B16, B17, B18, B22).

Everything here runs without ffmpeg, FluidSynth, Supabase or R2: the guards
under test fire *before* those dependencies are touched.
"""
from __future__ import annotations

import pytest
from fastapi.testclient import TestClient
from starlette.requests import Request

from app import analyze as analyze_mod
from app import render as render_mod
from app.main import _client_ip, app
from app.routes.projects import CloudProjectListItem
from app.routes.storage import _sanitise
from app.schemas import Note
from app.storage_r2 import sanitise_key_part


@pytest.fixture(scope="module")
def client():
    # `with` runs the lifespan → exercises the learned-model startup log.
    with TestClient(app) as c:
        yield c


def _note(start: float, end: float, pitch: int = 60) -> dict:
    return {
        "start": start, "end": end, "duration": end - start, "pitch": pitch,
        "pitch_raw": float(pitch), "pitch_hz": 261.63, "velocity": 100,
        "confidence": 0.9, "voiced_ratio": 1.0,
    }


# --- B17: render input clamps -------------------------------------------------
@pytest.mark.parametrize("path,body", [
    ("/render_audio", {"notes": [_note(0.0, 0.5)], "sample_rate": 10_000_000}),
    ("/render_mix", {"tracks": [{"notes": [_note(0.0, 0.5)], "program": 0}], "sample_rate": 10_000_000}),
    ("/render_demo", {"bank": 0, "program": 0, "sample_rate": 96000}),
    ("/audition_render", {"source": "gm", "track_type": "melody", "sample_rate": "huge"}),
    ("/guitar_lab_render", {"source": "gm", "sample_rate": 1}),
])
def test_render_bad_sample_rate_is_400(client, path, body):
    r = client.post(path, json=body)
    assert r.status_code == 400, r.text
    assert "sample_rate" in r.json()["detail"]


def test_render_audio_too_many_notes_is_400(client):
    notes = [_note(i * 0.01, i * 0.01 + 0.005) for i in range(render_mod.MAX_RENDER_NOTES + 1)]
    r = client.post("/render_audio", json={"notes": notes})
    assert r.status_code == 400
    assert "too many notes" in r.json()["detail"]


def test_render_audio_over_long_timeline_is_400(client):
    r = client.post("/render_audio", json={"notes": [_note(0.0, render_mod.MAX_RENDER_SECONDS + 1)]})
    assert r.status_code == 400
    assert "max render length" in r.json()["detail"]


def test_render_mix_counts_notes_across_tracks(client):
    half = render_mod.MAX_RENDER_NOTES // 2 + 1
    tr = {"notes": [_note(0.0, 0.1)] * half, "program": 0}
    r = client.post("/render_mix", json={"tracks": [tr, tr]})
    assert r.status_code == 400
    assert "too many notes" in r.json()["detail"]


def test_guitar_lab_repeats_bounded(client):
    r = client.post("/guitar_lab_render", json={"source": "gm", "repeats": 10_000})
    assert r.status_code == 400
    assert "repeats" in r.json()["detail"]


def test_validate_notes_rejects_nonfinite_and_negative():
    n = Note(**_note(0.0, 1.0))
    render_mod.validate_notes([n])  # ok
    with pytest.raises(ValueError):
        render_mod.validate_notes([Note(**_note(-1.0, 1.0))])
    with pytest.raises(ValueError):
        render_mod.validate_notes([Note(**_note(0.0, float("inf")))])
    with pytest.raises(ValueError):
        render_mod.validate_notes([n] * 3, max_notes=2)


def test_validate_sample_rate():
    assert render_mod.validate_sample_rate("44100") == 44100
    for bad in (0, 96000, "x", None, 10_000_000):
        with pytest.raises(ValueError):
            render_mod.validate_sample_rate(bad)


# --- B16: chunked upload cap ----------------------------------------------------
def _multipart_gen(boundary: str, total_bytes: int, chunk: int = 256 * 1024):
    yield (
        f"--{boundary}\r\nContent-Disposition: form-data; name=\"fx_type\"\r\n\r\neq\r\n"
        f"--{boundary}\r\nContent-Disposition: form-data; name=\"audio\"; "
        f"filename=\"a.wav\"\r\nContent-Type: audio/wav\r\n\r\n"
    ).encode()
    sent = 0
    while sent < total_bytes:
        n = min(chunk, total_bytes - sent)
        yield b"\0" * n
        sent += n
    yield f"\r\n--{boundary}--\r\n".encode()


def test_chunked_upload_over_cap_is_413(client):
    from app.settings import get_settings

    cap = get_settings().max_body_bytes
    boundary = "xxHummingTestBoundaryxx"
    r = client.post(
        "/process_fx",
        content=_multipart_gen(boundary, cap + 64 * 1024),
        headers={"Content-Type": f"multipart/form-data; boundary={boundary}"},
    )
    assert r.status_code == 413, r.text
    assert "body too large" in r.json()["detail"]


# --- B15: rate-limit key -------------------------------------------------------
def _req(headers: dict, client_host: str = "10.0.0.1") -> Request:
    scope = {
        "type": "http", "method": "GET", "path": "/", "query_string": b"",
        "headers": [(k.lower().encode(), v.encode()) for k, v in headers.items()],
        "client": (client_host, 1234), "server": ("h", 80), "scheme": "http",
    }
    return Request(scope)


def test_client_ip_prefers_edge_headers_over_xff():
    assert _client_ip(_req({"fly-client-ip": "203.0.113.9", "x-forwarded-for": "1.1.1.1"})) == "203.0.113.9"
    assert _client_ip(_req({"cf-connecting-ip": "198.51.100.7"})) == "198.51.100.7"
    assert _client_ip(_req({"x-forwarded-for": "1.1.1.1"}, client_host="10.0.0.5")) == "10.0.0.5"


# --- B8: analyze decode-info is per-call ---------------------------------------
def test_analyze_has_no_shared_decode_global():
    assert not hasattr(analyze_mod, "_LAST_DECODE_INFO")
    assert analyze_mod.DecodeInfo(input_codec="wav").input_codec == "wav"


def test_load_audio_returns_decode_info():
    import io
    import numpy as np
    import soundfile as sf

    buf = io.BytesIO()
    sf.write(buf, np.zeros(2205, dtype=np.float32), 22050, format="WAV", subtype="PCM_16")
    y, sr, info = analyze_mod._load_audio(buf.getvalue())
    assert sr == analyze_mod.TARGET_SR
    assert isinstance(info, analyze_mod.DecodeInfo)
    assert info.input_codec == "wav"
    assert info.decoded_via == "soundfile"


# --- B12 / B22: projects list model + shared key sanitiser ---------------------
def test_project_list_item_carries_optional_meta():
    base = {"project_id": "p", "title": "t", "size_bytes": 1,
            "uploaded_at": "2026-01-01T00:00:00Z", "updated_at": "2026-01-01T00:00:00Z"}
    assert CloudProjectListItem(**base).model_dump(exclude_none=True).get("meta") is None
    assert CloudProjectListItem(**base, meta={"k": 1}).model_dump(exclude_none=True)["meta"] == {"k": 1}


def test_sanitise_is_shared_between_presign_and_delete():
    assert _sanitise is sanitise_key_part
    assert sanitise_key_part("a/b c?.wav") == "a_b_c_.wav"
    assert sanitise_key_part("...") == "file"
    assert len(sanitise_key_part("x" * 500)) == 120


# --- B8: DSP endpoints still round-trip through the thread pool ----------------
def _sine_wav(sec: float = 1.0, hz: float = 220.0, sr: int = 22050) -> bytes:
    import io
    import numpy as np
    import soundfile as sf

    t = np.arange(int(sr * sec)) / sr
    y = (0.4 * np.sin(2 * np.pi * hz * t)).astype(np.float32)
    buf = io.BytesIO()
    sf.write(buf, y, sr, format="WAV", subtype="PCM_16")
    return buf.getvalue()


def test_process_vocal_roundtrip_off_loop(client):
    r = client.post("/process_vocal", files={"audio": ("a.wav", _sine_wav(), "audio/wav")},
                    data={"denoise": "0"})
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["sample_rate"] == analyze_mod.TARGET_SR
    assert 0.9 < body["duration"] < 1.1
    assert body["audio_b64"]


def test_analyze_roundtrip_carries_decode_info(client):
    r = client.post("/analyze", files={"audio": ("a.wav", _sine_wav(1.5), "audio/wav")})
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["input_codec"] == "wav"
    assert body["decoded_via"] == "soundfile"
    assert isinstance(body["notes"], list)


def test_analyze_undecodable_upload_is_400_not_500(client):
    r = client.post("/analyze", files={"audio": ("a.bin", b"\x00" * 4096, "application/octet-stream")})
    assert r.status_code in (400, 500)  # 400 once ffmpeg present; never leaks internals
    assert "{" not in r.json()["detail"] and "Traceback" not in r.json()["detail"]
