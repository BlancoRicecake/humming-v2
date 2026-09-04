"""Per-IP rate limits on the unauthenticated DSP / download endpoints.

These endpoints are deliberately open (the app works signed-out) and share one
shared-CPU machine, so an unbounded caller is a denial of service and a
bandwidth bill. Only the presence and per-IP scoping of the limit is asserted
here — the exact numbers are a tuning decision.
"""
import pytest
from fastapi.testclient import TestClient

from app.main import app, limiter


@pytest.fixture(autouse=True)
def _reset_limiter():
    if limiter is not None:
        limiter.reset()
    yield
    if limiter is not None:
        limiter.reset()


@pytest.fixture
def client():
    with TestClient(app) as c:
        yield c


def _post(client, path, ip="9.9.9.9"):
    return client.post(path, json={"notes": []}, headers={"fly-client-ip": ip})


@pytest.mark.skipif(limiter is None, reason="slowapi not installed")
def test_export_midi_is_rate_limited_per_ip(client):
    seen = [_post(client, "/export_midi").status_code for _ in range(31)]
    assert 429 in seen, "an unbounded caller must eventually be throttled"
    # a different IP is unaffected — the limit is per client, not global
    assert _post(client, "/export_midi", ip="8.8.8.8").status_code != 429


@pytest.mark.skipif(limiter is None, reason="slowapi not installed")
def test_soundfont_download_is_rate_limited(client):
    # 300MB files: the tightest limit of the lot.
    seen = [client.get("/soundfonts/nope", headers={"fly-client-ip": "7.7.7.7"}).status_code
            for _ in range(7)]
    assert 429 in seen


@pytest.mark.skipif(limiter is None, reason="slowapi not installed")
def test_render_mix_is_rate_limited(client):
    seen = [_post(client, "/render_mix", ip="6.6.6.6").status_code for _ in range(11)]
    assert 429 in seen
