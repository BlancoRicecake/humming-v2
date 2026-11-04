"""Sentry error events carry no request contents (2026-11-04).

Real sentry-sdk serialisation with an in-memory transport (no network,
synthetic markers only), through the real backend initialisation in
``app.main`` (run in a subprocess: Sentry's init is process-wide). Codex's
offline reproduction found a bearer token in frame locals (ASGI scope
headers), a presigned signature in a frame local, and a song title / object
key in frame locals and ``event.request.data``. None of them may appear;
the error type, message and stack trace must.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

pytest.importorskip("sentry_sdk")

BACKEND = Path(__file__).resolve().parents[1]

MARKERS = (
    "QA_SIGNATURE_SENTINEL",
    "QA_SONG_TITLE_SENTINEL",
    "QA_ACCESS_TOKEN_SENTINEL",
    "QA_OBJECT_KEY_SENTINEL",
)

PROBE = r'''
import json, logging, os, sys
logging.disable(logging.CRITICAL)
import sentry_sdk
from sentry_sdk.transport import Transport

events, crumbs = [], []

class MemoryTransport(Transport):
    def capture_envelope(self, envelope):
        for item in envelope.items:
            if item.type == "event":
                events.append(item.get_event())

real_init = sentry_sdk.init
seen = {}

def init(*args, **kwargs):  # the backend's own options + a memory transport
    seen.update(kwargs)
    kwargs.update(transport=MemoryTransport, send_client_reports=False, auto_session_tracking=False)
    return real_init(*args, **kwargs)

sentry_sdk.init = init

from fastapi import Request
from fastapi.testclient import TestClient
import app.main as main

@main.app.post("/qa-sentry-privacy")
async def qa_failure(request: Request):
    body = await request.json()
    presigned_url = "https://qa.r2.cloudflarestorage.com/owned-only?X-Amz-Signature=QA_SIGNATURE_SENTINEL"
    song_title = body.get("title")
    object_key = body["meta"]["key"]
    sentry_sdk.add_breadcrumb(category="httplib", data={"url": presigned_url})
    raise RuntimeError("QA synthetic cloud failure")

with TestClient(main.app, raise_server_exceptions=False) as client:
    status = client.post(
        "/qa-sentry-privacy?token=QA_ACCESS_TOKEN_SENTINEL",
        headers={"Authorization": "Bearer QA_ACCESS_TOKEN_SENTINEL"},
        json={"title": "QA_SONG_TITLE_SENTINEL", "meta": {"key": "vocals/qa/QA_OBJECT_KEY_SENTINEL"}},
    ).status_code
sentry_sdk.flush()

def strings(value, path="event"):
    if isinstance(value, dict):
        for k, v in value.items():
            if k not in ("pre_context", "context_line", "post_context"):  # source code lines
                yield from strings(v, f"{path}.{k}")
    elif isinstance(value, list):
        for i, v in enumerate(value):
            yield from strings(v, f"{path}.{i}")
    elif isinstance(value, str):
        yield path, value

# markers come by environment: Sentry reports sys.argv with every event
found = {m: [p for p, s in strings(events) if m in s] for m in os.environ["QA_MARKERS"].split(",")}
exc = (events[0].get("exception") or {}).get("values") if events else None
print(json.dumps({
    "status": status,
    "events": len(events),
    "found": found,
    "exception_type": exc[-1]["type"] if exc else None,
    "exception_value": exc[-1]["value"] if exc else None,
    "frames": len(exc[-1]["stacktrace"]["frames"]) if exc else 0,
    "has_function": any(f.get("function") == "qa_failure" for f in exc[-1]["stacktrace"]["frames"]) if exc else False,
    "frame_vars": sum(1 for f in exc[-1]["stacktrace"]["frames"] if f.get("vars")) if exc else 0,
    "request_data": "data" in (events[0].get("request") or {}) if events else None,
    "options": {k: seen.get(k) for k in ("send_default_pii", "include_local_variables", "max_request_body_size")},
}))
'''


def _run_probe() -> dict:
    env = {
        **os.environ,
        "SENTRY_DSN": "https://public@example.invalid/1",  # never contacted
        "PYTHONUTF8": "1",
        "QA_MARKERS": ",".join(MARKERS),
    }
    out = subprocess.run(
        [sys.executable, "-c", PROBE],
        cwd=BACKEND,
        env=env,
        capture_output=True,
        text=True,
        timeout=180,
    )
    assert out.returncode == 0, out.stderr[-4000:]
    return json.loads(out.stdout.strip().splitlines()[-1])


@pytest.fixture(scope="module")
def report() -> dict:
    return _run_probe()


def test_the_backend_error_event_is_still_reported_with_its_stack(report):
    assert report["status"] == 500
    assert report["events"] == 1
    assert report["exception_type"] == "RuntimeError"
    assert report["exception_value"] == "QA synthetic cloud failure"
    assert report["frames"] > 0 and report["has_function"]


@pytest.mark.parametrize("marker", MARKERS)
def test_no_request_contents_in_the_event(report, marker):
    assert report["found"][marker] == [], f"{marker} leaked at {report['found'][marker]}"


def test_no_frame_locals_and_no_request_body(report):
    assert report["frame_vars"] == 0
    assert report["request_data"] is False
    assert report["options"] == {
        "send_default_pii": False,
        "include_local_variables": False,
        "max_request_body_size": "never",
    }


def test_scrubber_filters_credentials_left_in_any_string():
    from app.sentry_setup import before_breadcrumb, before_send

    event = {
        "request": {
            "url": "https://api.example.test/x?X-Amz-Signature=abc",
            "query_string": "token=abc",
            "headers": {"Authorization": "Bearer abcdefghijkl", "Accept": "application/json"},
            "cookies": {"sb": "1"},
            "data": {"title": "song"},
        },
        "extra": {"u": "https://r2.test/k?X-Amz-Credential=a&X-Amz-Signature=b", "ok": "plain text"},
        "message": "token Bearer abcdefghijkl rejected",
    }
    out = before_send(event, {})
    assert out["request"] == {
        "url": "https://api.example.test/x",
        "query_string": "[Filtered]",
        "headers": {"Authorization": "[Filtered]", "Accept": "application/json"},
    }
    assert out["extra"] == {"u": "[Filtered]", "ok": "plain text"}
    assert out["message"] == "[Filtered]"
    crumb = before_breadcrumb({"data": {"url": "https://r2.test/k?X-Amz-Signature=b"}, "message": "GET"}, {})
    assert crumb == {"data": {"url": "[Filtered]"}, "message": "GET"}
