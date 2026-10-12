"""Stdlib HTTP server for the Argos API and web UI.

No framework and no third-party dependency: ``python -m argos serve`` works on a
bare Python install, which matters for a tool meant to run next to sensitive
documents on someone's own machine.

A single SQLite connection is shared behind a lock. Request volume for an
analyst tool is low and writes must not interleave, so one lock is both simpler
and safer than a connection pool.
"""

from __future__ import annotations

import json
import mimetypes
import re
import sqlite3
import threading
import traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, unquote, urlparse

from . import api, charts
from .config import CONFIG
from .db import open_db

MAX_BODY_BYTES = 8 * 1024 * 1024
COMPILED_ROUTES = [(method, re.compile(pattern), handler) for method, pattern, handler in api.ROUTES]

DOWNLOAD_TYPES = {
    ".html": "text/html; charset=utf-8",
    ".pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation",
    ".pdf": "application/pdf",
}


def _tokens_css() -> str:
    """Light tokens on :root, dark under both the OS query and the theme stamp."""
    light = charts.css_tokens("light", selector=":root")
    dark_body = charts.css_tokens("dark", selector=":root").split("{", 1)[1].rsplit("}", 1)[0]
    return "\n".join([
        light,
        '@media (prefers-color-scheme: dark) {',
        '  :root:where(:not([data-theme="light"])) {',
        dark_body,
        "  }",
        "}",
        ':root[data-theme="dark"] {',
        dark_body,
        "}",
        "",
    ])


class ArgosHandler(BaseHTTPRequestHandler):
    server_version = "Argos/1.0"
    protocol_version = "HTTP/1.1"

    # -------------------------------------------------------------- helpers

    @property
    def conn(self) -> sqlite3.Connection:
        return self.server.db  # type: ignore[attr-defined]

    @property
    def lock(self) -> threading.Lock:
        return self.server.lock  # type: ignore[attr-defined]

    def log_message(self, fmt: str, *args: Any) -> None:  # quieter default logging
        if self.server.verbose:  # type: ignore[attr-defined]
            super().log_message(fmt, *args)

    def _send(self, status: int, body: bytes, content_type: str, extra: dict[str, str] | None = None) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        for key, value in (extra or {}).items():
            self.send_header(key, value)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _send_json(self, status: int, payload: Any) -> None:
        body = json.dumps(payload, default=str).encode("utf-8")
        self._send(status, body, "application/json; charset=utf-8")

    def _read_body(self) -> Any:
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0:
            return {}
        if length > MAX_BODY_BYTES:
            raise api.ApiError("request body too large", 413)
        raw = self.rfile.read(length)
        if not raw:
            return {}
        try:
            return json.loads(raw.decode("utf-8"))
        except (ValueError, UnicodeDecodeError) as exc:
            raise api.ApiError(f"invalid JSON body: {exc}") from exc

    # -------------------------------------------------------------- routing

    def _serve_static(self, path: str) -> None:
        relative = "index.html" if path in ("/", "") else path.lstrip("/")
        candidate = (CONFIG.static_dir / relative).resolve()
        static_root = CONFIG.static_dir.resolve()
        if not str(candidate).startswith(str(static_root)) or not candidate.is_file():
            self._send_json(404, {"error": "not found", "path": path})
            return
        content_type = mimetypes.guess_type(candidate.name)[0] or "application/octet-stream"
        if content_type.startswith("text/") or content_type in ("application/javascript", "application/json"):
            content_type += "; charset=utf-8"
        self._send(200, candidate.read_bytes(), content_type)

    def _serve_download(self, params: dict[str, list[str]], pitchbook_id: int) -> None:
        """Export a deck and stream it back as an attachment."""
        with self.lock:
            result = api.export_pitchbook(self.conn, params, {}, pitchbook_id)
        path = Path(result["path"])
        suffix = path.suffix.lower()
        self._send(
            200, path.read_bytes(),
            DOWNLOAD_TYPES.get(suffix, "application/octet-stream"),
            {"Content-Disposition": f'attachment; filename="{path.name}"'},
        )

    def _dispatch(self) -> None:
        parsed = urlparse(self.path)
        path = unquote(parsed.path)
        params = parse_qs(parsed.query)

        if path == "/tokens.css":
            # The palette lives in Python so the UI, the HTML deck and the PPTX
            # export cannot drift apart.
            self._send(200, _tokens_css().encode("utf-8"), "text/css; charset=utf-8")
            return

        if not path.startswith("/api/"):
            self._serve_static(path)
            return

        method = "GET" if self.command == "HEAD" else self.command
        for route_method, pattern, handler in COMPILED_ROUTES:
            if route_method != method:
                continue
            match = pattern.match(path)
            if not match:
                continue
            kwargs: dict[str, Any] = {}
            for key, value in match.groupdict().items():
                kwargs[key] = int(value) if key in api.INT_PARAMS else value
            body = self._read_body() if method in ("POST", "PATCH", "PUT") else {}
            if handler is api.export_pitchbook and params.get("download", ["1"])[0] not in ("0", "false"):
                self._serve_download(params, int(kwargs["pitchbook_id"]))
                return
            with self.lock:
                payload = handler(self.conn, params, body, **kwargs)
            self._send_json(200, payload)
            return

        allowed = sorted({m for m, pattern, _ in COMPILED_ROUTES if pattern.match(path)})
        if allowed:
            self._send_json(405, {"error": "method not allowed", "allowed": allowed})
        else:
            self._send_json(404, {"error": "no such endpoint", "path": path})

    def _handle(self) -> None:
        try:
            self._dispatch()
        except api.ApiError as exc:
            self._send_json(exc.status, {"error": exc.message})
        except BrokenPipeError:
            pass
        except Exception as exc:  # pragma: no cover - surfaced to the client
            if self.server.verbose:  # type: ignore[attr-defined]
                traceback.print_exc()
            self._send_json(500, {"error": f"{type(exc).__name__}: {exc}"})

    do_GET = do_POST = do_PATCH = do_DELETE = do_HEAD = _handle


class ArgosServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, address: tuple[str, int], db: sqlite3.Connection, *, verbose: bool = False) -> None:
        super().__init__(address, ArgosHandler)
        self.db = db
        self.lock = threading.Lock()
        self.verbose = verbose


def create_server(
    host: str | None = None, port: int | None = None, *,
    db_path: Path | str | None = None, conn: sqlite3.Connection | None = None, verbose: bool = False,
) -> ArgosServer:
    CONFIG.ensure_dirs()
    database = conn or open_db(db_path)
    return ArgosServer((host or CONFIG.host, port if port is not None else CONFIG.port), database, verbose=verbose)


def serve(
    host: str | None = None, port: int | None = None, *,
    db_path: Path | str | None = None, verbose: bool = True,
) -> None:
    httpd = create_server(host, port, db_path=db_path, verbose=verbose)
    host, port = httpd.server_address[0], httpd.server_address[1]
    print(f"Argos is running at http://{host}:{port}  (Ctrl-C to stop)")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down.")
    finally:
        httpd.server_close()
