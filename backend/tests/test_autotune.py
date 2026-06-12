"""Autotune (/autotune, app.autotune) — DSP and endpoint tests.

Synthesizes vibrato sines (no fixtures), runs the WORLD round-trip, and
re-measures f0 on the output to assert it lands on the requested scale.
"""
import base64
import io
import math

import numpy as np
import pytest
import soundfile as sf

from app.autotune import AT_SR, _nearest_scale_midi, autotune_vocal, retune_f0
from app.scales import scale_pitch_classes

A3_HZ = 220.0


def vibrato_sine(center_hz: float, cents: float, vib_hz: float, sec: float, sr: int = AT_SR) -> np.ndarray:
    """Sine whose pitch wobbles ±cents around center_hz at vib_hz."""
    t = np.arange(int(sr * sec)) / sr
    inst_hz = center_hz * 2.0 ** (cents / 1200.0 * np.sin(2 * math.pi * vib_hz * t))
    phase = 2 * math.pi * np.cumsum(inst_hz) / sr
    return (0.5 * np.sin(phase)).astype(np.float32)


def wav_bytes(y: np.ndarray, sr: int = AT_SR) -> bytes:
    buf = io.BytesIO()
    sf.write(buf, y, sr, format="WAV", subtype="PCM_16")
    return buf.getvalue()


def measured_f0(wav: bytes):
    import pyworld as pw

    y, sr = sf.read(io.BytesIO(wav), dtype="float64", always_2d=False)
    f0, t = pw.dio(y, sr, frame_period=5.0)
    return pw.stonemask(y, f0, t, sr)


def cents_off_scale(f0: np.ndarray, tonic: str, scale: str) -> np.ndarray:
    """Per voiced frame: |cents| to the nearest in-scale note."""
    pcs = scale_pitch_classes(tonic, scale)
    v = f0[f0 > 0]
    midi = 69 + 12 * np.log2(v / 440.0)
    out = []
    for m in midi:
        best = min(
            abs((round(m) - round(m) % 12 + pc + 12 * o) - m)
            for o in (-1, 0, 1)
            for pc in pcs
        )
        out.append(best * 100)
    return np.asarray(out)


def test_full_strength_snaps_vibrato_to_a_minor():
    # ±60 cents of slow vibrato around A3 (in-scale tone of A minor)
    y = vibrato_sine(A3_HZ, 60, 1.5, 4.0)
    wav, peaks, dur, sr = autotune_vocal(wav_bytes(y), "A", "minor", strength=1.0, retune_ms=20, denoise=False)
    assert sr == AT_SR
    assert abs(dur - 4.0) < 0.15  # duration preserved
    assert len(peaks) > 0
    before = cents_off_scale(measured_f0(wav_bytes(y)), "A", "minor")
    after = cents_off_scale(measured_f0(wav), "A", "minor")
    # trim edge frames (onset/decay artifacts)
    assert np.median(after[20:-20]) < 15
    assert np.median(after[20:-20]) < np.median(before[20:-20])


def test_zero_strength_leaves_pitch_alone():
    y = vibrato_sine(A3_HZ, 60, 1.5, 2.0)
    wav, *_ = autotune_vocal(wav_bytes(y), "A", "minor", strength=0.0, retune_ms=20, denoise=False)
    after = cents_off_scale(measured_f0(wav), "A", "minor")
    # vibrato survives: median deviation stays well above the snapped case
    assert np.median(after[20:-20]) > 20


def test_retune_hysteresis_no_warble():
    # f0 oscillating ON the A3/B3 nearest-note boundary (58.0 in A minor) — a
    # naive nearest-note tracker flips every crossing; hysteresis holds the
    # target because the new note never wins by more than the margin.
    n = 2000  # frames @5ms = 10s
    t = np.arange(n)
    midi_track = 58.0 + 0.25 * np.sin(2 * math.pi * t / 400)  # 57.75..58.25
    f0 = 440.0 * 2.0 ** ((midi_track - 69) / 12.0)
    pcs = scale_pitch_classes("A", "minor")
    naive = np.asarray([_nearest_scale_midi(m, pcs) for m in midi_track])
    naive_flips = np.count_nonzero(np.diff(naive) != 0)
    assert naive_flips >= 8  # the track really does straddle the boundary
    out = retune_f0(f0, "A", "minor", strength=1.0, retune_ms=1.0)
    tgt_midi = 69 + 12 * np.log2(out / 440.0)
    flips = np.count_nonzero(np.abs(np.diff(np.round(tgt_midi))) > 0)
    assert flips < naive_flips  # held targets, not per-frame flapping


def test_unvoiced_frames_pass_through():
    f0 = np.zeros(100)
    f0[40:60] = A3_HZ
    out = retune_f0(f0, "A", "minor")
    assert np.all(out[:40] == 0)
    assert np.all(out[60:] == 0)
    assert np.all(out[40:60] > 0)


def test_unknown_scale_raises_value_error():
    y = vibrato_sine(A3_HZ, 10, 1, 0.5)
    with pytest.raises(ValueError):
        autotune_vocal(wav_bytes(y), "A", "nope", denoise=False)


def test_overlong_input_rejected():
    sr = 8000  # small synthetic blob, resampled internally
    y = np.zeros(int(sr * 61), dtype=np.float32)
    with pytest.raises(ValueError):
        autotune_vocal(wav_bytes(y, sr), "A", "minor", denoise=False)


def test_endpoint_roundtrip():
    from fastapi.testclient import TestClient

    from app.main import app

    client = TestClient(app)
    y = vibrato_sine(A3_HZ, 40, 1.5, 1.5)
    r = client.post(
        "/autotune",
        files={"audio": ("v.wav", wav_bytes(y), "audio/wav")},
        data={"key": "A", "scale": "minor", "strength": "1.0", "retune_ms": "40", "denoise": "0"},
    )
    assert r.status_code == 200, r.text
    j = r.json()
    assert j["sample_rate"] == AT_SR
    wav = base64.b64decode(j["audio_b64"])
    assert wav[:4] == b"RIFF"
    assert len(j["peaks"]) > 0


def test_endpoint_bad_scale_is_400():
    from fastapi.testclient import TestClient

    from app.main import app

    client = TestClient(app)
    y = vibrato_sine(A3_HZ, 40, 1.5, 0.5)
    r = client.post(
        "/autotune",
        files={"audio": ("v.wav", wav_bytes(y), "audio/wav")},
        data={"key": "A", "scale": "nope"},
    )
    assert r.status_code == 400


def test_endpoint_undecodable_upload_is_400():
    from fastapi.testclient import TestClient

    from app.main import app

    client = TestClient(app)
    # not a WAV → ffmpeg path → decode failure must surface as 400, not 500
    r = client.post(
        "/autotune",
        files={"audio": ("v.wav", b"definitely not audio" * 64, "audio/wav")},
        data={"key": "A", "scale": "minor"},
    )
    assert r.status_code == 400, r.text
    # RIFF/WAVE magic but corrupt body → libsndfile path → still 400
    r = client.post(
        "/autotune",
        files={"audio": ("v.wav", b"RIFF\x10\x00\x00\x00WAVEjunk" * 16, "audio/wav")},
        data={"key": "A", "scale": "minor"},
    )
    assert r.status_code == 400, r.text


def test_endpoint_nan_strength_is_400():
    from fastapi.testclient import TestClient

    from app.main import app

    client = TestClient(app)
    y = vibrato_sine(A3_HZ, 40, 1.5, 0.5)
    r = client.post(
        "/autotune",
        files={"audio": ("v.wav", wav_bytes(y), "audio/wav")},
        data={"key": "A", "scale": "minor", "strength": "nan"},
    )
    assert r.status_code == 400
    r = client.post(
        "/autotune",
        files={"audio": ("v.wav", wav_bytes(y), "audio/wav")},
        data={"key": "A", "scale": "minor", "retune_ms": "nan"},
    )
    assert r.status_code == 400


def test_endpoint_too_short_input_is_400():
    from fastapi.testclient import TestClient

    from app.main import app

    client = TestClient(app)
    y = vibrato_sine(A3_HZ, 40, 1.5, 0.1)  # < MIN_DURATION_SEC
    r = client.post(
        "/autotune",
        files={"audio": ("v.wav", wav_bytes(y), "audio/wav")},
        data={"key": "A", "scale": "minor"},
    )
    assert r.status_code == 400
    assert "short" in r.json()["detail"]
