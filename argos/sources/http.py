"""Polite HTTP with on-disk caching.

SEC asks automated clients to identify themselves and to stay under ten requests
a second. Everything here goes through one throttled, cached fetcher so a
re-run of a loader costs nothing and a first run stays within the rules.
"""

from __future__ import annotations

import hashlib
import os
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path

from ..config import REPO_ROOT

CACHE_DIR = Path(os.environ.get("ARGOS_HTTP_CACHE", REPO_ROOT / "data" / "cache"))
DEFAULT_USER_AGENT = os.environ.get(
    "ARGOS_USER_AGENT",
    "Argos-Research-Tool/1.0 (open-source research tool; set ARGOS_USER_AGENT to your contact)",
)
MIN_INTERVAL_SECONDS = 0.15
MAX_ATTEMPTS = 4

_lock = threading.Lock()
_last_request = 0.0


def _throttle() -> None:
    global _last_request
    with _lock:
        wait = MIN_INTERVAL_SECONDS - (time.monotonic() - _last_request)
        if wait > 0:
            time.sleep(wait)
        _last_request = time.monotonic()


def cache_path(url: str, suffix: str = "") -> Path:
    digest = hashlib.sha256(url.encode("utf-8")).hexdigest()[:32]
    return CACHE_DIR / f"{digest}{suffix}"


def fetch(url: str, *, cache: bool = True, timeout: int = 45, user_agent: str | None = None) -> bytes:
    """GET a URL, with a disk cache and exponential backoff on failure."""
    path = cache_path(url)
    if cache and path.exists():
        return path.read_bytes()

    headers = {
        "User-Agent": user_agent or DEFAULT_USER_AGENT,
        "Accept-Encoding": "gzip, deflate",
        "Accept": "*/*",
    }
    last_error: Exception | None = None
    for attempt in range(MAX_ATTEMPTS):
        _throttle()
        try:
            request = urllib.request.Request(url, headers=headers)
            with urllib.request.urlopen(request, timeout=timeout) as response:
                payload = response.read()
                if response.headers.get("Content-Encoding") in ("gzip", "deflate"):
                    import gzip
                    import zlib

                    try:
                        payload = gzip.decompress(payload)
                    except OSError:
                        payload = zlib.decompress(payload)
            if cache:
                CACHE_DIR.mkdir(parents=True, exist_ok=True)
                path.write_bytes(payload)
            return payload
        except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, OSError) as exc:
            last_error = exc
            status = getattr(exc, "code", None)
            if status in (400, 401, 403, 404):
                raise
            time.sleep(2 ** attempt)
    raise RuntimeError(f"failed to fetch {url}: {last_error}")


def fetch_json(url: str, **kwargs) -> dict:
    import json

    return json.loads(fetch(url, **kwargs).decode("utf-8", errors="replace"))
