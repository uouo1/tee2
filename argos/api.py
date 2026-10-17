"""JSON API layer.

Handlers are plain functions of ``(conn, params, body)`` returning a dict, so
they are directly unit-testable without a running server. The HTTP plumbing
lives in :mod:`argos.server`.
"""

from __future__ import annotations

import sqlite3
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable

from . import analytics, charts, ingest, pitchbook, search, seed, valuation
from .config import CONFIG
from .db import dump_json, insert, query, query_one
from .exporters import available_formats, export, render_deck_body


class ApiError(Exception):
    """An error with an HTTP status attached."""

    def __init__(self, message: str, status: int = 400) -> None:
        super().__init__(message)
        self.message = message
        self.status = status


def _first(params: dict[str, list[str]], key: str, default: Any = None) -> Any:
    values = params.get(key)
    return values[0] if values else default


def _int(params: dict[str, list[str]], key: str, default: int) -> int:
    raw = _first(params, key)
    try:
        return int(raw) if raw not in (None, "") else default
    except (TypeError, ValueError):
        return default


def _bool(params: dict[str, list[str]], key: str, default: bool = False) -> bool:
    raw = _first(params, key)
    if raw is None:
        return default
    return str(raw).lower() not in ("0", "false", "no", "")


def _search_filters(params: dict[str, list[str]]) -> dict[str, Any]:
    filters: dict[str, Any] = {}
    multi = {"doc_type": "doc_type", "ticker": "ticker"}
    for key, target in multi.items():
        values = [v for v in params.get(key, []) if v]
        if values:
            filters[target] = values
    for key in ("company", "sector", "source", "author", "sentiment", "date_from", "date_to"):
        value = _first(params, key)
        if value:
            filters[key] = value
    return filters


# ----------------------------------------------------------------- research


def health(conn: sqlite3.Connection, params, body) -> dict[str, Any]:
    return {
        "status": "ok",
        "time": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "documents": query_one(conn, "SELECT COUNT(*) AS n FROM documents")["n"],
        "export_formats": available_formats(),
    }


def get_overview(conn, params, body) -> dict[str, Any]:
    return analytics.overview(conn)


def get_search(conn, params, body) -> dict[str, Any]:
    return search.search(
        conn,
        _first(params, "q", "") or "",
        _search_filters(params),
        limit=_int(params, "limit", 25),
        offset=_int(params, "offset", 0),
        expand=_bool(params, "expand", True),
        summarize=_bool(params, "summarize", True),
    )


def get_document(conn, params, body, document_id: int) -> dict[str, Any]:
    terms = (_first(params, "q", "") or "").split()
    document = search.get_document(conn, document_id, query_terms=terms)
    if not document:
        raise ApiError(f"document {document_id} not found", 404)
    return document


def get_companies(conn, params, body) -> dict[str, Any]:
    rows = query(conn, """
        SELECT c.id, c.ticker, c.name, c.sector, c.industry, c.country, c.hq, c.employees,
               m.share_price, m.shares_diluted, m.net_debt,
               (SELECT COUNT(*) FROM documents d WHERE d.company_id = c.id) AS documents,
               (SELECT ROUND(AVG(d.sentiment), 3) FROM documents d WHERE d.company_id = c.id) AS sentiment
        FROM companies c LEFT JOIN market_data m ON m.company_id = c.id
        ORDER BY c.ticker
    """)
    return {"companies": rows}


def get_company(conn, params, body, ticker: str) -> dict[str, Any]:
    profile = analytics.company_profile(conn, ticker)
    if not profile:
        raise ApiError(f"company {ticker} not found", 404)
    profile["volume_by_type"] = analytics.volume_by_type(conn, ticker=ticker)
    return profile


def get_trends(conn, params, body) -> dict[str, Any]:
    ticker = _first(params, "ticker")
    window = _int(params, "window_days", 120)
    return {
        "themes": analytics.trending_themes(conn, window_days=window, ticker=ticker, limit=_int(params, "limit", 12)),
        "sentiment_timeline": analytics.sentiment_timeline(conn, ticker=ticker, months=_int(params, "months", 24)),
        "volume_by_type": analytics.volume_by_type(conn, ticker=ticker, months=_int(params, "months", 24)),
    }


def get_transactions(conn, params, body) -> dict[str, Any]:
    return valuation.precedent_transactions(conn, sector=_first(params, "sector"))


def post_ingest(conn, params, body) -> dict[str, Any]:
    documents = body.get("documents") if isinstance(body, dict) else body
    if isinstance(body, dict) and body.get("path"):
        return ingest.ingest_path(conn, Path(str(body["path"])))
    if not isinstance(documents, list) or not documents:
        raise ApiError("expected {\"documents\": [...]} or {\"path\": \"...\"}")
    try:
        return ingest.ingest_many(conn, documents)
    except ValueError as exc:
        raise ApiError(str(exc)) from exc


def post_seed(conn, params, body) -> dict[str, Any]:
    return seed.seed_database(conn)


# -------------------------------------------------------- watchlists/alerts


def get_watchlists(conn, params, body) -> dict[str, Any]:
    lists = query(conn, "SELECT * FROM watchlists ORDER BY name")
    for item in lists:
        item["companies"] = query(conn, """
            SELECT c.ticker, c.name, c.sector,
                   (SELECT ROUND(AVG(d.sentiment), 3) FROM documents d WHERE d.company_id = c.id) AS sentiment,
                   (SELECT MAX(d.published_at) FROM documents d WHERE d.company_id = c.id) AS latest
            FROM watchlist_items wi JOIN companies c ON c.id = wi.company_id
            WHERE wi.watchlist_id = ? ORDER BY c.ticker
        """, (item["id"],))
    return {"watchlists": lists}


def post_watchlist(conn, params, body) -> dict[str, Any]:
    name = (body or {}).get("name", "").strip()
    if not name:
        raise ApiError("watchlist name is required")
    existing = query_one(conn, "SELECT id FROM watchlists WHERE name = ?", (name,))
    watchlist_id = existing["id"] if existing else insert(
        conn, "watchlists", {"name": name, "created_at": datetime.now(timezone.utc).isoformat(timespec="seconds")}
    )
    for ticker in (body or {}).get("tickers", []):
        company = query_one(conn, "SELECT id FROM companies WHERE ticker = ?", (str(ticker).upper(),))
        if company:
            conn.execute(
                "INSERT OR IGNORE INTO watchlist_items (watchlist_id, company_id) VALUES (?, ?)",
                (watchlist_id, company["id"]),
            )
    conn.commit()
    return {"id": watchlist_id, "name": name}


def post_watchlist_items(conn, params, body, watchlist_id: int) -> dict[str, Any]:
    tickers = (body or {}).get("tickers") or ([body.get("ticker")] if (body or {}).get("ticker") else [])
    if not tickers:
        raise ApiError("ticker(s) required")
    for ticker in tickers:
        company = query_one(conn, "SELECT id FROM companies WHERE ticker = ?", (str(ticker).upper(),))
        if not company:
            raise ApiError(f"unknown ticker: {ticker}", 404)
        conn.execute(
            "INSERT OR IGNORE INTO watchlist_items (watchlist_id, company_id) VALUES (?, ?)",
            (watchlist_id, company["id"]),
        )
    conn.commit()
    return {"watchlist_id": watchlist_id, "added": [str(t).upper() for t in tickers]}


def delete_watchlist_item(conn, params, body, watchlist_id: int, ticker: str) -> dict[str, Any]:
    conn.execute("""
        DELETE FROM watchlist_items WHERE watchlist_id = ?
        AND company_id = (SELECT id FROM companies WHERE ticker = ?)
    """, (watchlist_id, ticker.upper()))
    conn.commit()
    return {"removed": ticker.upper()}


def delete_watchlist(conn, params, body, watchlist_id: int) -> dict[str, Any]:
    conn.execute("DELETE FROM watchlists WHERE id = ?", (watchlist_id,))
    conn.commit()
    return {"deleted": watchlist_id}


def get_saved_searches(conn, params, body) -> dict[str, Any]:
    return {"saved_searches": query(conn, "SELECT * FROM saved_searches ORDER BY id DESC")}


def post_saved_search(conn, params, body) -> dict[str, Any]:
    payload = body or {}
    if not (payload.get("query") or "").strip():
        raise ApiError("query is required")
    newest = query_one(conn, "SELECT COALESCE(MAX(id), 0) AS n FROM documents")["n"]
    saved_id = insert(conn, "saved_searches", {
        "name": payload.get("name") or payload["query"][:60],
        "query": payload["query"],
        "filters": dump_json(payload.get("filters") or {}),
        "created_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "last_seen_document_id": payload.get("last_seen_document_id", newest),
    })
    conn.commit()
    return query_one(conn, "SELECT * FROM saved_searches WHERE id = ?", (saved_id,)) or {}


def delete_saved_search(conn, params, body, saved_id: int) -> dict[str, Any]:
    conn.execute("DELETE FROM saved_searches WHERE id = ?", (saved_id,))
    conn.commit()
    return {"deleted": saved_id}


def get_alerts(conn, params, body) -> dict[str, Any]:
    return {"alerts": analytics.check_alerts(conn, mark_seen=_bool(params, "mark_seen", False))}


# --------------------------------------------------------------- pitchbooks


def get_pitchbooks(conn, params, body) -> dict[str, Any]:
    return {"pitchbooks": pitchbook.list_pitchbooks(conn), "export_formats": available_formats()}


def post_pitchbook(conn, params, body) -> dict[str, Any]:
    payload = body or {}
    target = (payload.get("target_ticker") or "").strip()
    if not target:
        raise ApiError("target_ticker is required")
    title = payload.get("title") or f"Project {target.upper()}"
    try:
        pitchbook_id = pitchbook.create_pitchbook(
            conn,
            title=title,
            target_ticker=target,
            comp_tickers=payload.get("comp_tickers"),
            client_name=payload.get("client_name"),
            subtitle=payload.get("subtitle"),
            banker=payload.get("banker"),
            assumptions=payload.get("assumptions"),
        )
    except ValueError as exc:
        raise ApiError(str(exc), 404) from exc
    return pitchbook.get_pitchbook(conn, pitchbook_id) or {}


def get_pitchbook(conn, params, body, pitchbook_id: int) -> dict[str, Any]:
    book = pitchbook.get_pitchbook(conn, pitchbook_id)
    if not book:
        raise ApiError(f"pitchbook {pitchbook_id} not found", 404)
    return book


def delete_pitchbook(conn, params, body, pitchbook_id: int) -> dict[str, Any]:
    if not pitchbook.delete_pitchbook(conn, pitchbook_id):
        raise ApiError(f"pitchbook {pitchbook_id} not found", 404)
    return {"deleted": pitchbook_id}


def post_rebuild(conn, params, body, pitchbook_id: int) -> dict[str, Any]:
    try:
        pitchbook.rebuild_slides(conn, pitchbook_id)
    except ValueError as exc:
        raise ApiError(str(exc), 404) from exc
    return pitchbook.get_pitchbook(conn, pitchbook_id) or {}


def post_comps(conn, params, body, pitchbook_id: int) -> dict[str, Any]:
    tickers = (body or {}).get("tickers")
    if not isinstance(tickers, list):
        raise ApiError("tickers must be a list")
    pitchbook.set_comps(conn, pitchbook_id, tickers)
    return pitchbook.get_pitchbook(conn, pitchbook_id) or {}


def post_assumptions(conn, params, body, pitchbook_id: int) -> dict[str, Any]:
    try:
        pitchbook.set_assumptions(conn, pitchbook_id, body or {})
    except (ValueError, TypeError) as exc:
        raise ApiError(str(exc)) from exc
    return pitchbook.get_pitchbook(conn, pitchbook_id) or {}


def get_valuation(conn, params, body, pitchbook_id: int) -> dict[str, Any]:
    book = pitchbook.get_pitchbook(conn, pitchbook_id)
    if not book:
        raise ApiError(f"pitchbook {pitchbook_id} not found", 404)
    try:
        return valuation.football_field(conn, book["ticker"], book["comps"], assumptions=book["assumptions"])
    except ValueError as exc:
        raise ApiError(str(exc)) from exc


def patch_slide(conn, params, body, slide_id: int) -> dict[str, Any]:
    payload = body or {}
    slide = pitchbook.update_slide(
        conn, slide_id,
        title=payload.get("title"),
        subtitle=payload.get("subtitle"),
        payload=payload.get("payload"),
        pin=payload.get("pin"),
    )
    if not slide:
        raise ApiError(f"slide {slide_id} not found", 404)
    return slide


def post_reorder(conn, params, body, pitchbook_id: int) -> dict[str, Any]:
    order = (body or {}).get("slide_ids")
    if not isinstance(order, list):
        raise ApiError("slide_ids must be a list")
    return {"slides": pitchbook.reorder_slides(conn, pitchbook_id, [int(s) for s in order])}


def post_evidence(conn, params, body, pitchbook_id: int) -> dict[str, Any]:
    payload = body or {}
    try:
        return pitchbook.add_evidence(
            conn, pitchbook_id,
            quote=payload.get("quote", ""),
            document_id=payload.get("document_id"),
            chunk_id=payload.get("chunk_id"),
            slide_id=payload.get("slide_id"),
            note=payload.get("note"),
        )
    except ValueError as exc:
        raise ApiError(str(exc)) from exc


def delete_evidence(conn, params, body, evidence_id: int) -> dict[str, Any]:
    if not pitchbook.delete_evidence(conn, evidence_id):
        raise ApiError(f"evidence {evidence_id} not found", 404)
    return {"deleted": evidence_id}


def get_suggest_comps(conn, params, body, ticker: str) -> dict[str, Any]:
    return {"ticker": ticker.upper(), "comps": pitchbook.suggest_comps(conn, ticker)}


def export_pitchbook(conn, params, body, pitchbook_id: int) -> dict[str, Any]:
    """Export a deck to disk and return the path plus bytes for download."""
    book = pitchbook.get_pitchbook(conn, pitchbook_id)
    if not book:
        raise ApiError(f"pitchbook {pitchbook_id} not found", 404)
    fmt = (_first(params, "format", "html") or "html").lower()
    if not available_formats().get(fmt):
        raise ApiError(f"export format unavailable: {fmt}", 400)
    CONFIG.ensure_dirs()
    safe_title = "".join(ch if ch.isalnum() or ch in "-_ " else "" for ch in book["title"]).strip().replace(" ", "-")
    path = CONFIG.export_dir / f"{safe_title or 'pitchbook'}-{pitchbook_id}.{fmt}"
    export(book, fmt, path)
    return {"path": str(path), "format": fmt, "filename": path.name, "bytes": path.stat().st_size}


def get_pitchbook_preview(conn, params, body, pitchbook_id: int) -> dict[str, Any]:
    """Deck markup for the in-app preview — the exporter's own renderers."""
    book = pitchbook.get_pitchbook(conn, pitchbook_id)
    if not book:
        raise ApiError(f"pitchbook {pitchbook_id} not found", 404)
    return {"id": pitchbook_id, "title": book["title"], "html": render_deck_body(book)}


def get_company_charts(conn, params, body, ticker: str) -> dict[str, Any]:
    """Server-rendered SVG for a company page.

    Rendering charts in Python rather than in the browser means the figures on
    screen and the figures in the exported deck come from one implementation.
    """
    profile = analytics.company_profile(conn, ticker)
    if not profile:
        raise ApiError(f"company {ticker} not found", 404)
    # Fiscal-year rows only: an LTM row would plot as a duplicate of the year it
    # extends, and a consensus row carries revenue and EPS but no EBITDA, so its
    # margin point is blank rather than a crash (found on the reloaded Itron data).
    financials = [row for row in (profile.get("financials") or []) if row.get("period_type", "FY") == "FY"]
    labels = [f"FY{row['fiscal_year']}{'E' if row.get('is_estimate') else ''}" for row in financials]
    estimate_from = next((i for i, row in enumerate(financials) if row["is_estimate"]), None)
    timeline = profile.get("sentiment_timeline") or []
    volume = analytics.volume_by_type(conn, ticker=ticker)
    margins = [
        (float(row["ebitda"]) / float(row["revenue"]) * 100
         if row.get("revenue") and row.get("ebitda") is not None else None)
        for row in financials
    ]
    return {
        "revenue": charts.column_chart_svg(
            labels, [float(row["revenue"] or 0) for row in financials],
            title=f"Revenue ({profile.get('currency', 'USD')}m)", estimate_from=estimate_from,
        ),
        "margin": charts.line_chart_svg(labels, margins, title="EBITDA margin (%)"),
        "sentiment": charts.diverging_bar_svg(
            [row["month"][-5:] for row in timeline],
            [float(row["sentiment"] or 0) for row in timeline],
            title="Document tone by month (−1 to +1)",
        ),
        "volume": charts.stacked_bar_svg(
            [month[-5:] for month in volume.get("months", [])], volume.get("series", []),
            title="Documents published by type",
        ),
    }


def get_dashboard_charts(conn, params, body) -> dict[str, Any]:
    """Server-rendered SVG for the dashboard."""
    timeline = analytics.sentiment_timeline(conn, months=_int(params, "months", 24))
    volume = analytics.volume_by_type(conn, months=_int(params, "months", 24))
    return {
        "sentiment": charts.diverging_bar_svg(
            [row["month"][-5:] for row in timeline],
            [float(row["sentiment"] or 0) for row in timeline],
            title="Corpus tone by month (−1 to +1)",
        ),
        "volume": charts.stacked_bar_svg(
            [month[-5:] for month in volume.get("months", [])], volume.get("series", []),
            title="Documents published by type",
        ),
    }


def get_valuation_chart(conn, params, body, pitchbook_id: int) -> dict[str, Any]:
    """Football field SVG for a pitch book, for the valuation workbench."""
    field = get_valuation(conn, params, body, pitchbook_id)
    currency = field["target"].get("currency", "USD")
    symbol = {"USD": "$", "EUR": "€", "GBP": "£"}.get(currency, "")
    return {
        "football_field": charts.football_field_svg(
            field["ranges"], reference_price=field["reference_price"],
            concluded=field["concluded_range"], currency_symbol=symbol,
        ),
        "sensitivity": charts.heatmap_html(
            field["sensitivity"]["grid"],
            row_labels=[f"{g * 100:.2f}%" for g in field["sensitivity"]["terminal_axis"]],
            column_labels=[f"{w * 100:.2f}%" for w in field["sensitivity"]["wacc_axis"]],
            row_title="Terminal growth", column_title="WACC",
            reference=field["reference_price"],
        ),
        "ranges": field["ranges"],
        "concluded_range": field["concluded_range"],
        "reference_price": field["reference_price"],
        "dcf": field["dcf"],
        "comps": field["comps"],
    }


def get_export_formats(conn, params, body) -> dict[str, Any]:
    return {"formats": available_formats()}


# ------------------------------------------------------------------- routes

Handler = Callable[..., dict[str, Any]]

ROUTES: tuple[tuple[str, str, Handler], ...] = (
    ("GET", r"^/api/health$", health),
    ("GET", r"^/api/overview$", get_overview),
    ("GET", r"^/api/search$", get_search),
    ("GET", r"^/api/documents/(?P<document_id>\d+)$", get_document),
    ("GET", r"^/api/companies$", get_companies),
    ("GET", r"^/api/companies/(?P<ticker>[A-Za-z0-9.\-]+)$", get_company),
    ("GET", r"^/api/companies/(?P<ticker>[A-Za-z0-9.\-]+)/suggest-comps$", get_suggest_comps),
    ("GET", r"^/api/trends$", get_trends),
    ("GET", r"^/api/transactions$", get_transactions),
    ("POST", r"^/api/ingest$", post_ingest),
    ("POST", r"^/api/seed$", post_seed),
    ("GET", r"^/api/watchlists$", get_watchlists),
    ("POST", r"^/api/watchlists$", post_watchlist),
    ("POST", r"^/api/watchlists/(?P<watchlist_id>\d+)/items$", post_watchlist_items),
    ("DELETE", r"^/api/watchlists/(?P<watchlist_id>\d+)/items/(?P<ticker>[A-Za-z0-9.\-]+)$", delete_watchlist_item),
    ("DELETE", r"^/api/watchlists/(?P<watchlist_id>\d+)$", delete_watchlist),
    ("GET", r"^/api/saved-searches$", get_saved_searches),
    ("POST", r"^/api/saved-searches$", post_saved_search),
    ("DELETE", r"^/api/saved-searches/(?P<saved_id>\d+)$", delete_saved_search),
    ("GET", r"^/api/alerts$", get_alerts),
    ("GET", r"^/api/pitchbooks$", get_pitchbooks),
    ("POST", r"^/api/pitchbooks$", post_pitchbook),
    ("GET", r"^/api/pitchbooks/(?P<pitchbook_id>\d+)$", get_pitchbook),
    ("DELETE", r"^/api/pitchbooks/(?P<pitchbook_id>\d+)$", delete_pitchbook),
    ("POST", r"^/api/pitchbooks/(?P<pitchbook_id>\d+)/rebuild$", post_rebuild),
    ("POST", r"^/api/pitchbooks/(?P<pitchbook_id>\d+)/comps$", post_comps),
    ("POST", r"^/api/pitchbooks/(?P<pitchbook_id>\d+)/assumptions$", post_assumptions),
    ("GET", r"^/api/pitchbooks/(?P<pitchbook_id>\d+)/valuation$", get_valuation),
    ("POST", r"^/api/pitchbooks/(?P<pitchbook_id>\d+)/evidence$", post_evidence),
    ("POST", r"^/api/pitchbooks/(?P<pitchbook_id>\d+)/reorder$", post_reorder),
    ("GET", r"^/api/pitchbooks/(?P<pitchbook_id>\d+)/export$", export_pitchbook),
    ("PATCH", r"^/api/slides/(?P<slide_id>\d+)$", patch_slide),
    ("POST", r"^/api/slides/(?P<slide_id>\d+)$", patch_slide),
    ("DELETE", r"^/api/evidence/(?P<evidence_id>\d+)$", delete_evidence),
    ("GET", r"^/api/pitchbooks/(?P<pitchbook_id>\d+)/preview$", get_pitchbook_preview),
    ("GET", r"^/api/pitchbooks/(?P<pitchbook_id>\d+)/valuation-charts$", get_valuation_chart),
    ("GET", r"^/api/companies/(?P<ticker>[A-Za-z0-9.\-]+)/charts$", get_company_charts),
    ("GET", r"^/api/dashboard-charts$", get_dashboard_charts),
    ("GET", r"^/api/export-formats$", get_export_formats),
)

INT_PARAMS = {"document_id", "pitchbook_id", "slide_id", "evidence_id", "watchlist_id", "saved_id"}
