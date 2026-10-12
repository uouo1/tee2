"""Aggregations that sit on top of the corpus: profiles, trends, alerts.

These are the views an analyst opens before they search for anything — what has
changed, which companies are talking about what, and whether the tone of a name
is drifting. They are also the inputs the pitch book generator reads when it
writes the market-overview and executive-summary slides.
"""

from __future__ import annotations

import json
import sqlite3
from datetime import date, timedelta
from typing import Any

from . import nlp, search
from .db import query, query_one, scalar

KPI_LABELS: dict[str, str] = {
    "revenue_growth": "Revenue growth",
    "revenue_decline": "Revenue decline",
    "gross_margin": "Gross margin",
    "ebitda_margin": "EBITDA margin",
    "operating_margin": "Operating margin",
    "net_retention": "Net dollar retention",
    "churn": "Churn",
    "arr": "ARR",
    "backlog": "Backlog / RPO",
    "headcount": "Headcount",
    "free_cash_flow": "Free cash flow",
    "capex_intensity": "Capex intensity",
}


def _latest_corpus_date(conn: sqlite3.Connection) -> date:
    raw = scalar(conn, "SELECT MAX(published_at) FROM documents")
    try:
        return date.fromisoformat(str(raw)[:10])
    except (TypeError, ValueError):
        return date.today()


def overview(conn: sqlite3.Connection) -> dict[str, Any]:
    """Landing-page state: corpus size, coverage, tone, what is new."""
    as_of = _latest_corpus_date(conn)
    return {
        "as_of": as_of.isoformat(),
        "counts": {
            "documents": scalar(conn, "SELECT COUNT(*) FROM documents", default=0),
            "chunks": scalar(conn, "SELECT COUNT(*) FROM chunks", default=0),
            "companies": scalar(conn, "SELECT COUNT(*) FROM companies", default=0),
            "kpis": scalar(conn, "SELECT COUNT(*) FROM kpis", default=0),
            "pitchbooks": scalar(conn, "SELECT COUNT(*) FROM pitchbooks", default=0),
            "transactions": scalar(conn, "SELECT COUNT(*) FROM transactions", default=0),
        },
        "by_type": query(conn, "SELECT doc_type AS value, COUNT(*) AS count FROM documents GROUP BY 1 ORDER BY count DESC"),
        "coverage": query(conn, """
            SELECT c.ticker, c.name, c.sector, COUNT(d.id) AS documents,
                   ROUND(AVG(d.sentiment), 3) AS sentiment,
                   MAX(d.published_at) AS latest
            FROM companies c LEFT JOIN documents d ON d.company_id = c.id
            GROUP BY c.id ORDER BY documents DESC
        """),
        "recent": query(conn, """
            SELECT d.id, d.title, d.doc_type, d.published_at, d.sentiment, c.ticker
            FROM documents d LEFT JOIN companies c ON c.id = d.company_id
            ORDER BY d.published_at DESC, d.id DESC LIMIT 8
        """),
        "sentiment": {
            "mean": round(float(scalar(conn, "SELECT AVG(sentiment) FROM documents", default=0.0) or 0.0), 3),
            "distribution": query(conn, """
                SELECT CASE WHEN sentiment >= 0.18 THEN 'positive'
                            WHEN sentiment <= -0.18 THEN 'negative'
                            ELSE 'neutral' END AS value,
                       COUNT(*) AS count
                FROM documents GROUP BY 1
            """),
        },
        "trending": trending_themes(conn, window_days=180)["themes"][:8],
    }


def sentiment_timeline(conn: sqlite3.Connection, *, ticker: str | None = None, months: int = 24) -> list[dict[str, Any]]:
    """Mean document sentiment by month, with volume, for a diverging bar chart."""
    as_of = _latest_corpus_date(conn)
    cutoff = (as_of - timedelta(days=int(months * 30.44))).isoformat()
    params: list[Any] = [cutoff]
    where = "d.published_at >= ?"
    if ticker:
        where += " AND c.ticker = ?"
        params.append(ticker.upper())
    return query(conn, f"""
        SELECT substr(d.published_at, 1, 7) AS month,
               ROUND(AVG(d.sentiment), 4) AS sentiment,
               COUNT(*) AS documents
        FROM documents d LEFT JOIN companies c ON c.id = d.company_id
        WHERE {where}
        GROUP BY month ORDER BY month
    """, params)


def volume_by_type(conn: sqlite3.Connection, *, ticker: str | None = None, months: int = 24) -> dict[str, Any]:
    as_of = _latest_corpus_date(conn)
    cutoff = (as_of - timedelta(days=int(months * 30.44))).isoformat()
    params: list[Any] = [cutoff]
    where = "d.published_at >= ?"
    if ticker:
        where += " AND c.ticker = ?"
        params.append(ticker.upper())
    rows = query(conn, f"""
        SELECT substr(d.published_at, 1, 7) AS month, d.doc_type, COUNT(*) AS count
        FROM documents d LEFT JOIN companies c ON c.id = d.company_id
        WHERE {where}
        GROUP BY month, d.doc_type ORDER BY month
    """, params)
    months_seen = sorted({r["month"] for r in rows})
    types = sorted({r["doc_type"] for r in rows})
    index = {(r["month"], r["doc_type"]): r["count"] for r in rows}
    return {
        "months": months_seen,
        "series": [
            {"name": doc_type, "values": [index.get((m, doc_type), 0) for m in months_seen]}
            for doc_type in types
        ],
    }


def trending_themes(
    conn: sqlite3.Connection, *, window_days: int = 120, ticker: str | None = None, limit: int = 12
) -> dict[str, Any]:
    """Themes over-represented in the trailing window versus the period before it."""
    as_of = _latest_corpus_date(conn)
    recent_cutoff = (as_of - timedelta(days=window_days)).isoformat()
    base_cutoff = (as_of - timedelta(days=window_days * 3)).isoformat()
    where = ""
    params_tail: list[Any] = []
    if ticker:
        where = " AND c.ticker = ?"
        params_tail.append(ticker.upper())

    # Chunk text rather than the raw body: chunks have speaker attribution split
    # off, so "Dana Okafor, Chief Financial Officer:" cannot surface as a theme.
    recent = [r["text"] for r in query(conn, f"""
        SELECT GROUP_CONCAT(ch.text, ' ') AS text
        FROM documents d JOIN chunks ch ON ch.document_id = d.id
        LEFT JOIN companies c ON c.id = d.company_id
        WHERE d.published_at >= ?{where} GROUP BY d.id
    """, [recent_cutoff, *params_tail]) if r["text"]]
    baseline = [r["text"] for r in query(conn, f"""
        SELECT GROUP_CONCAT(ch.text, ' ') AS text
        FROM documents d JOIN chunks ch ON ch.document_id = d.id
        LEFT JOIN companies c ON c.id = d.company_id
        WHERE d.published_at >= ? AND d.published_at < ?{where} GROUP BY d.id
    """, [base_cutoff, recent_cutoff, *params_tail]) if r["text"]]

    themes = nlp.theme_trends(recent, baseline, limit=limit)
    return {
        "as_of": as_of.isoformat(),
        "window_days": window_days,
        "recent_documents": len(recent),
        "baseline_documents": len(baseline),
        "themes": themes,
    }


def company_profile(conn: sqlite3.Connection, ticker: str) -> dict[str, Any] | None:
    """Everything known about one company, research and financials together."""
    company = query_one(conn, "SELECT * FROM companies WHERE ticker = ?", (ticker.upper(),))
    if not company:
        return None
    company_id = company["id"]
    company["financials"] = query(conn, "SELECT * FROM financials WHERE company_id = ? ORDER BY fiscal_year", (company_id,))
    company["market_data"] = query_one(conn, "SELECT * FROM market_data WHERE company_id = ?", (company_id,)) or {}
    company["document_count"] = scalar(conn, "SELECT COUNT(*) FROM documents WHERE company_id = ?", (company_id,), default=0)
    company["sentiment"] = round(float(scalar(conn, "SELECT AVG(sentiment) FROM documents WHERE company_id = ?", (company_id,), default=0.0) or 0.0), 3)
    company["sentiment_label"] = nlp.sentiment_label(company["sentiment"])
    company["documents"] = query(conn, """
        SELECT id, title, doc_type, source, published_at, sentiment
        FROM documents WHERE company_id = ? ORDER BY published_at DESC LIMIT 25
    """, (company_id,))
    company["kpis"] = kpi_series(conn, ticker)
    company["sentiment_timeline"] = sentiment_timeline(conn, ticker=ticker)
    company["themes"] = trending_themes(conn, ticker=ticker, limit=8)["themes"]
    company["metrics"] = valuation_snapshot(conn, ticker)
    return company


def kpi_series(conn: sqlite3.Connection, ticker: str) -> list[dict[str, Any]]:
    """Extracted KPIs for a company, newest value per metric plus history."""
    rows = query(conn, """
        SELECT k.metric, k.value, k.unit, k.period, k.context, k.document_id, d.published_at, d.title
        FROM kpis k JOIN documents d ON d.id = k.document_id
        JOIN companies c ON c.id = k.company_id
        WHERE c.ticker = ? ORDER BY k.metric, d.published_at
    """, (ticker.upper(),))
    grouped: dict[str, dict[str, Any]] = {}
    for row in rows:
        bucket = grouped.setdefault(row["metric"], {
            "metric": row["metric"],
            "label": KPI_LABELS.get(row["metric"], row["metric"].replace("_", " ").title()),
            "unit": row["unit"],
            "points": [],
        })
        bucket["points"].append({
            "period": row["period"], "published_at": row["published_at"],
            "value": row["value"], "document_id": row["document_id"],
            "title": row["title"], "context": row["context"],
        })
    for bucket in grouped.values():
        bucket["points"].sort(key=lambda p: str(p["published_at"]))
        bucket["latest"] = bucket["points"][-1]["value"] if bucket["points"] else None
        bucket["observations"] = len(bucket["points"])
    return sorted(grouped.values(), key=lambda b: (-b["observations"], b["metric"]))


def valuation_snapshot(conn: sqlite3.Connection, ticker: str) -> dict[str, Any]:
    """Market multiples for one company off the latest actual fiscal year."""
    from .valuation import company_metrics  # local import: valuation imports nothing from here

    metrics = company_metrics(conn, ticker)
    return metrics or {}


def check_alerts(conn: sqlite3.Connection, *, mark_seen: bool = False) -> list[dict[str, Any]]:
    """Re-run every saved search and report documents newer than last seen.

    This is the "alert" half of a research platform: a saved search is only
    useful if it tells you what arrived since you last looked.
    """
    alerts: list[dict[str, Any]] = []
    for saved in query(conn, "SELECT * FROM saved_searches ORDER BY id"):
        try:
            filters = json.loads(saved["filters"] or "{}")
        except ValueError:
            filters = {}
        filters = {**filters, "min_document_id": saved["last_seen_document_id"] or 0}
        result = search.search(conn, saved["query"], filters, limit=10, summarize=False)
        hits = result["results"]
        newest = max((int(r["document_id"]) for r in hits), default=saved["last_seen_document_id"] or 0)
        alerts.append({
            "saved_search_id": saved["id"],
            "name": saved["name"],
            "query": saved["query"],
            "new_documents": len(hits),
            "hits": hits,
        })
        if mark_seen and hits:
            conn.execute("UPDATE saved_searches SET last_seen_document_id = ? WHERE id = ?", (newest, saved["id"]))
    if mark_seen:
        conn.commit()
    return alerts
