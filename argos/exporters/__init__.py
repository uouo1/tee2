"""Deck exporters. Each renders the same slide payloads to a different medium."""

from __future__ import annotations

from pathlib import Path
from typing import Any

from .html_export import render_deck_body, render_deck_html, write_html


def available_formats() -> dict[str, bool]:
    """Which export formats this install can produce.

    HTML is always available (stdlib only); PPTX and PDF depend on optional
    third-party libraries, so the UI can hide what it cannot deliver.
    """
    formats = {"html": True, "pptx": False, "pdf": False}
    try:
        import pptx  # noqa: F401

        formats["pptx"] = True
    except ImportError:
        pass
    try:
        import reportlab  # noqa: F401

        formats["pdf"] = True
    except ImportError:
        pass
    return formats


def export(book: dict[str, Any], fmt: str, path: Path) -> Path:
    """Write ``book`` to ``path`` in ``fmt`` (html | pptx | pdf)."""
    fmt = fmt.lower()
    if fmt == "html":
        return write_html(book, path)
    if fmt == "pptx":
        from .pptx_export import write_pptx

        return write_pptx(book, path)
    if fmt == "pdf":
        from .pdf_export import write_pdf

        return write_pdf(book, path)
    raise ValueError(f"unsupported export format: {fmt}")


__all__ = ["available_formats", "export", "render_deck_body", "render_deck_html", "write_html"]
