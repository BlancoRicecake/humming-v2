"""Sentry for the backend, without request contents (2026-11-04).

Codex reproduced offline with sentry-sdk 2.73.0 that ``send_default_pii=False``
alone still lets an error event carry what a request handled: the SDK's
default ``include_local_variables=True`` serialises every stack frame's
locals (the ASGI ``scope`` with the Authorization header, a presigned URL
with its signature, a song title, an object key) and the default
``max_request_body_size="medium"`` copies the JSON body into
``event.request.data``.

Errors stay reported with their type, message and stack trace. Turned off:
frame locals and request bodies. As a second line, ``_scrub`` filters any
remaining string that carries a bearer token or a signed-URL query, in
events and breadcrumbs, and drops auth / cookie headers and query strings
from the request part of an event.
"""
from __future__ import annotations

import re
from typing import Any, Callable, Optional

_FILTERED = "[Filtered]"
# a bearer / basic credential, or the query of an S3 / R2 presigned URL
_SECRET = re.compile(
    r"(?i)(\b(bearer|basic)\s+[A-Za-z0-9._~+/=-]{8,}"
    r"|X-Amz-(Signature|Credential|Security-Token)=)"
)
_SECRET_HEADERS = {"authorization", "cookie", "set-cookie", "x-api-key", "proxy-authorization"}


def _scrub(value: Any, depth: int = 0) -> Any:
    """``value`` with every string that carries a credential replaced."""
    if depth > 20:
        return value
    if isinstance(value, str):
        return _FILTERED if _SECRET.search(value) else value
    if isinstance(value, dict):
        return {k: _scrub(v, depth + 1) for k, v in value.items()}
    if isinstance(value, list):
        return [_scrub(v, depth + 1) for v in value]
    if isinstance(value, tuple):
        return tuple(_scrub(v, depth + 1) for v in value)
    return value


def _clean_request(request: dict) -> dict:
    request = dict(request)
    request.pop("data", None)  # bodies: song titles, object keys, receipts
    request.pop("cookies", None)
    if request.get("query_string"):
        request["query_string"] = _FILTERED
    url = request.get("url")
    if isinstance(url, str) and "?" in url:
        request["url"] = url.split("?", 1)[0]
    headers = request.get("headers")
    if isinstance(headers, dict):
        request["headers"] = {
            k: (_FILTERED if str(k).lower() in _SECRET_HEADERS else v) for k, v in headers.items()
        }
    return request


def before_send(event: dict, hint: dict) -> dict:
    if isinstance(event.get("request"), dict):
        event["request"] = _clean_request(event["request"])
    return _scrub(event)


def before_breadcrumb(crumb: dict, hint: dict) -> dict:
    return _scrub(crumb)


def sentry_options(
    *,
    dsn: str,
    environment: str,
    traces_sampler: Optional[Callable[[dict], float]] = None,
) -> dict:
    """The keyword arguments for ``sentry_sdk.init`` (also used by the
    regression test with an in-memory transport)."""
    from sentry_sdk.integrations.fastapi import FastApiIntegration
    from sentry_sdk.integrations.starlette import StarletteIntegration

    options: dict = dict(
        dsn=dsn,
        environment=environment,
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
        # no request contents in error events (see module docstring)
        include_local_variables=False,
        max_request_body_size="never",
        before_send=before_send,
        before_breadcrumb=before_breadcrumb,
    )
    if traces_sampler is not None:
        # traces_sampler (takes precedence over traces_sample_rate) so we can
        # exclude /health — see main._traces_sampler.
        options["traces_sampler"] = traces_sampler
    return options
