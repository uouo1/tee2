"""The research search engine.

A query goes through four stages:

1. **Parse** — quoted phrases, ``-exclusions``, ``OR`` groups and field filters
   (``type:filing``, ``ticker:NVG``) are pulled out of the raw string.
2. **Expand** — each bare term optionally picks up lexicon synonyms, because the
   vocabulary gap between "guidance" and "outlook" is what makes naive search on
   filings feel broken.
3. **Rank** — BM25 from FTS5, re-weighted for recency and document type, so a
   two-year-old press release does not outrank last week's transcript.
4. **Present** — highlighted snippets, facet counts and an extractive summary of
   the top matches.
"""

from __future__ import annotations

import html
import math
import re
import sqlite3
import time
from dataclasses import dataclass, field
from datetime import date
from typing import Any, Sequence

from . import nlp
from .config import CONFIG
from .db import query

FIELD_RE = re.compile(r"\b(type|ticker|company|source|author|sentiment):(\"[^\"]+\"|\S+)", re.I)
TOKEN_RE = re.compile(r'"[^"]*"|\S+')

# Document types are weighted by how much signal analysts actually get from them.
DOC_TYPE_WEIGHT: dict[str, float] = {
    "transcript": 1.15,
    "filing": 1.10,
    "research": 1.05,
    "expert-call": 1.05,
    "investor-day": 1.0,
    "press-release": 0.92,
    "news": 0.90,
    "memo": 0.95,
}
HALF_LIFE_DAYS = 420.0


@dataclass
class ParsedQuery:
    """A raw query string decomposed into something executable."""

    raw: str = ""
    terms: list[str] = field(default_factory=list)       # bare terms (AND-ed)
    phrases: list[str] = field(default_factory=list)     # quoted phrases (AND-ed)
    or_groups: list[list[str]] = field(default_factory=list)
    excluded: list[str] = field(default_factory=list)
    fields: dict[str, str] = field(default_factory=dict)

    @property
    def is_empty(self) -> bool:
        return not (self.terms or self.phrases or self.or_groups)

    def all_terms(self) -> list[str]:
        out = list(self.terms) + list(self.phrases)
        for group in self.or_groups:
            out.extend(group)
        return out


def parse_query(raw: str) -> ParsedQuery:
    parsed = ParsedQuery(raw=(raw or "").strip())
    remainder = parsed.raw

    for match in FIELD_RE.finditer(parsed.raw):
        key = match.group(1).lower()
        value = match.group(2).strip('"')
        parsed.fields[key] = value
        remainder = remainder.replace(match.group(0), " ")

    tokens = [t for t in TOKEN_RE.findall(remainder) if t.strip()]
    i = 0
    while i < len(tokens):
        token = tokens[i]
        upper = token.upper()
        if upper in ("OR", "AND"):
            i += 1
            continue
        negated = token.startswith("-") and len(token) > 1
        clean = token[1:] if negated else token
        is_phrase = clean.startswith('"') and clean.endswith('"') and len(clean) > 2
        value = clean.strip('"').strip()
        if not value:
            i += 1
            continue
        if negated:
            parsed.excluded.append(value)
            i += 1
            continue
        # Look ahead for an explicit OR group: a OR b OR c
        if i + 2 < len(tokens) and tokens[i + 1].upper() == "OR":
            group = [value]
            j = i + 1
            while j + 1 < len(tokens) and tokens[j].upper() == "OR":
                group.append(tokens[j + 1].strip('"').strip())
                j += 2
            parsed.or_groups.append([g for g in group if g])
            i = j
            continue
        (parsed.phrases if is_phrase else parsed.terms).append(value)
        i += 1
    return parsed


def _fts_quote(value: str) -> str:
    """Quote a term/phrase for FTS5, neutralising embedded quotes and operators."""
    cleaned = re.sub(r'["*^]', " ", value).strip()
    cleaned = re.sub(r"\s+", " ", cleaned)
    return f'"{cleaned}"' if cleaned else ""


def build_match_expression(parsed: ParsedQuery, *, expand: bool = True) -> str:
    """Render a parsed query as an FTS5 MATCH expression."""
    clauses: list[str] = []

    for phrase in parsed.phrases:
        quoted = _fts_quote(phrase)
        if quoted:
            clauses.append(quoted)

    for term in parsed.terms:
        variants = nlp.expand_query_terms([term]) if expand else [term]
        quoted = [q for q in (_fts_quote(v) for v in variants) if q]
        if not quoted:
            continue
        clauses.append(quoted[0] if len(quoted) == 1 else "(" + " OR ".join(quoted) + ")")

    for group in parsed.or_groups:
        variants: list[str] = []
        for term in group:
            variants.extend(nlp.expand_query_terms([term]) if expand else [term])
        quoted = [q for q in (_fts_quote(v) for v in variants) if q]
        if quoted:
            clauses.append("(" + " OR ".join(quoted) + ")")

    expression = " AND ".join(clauses)
    excluded = [q for q in (_fts_quote(e) for e in parsed.excluded) if q]
    if expression and excluded:
        expression += " NOT " + " NOT ".join(excluded)
    return expression


def _recency_weight(published_at: str, today: date | None = None) -> float:
    try:
        published = date.fromisoformat(str(published_at)[:10])
    except ValueError:
        return 0.8
    days = max(0, ((today or date.today()) - published).days)
    return 0.55 + 0.45 * math.exp(-days / HALF_LIFE_DAYS)


def _highlight(raw_snippet: str) -> str:
    """Escape a snippet for HTML, then re-apply the FTS highlight markers."""
    escaped = html.escape(raw_snippet)
    escaped = escaped.replace("⦑", "<mark>").replace("⦒", "</mark>")
    return escaped.replace("\n", " ")


def _filter_sql(filters: dict[str, Any], parsed: ParsedQuery | None = None) -> tuple[str, list[Any]]:
    """Build the WHERE fragment shared by search and facet counting."""
    where: list[str] = []
    params: list[Any] = []
    fields = dict(parsed.fields) if parsed else {}
    merged: dict[str, Any] = {**fields, **{k: v for k, v in filters.items() if v not in (None, "", [])}}

    doc_type = merged.get("doc_type") or merged.get("type")
    if doc_type:
        types = doc_type if isinstance(doc_type, list) else [doc_type]
        where.append("d.doc_type IN (" + ",".join("?" for _ in types) + ")")
        params.extend(types)

    ticker = merged.get("ticker")
    if ticker:
        tickers = ticker if isinstance(ticker, list) else [ticker]
        where.append("c.ticker IN (" + ",".join("?" for _ in tickers) + ")")
        params.extend(t.upper() for t in tickers)

    company = merged.get("company")
    if company:
        where.append("c.name LIKE ?")
        params.append(f"%{company}%")

    sector = merged.get("sector")
    if sector:
        where.append("c.sector = ?")
        params.append(sector)

    source = merged.get("source")
    if source:
        where.append("d.source LIKE ?")
        params.append(f"%{source}%")

    author = merged.get("author")
    if author:
        where.append("d.author LIKE ?")
        params.append(f"%{author}%")

    if merged.get("date_from"):
        where.append("d.published_at >= ?")
        params.append(str(merged["date_from"])[:10])
    if merged.get("date_to"):
        where.append("d.published_at <= ?")
        params.append(str(merged["date_to"])[:10])

    sentiment = merged.get("sentiment")
    if sentiment == "positive":
        where.append("ch.sentiment >= 0.18")
    elif sentiment == "negative":
        where.append("ch.sentiment <= -0.18")
    elif sentiment == "neutral":
        where.append("ch.sentiment > -0.18 AND ch.sentiment < 0.18")

    if merged.get("min_document_id"):
        where.append("d.id > ?")
        params.append(int(merged["min_document_id"]))

    return (" AND ".join(where), params)


BASE_FROM = """
FROM chunks_fts f
JOIN chunks ch ON ch.id = f.rowid
JOIN documents d ON d.id = ch.document_id
LEFT JOIN companies c ON c.id = d.company_id
"""

BROWSE_FROM = """
FROM chunks ch
JOIN documents d ON d.id = ch.document_id
LEFT JOIN companies c ON c.id = d.company_id
"""


_CORPUS_CACHE: dict[int, tuple[int, nlp.Corpus]] = {}
CORPUS_SAMPLE = 1500


def corpus_stats(conn: sqlite3.Connection) -> nlp.Corpus:
    """Document-frequency stats for the corpus, cached per connection.

    tf-idf keywording is only as good as its idf: without corpus statistics,
    "adjusted" and "quarter" outrank "interconnection". The cache is invalidated
    whenever the document count changes, which is the cheap proxy for ingest.
    """
    key = id(conn)
    doc_count = int(conn.execute("SELECT COUNT(*) FROM documents").fetchone()[0])
    cached = _CORPUS_CACHE.get(key)
    if cached and cached[0] == doc_count:
        return cached[1]
    corpus = nlp.Corpus()
    for row in conn.execute(
        "SELECT body FROM documents ORDER BY published_at DESC LIMIT ?", (CORPUS_SAMPLE,)
    ):
        corpus.add(row[0])
    _CORPUS_CACHE[key] = (doc_count, corpus)
    return corpus


def search(
    conn: sqlite3.Connection,
    q: str = "",
    filters: dict[str, Any] | None = None,
    *,
    limit: int = 25,
    offset: int = 0,
    expand: bool = True,
    summarize: bool = True,
    today: date | None = None,
) -> dict[str, Any]:
    """Run a research query and return results, facets and a summary."""
    started = time.perf_counter()
    filters = dict(filters or {})
    parsed = parse_query(q)
    match_expr = build_match_expression(parsed, expand=expand)
    limit = max(1, min(int(limit), CONFIG.max_results))
    where_sql, where_params = _filter_sql(filters, parsed)

    select_cols = """
        ch.id AS chunk_id, ch.document_id, ch.seq, ch.speaker, ch.sentiment AS chunk_sentiment,
        d.title, d.doc_type, d.source, d.author, d.published_at, d.url,
        d.sentiment AS doc_sentiment, d.word_count,
        c.ticker, c.name AS company, c.sector
    """

    if match_expr:
        sql = f"""
        SELECT {select_cols},
               bm25(chunks_fts) AS bm25,
               snippet(chunks_fts, 0, char(10641), char(10642), '…', {CONFIG.snippet_tokens}) AS snip
        {BASE_FROM}
        WHERE chunks_fts MATCH ?
        """
        params: list[Any] = [match_expr]
        if where_sql:
            sql += f" AND {where_sql}"
            params.extend(where_params)
        sql += " ORDER BY bm25 LIMIT ?"
        params.append(min(limit * 6 + offset, 600))
        rows = query(conn, sql, params)
    else:
        # No query text: browse mode, newest first, filters still apply.
        sql = f"""
        SELECT {select_cols}, 0.0 AS bm25, substr(ch.text, 1, 320) AS snip
        {BROWSE_FROM}
        WHERE ch.seq = 0
        """
        params = []
        if where_sql:
            sql += f" AND {where_sql}"
            params.extend(where_params)
        sql += " ORDER BY d.published_at DESC, d.id DESC LIMIT ?"
        params.append(limit + offset)
        rows = query(conn, sql, params)

    scored: list[dict[str, Any]] = []
    seen_docs: dict[int, int] = {}
    for row in rows:
        base = -float(row["bm25"]) if match_expr else 1.0
        weight = DOC_TYPE_WEIGHT.get(row["doc_type"], 1.0) * _recency_weight(row["published_at"], today)
        row["score"] = round(base * weight, 4) if match_expr else 0.0
        row["snippet_html"] = _highlight(row.pop("snip") or "")
        row["sentiment_label"] = nlp.sentiment_label(float(row["chunk_sentiment"] or 0))
        # Collapse to the best-scoring passage per document, but remember how many
        # passages matched — "7 matching passages" is itself a research signal.
        doc_id = int(row["document_id"])
        if doc_id in seen_docs:
            scored[seen_docs[doc_id]]["match_count"] += 1
            continue
        row["match_count"] = 1
        seen_docs[doc_id] = len(scored)
        scored.append(row)

    if match_expr:
        scored.sort(key=lambda r: (-r["score"], r["published_at"]))
    else:
        # Browse mode is a reverse-chronological feed; relevance weighting there
        # would quietly reorder "newest first" into something else.
        scored.sort(key=lambda r: (r["published_at"], r["document_id"]), reverse=True)
    page = scored[offset:offset + limit]

    result: dict[str, Any] = {
        "query": q,
        "parsed": {
            "terms": parsed.terms, "phrases": parsed.phrases, "or_groups": parsed.or_groups,
            "excluded": parsed.excluded, "fields": parsed.fields,
        },
        "match_expression": match_expr,
        "expanded": expand and bool(match_expr),
        "total_documents": len(scored),
        "returned": len(page),
        "offset": offset,
        "results": page,
        "facets": facets(conn, parsed, filters, match_expr),
    }
    if summarize and page:
        result["summary"] = summarize_results(conn, page, parsed)
    result["took_ms"] = round((time.perf_counter() - started) * 1000, 1)
    return result


def facets(
    conn: sqlite3.Connection,
    parsed: ParsedQuery,
    filters: dict[str, Any],
    match_expr: str,
) -> dict[str, list[dict[str, Any]]]:
    """Facet counts over the documents that match the query and filters."""
    where_sql, where_params = _filter_sql(filters, parsed)
    if match_expr:
        source = f"""
        SELECT DISTINCT d.id, d.doc_type, d.published_at, d.sentiment, c.ticker, c.name AS company, c.sector
        {BASE_FROM}
        WHERE chunks_fts MATCH ?
        """
        params: list[Any] = [match_expr]
    else:
        source = f"""
        SELECT DISTINCT d.id, d.doc_type, d.published_at, d.sentiment, c.ticker, c.name AS company, c.sector
        {BROWSE_FROM}
        WHERE 1=1
        """
        params = []
    if where_sql:
        source += f" AND {where_sql}"
        params.extend(where_params)

    def group(column: str, label: str, limit: int = 12) -> list[dict[str, Any]]:
        sql = f"SELECT {column} AS value, COUNT(*) AS count FROM ({source}) WHERE {column} IS NOT NULL GROUP BY 1 ORDER BY count DESC, value LIMIT {limit}"
        return [{"label": label, "value": r["value"], "count": r["count"]} for r in query(conn, sql, params)]

    sentiment_sql = f"""
    SELECT CASE WHEN sentiment >= 0.18 THEN 'positive'
                WHEN sentiment <= -0.18 THEN 'negative'
                ELSE 'neutral' END AS value,
           COUNT(*) AS count
    FROM ({source}) GROUP BY 1 ORDER BY count DESC
    """
    year_sql = f"SELECT substr(published_at,1,4) AS value, COUNT(*) AS count FROM ({source}) GROUP BY 1 ORDER BY value DESC"
    return {
        "doc_type": group("doc_type", "Document type"),
        "ticker": group("ticker", "Company"),
        "sector": group("sector", "Sector"),
        "year": [{"label": "Year", "value": r["value"], "count": r["count"]} for r in query(conn, year_sql, params)],
        "sentiment": [{"label": "Sentiment", "value": r["value"], "count": r["count"]} for r in query(conn, sentiment_sql, params)],
    }


def summarize_results(
    conn: sqlite3.Connection,
    results: Sequence[dict[str, Any]],
    parsed: ParsedQuery,
    *,
    bullets: int = 5,
) -> dict[str, Any]:
    """Build a cited summary across the top hits.

    Each bullet keeps its document id so the UI (and the pitch book) can trace
    the claim back to a source — a summary without provenance is not usable in
    banker-facing material.
    """
    chunk_ids = [int(r["chunk_id"]) for r in results[:12]]
    if not chunk_ids:
        return {"bullets": [], "themes": [], "sentiment": 0.0}
    marks = ",".join("?" for _ in chunk_ids)
    rows = query(conn, f"""
        SELECT ch.id, ch.text, ch.sentiment, ch.speaker,
               d.id AS document_id, d.title, d.published_at, d.doc_type, c.ticker
        FROM chunks ch JOIN documents d ON d.id = ch.document_id
        LEFT JOIN companies c ON c.id = d.company_id
        WHERE ch.id IN ({marks})
    """, chunk_ids)
    by_id = {int(r["id"]): r for r in rows}
    terms = parsed.all_terms()

    picked: list[dict[str, Any]] = []
    seen_sentences: set[str] = set()
    for chunk_id in chunk_ids:
        row = by_id.get(chunk_id)
        if not row:
            continue
        # A question put by an analyst, or the operator's intro, is not a finding.
        if _is_boilerplate_speaker(row.get("speaker")):
            continue
        candidates = nlp.summarize(row["text"], limit=4, query_terms=terms) or [row["text"]]
        statements = [c for c in candidates if not c.rstrip().endswith("?")]
        # A fragment ("Competitive renewals.") is technically the top-ranked
        # sentence and useless as a finding, so require a clause's worth of words.
        substantial = [c for c in statements if len(c.split()) >= 8]
        sentence = (substantial or statements or candidates)[0] if (substantial or statements) else None
        if sentence is None:
            continue
        # Near-identical boilerplate across documents (the same risk-factor
        # paragraph, the same wire copy) would otherwise fill the summary with
        # one claim repeated five times.
        fingerprint = " ".join(sentence.lower().split())[:160]
        if fingerprint in seen_sentences:
            continue
        seen_sentences.add(fingerprint)
        picked.append({
            "text": sentence.strip()[:400],
            "document_id": row["document_id"],
            "title": row["title"],
            "ticker": row["ticker"],
            "doc_type": row["doc_type"],
            "published_at": row["published_at"],
            "chunk_id": chunk_id,
            "sentiment": round(float(row["sentiment"] or 0), 3),
        })
        if len(picked) >= bullets:
            break

    unique_texts: dict[str, str] = {}
    for chunk_id in chunk_ids:
        row = by_id.get(chunk_id)
        if row:
            unique_texts.setdefault(" ".join(row["text"].lower().split())[:200], row["text"])
    blob = " ".join(unique_texts.values())
    sentiments = [float(by_id[c]["sentiment"] or 0) for c in chunk_ids if c in by_id]
    return {
        "bullets": picked,
        "themes": [
            {"theme": t, "weight": round(w, 2)}
            for t, w in nlp.keywords(blob, corpus=corpus_stats(conn), limit=10)
        ],
        "sentiment": round(sum(sentiments) / len(sentiments), 3) if sentiments else 0.0,
        "sentiment_label": nlp.sentiment_label(sum(sentiments) / len(sentiments) if sentiments else 0.0),
    }


def _is_boilerplate_speaker(speaker: str | None) -> bool:
    if not speaker:
        return False
    lowered = speaker.lower()
    return any(word in lowered for word in ("operator", "analyst", "interviewer", "moderator"))


def get_document(conn: sqlite3.Connection, document_id: int, *, query_terms: Sequence[str] = ()) -> dict[str, Any] | None:
    """Full document view: metadata, chunks, extracted KPIs, summary, neighbours."""
    doc = query(conn, """
        SELECT d.*, c.ticker, c.name AS company, c.sector, c.industry
        FROM documents d LEFT JOIN companies c ON c.id = d.company_id
        WHERE d.id = ?
    """, (document_id,))
    if not doc:
        return None
    record = doc[0]
    record["chunks"] = query(conn, "SELECT id, seq, speaker, text, sentiment FROM chunks WHERE document_id = ? ORDER BY seq", (document_id,))
    for chunk in record["chunks"]:
        chunk["sentiment_label"] = nlp.sentiment_label(float(chunk["sentiment"] or 0))
    record["kpis"] = query(conn, "SELECT metric, value, unit, period, context, chunk_id FROM kpis WHERE document_id = ? ORDER BY metric", (document_id,))
    record["summary"] = nlp.summarize(record["body"], limit=5, query_terms=query_terms)
    record["keywords"] = [
        {"theme": t, "weight": round(w, 2)}
        for t, w in nlp.keywords(record["body"], corpus=corpus_stats(conn), limit=12)
    ]
    record["sentiment_label"] = nlp.sentiment_label(float(record["sentiment"] or 0))
    record["similar"] = similar_documents(conn, document_id, limit=5)
    return record


def similar_documents(conn: sqlite3.Connection, document_id: int, *, limit: int = 5) -> list[dict[str, Any]]:
    """Nearest neighbours by tf-idf cosine over document bodies.

    Scoped to the same sector (or same company when the document has no sector)
    to keep the candidate set small enough to score in-process.
    """
    target = query(conn, """
        SELECT d.id, d.body, d.company_id, c.sector
        FROM documents d LEFT JOIN companies c ON c.id = d.company_id WHERE d.id = ?
    """, (document_id,))
    if not target:
        return []
    target = target[0]
    if target["sector"]:
        candidates = query(conn, """
            SELECT d.id, d.title, d.body, d.doc_type, d.published_at, c.ticker
            FROM documents d LEFT JOIN companies c ON c.id = d.company_id
            WHERE d.id != ? AND (c.sector = ? OR c.sector IS NULL)
            ORDER BY d.published_at DESC LIMIT 400
        """, (document_id, target["sector"]))
    else:
        candidates = query(conn, """
            SELECT d.id, d.title, d.body, d.doc_type, d.published_at, c.ticker
            FROM documents d LEFT JOIN companies c ON c.id = d.company_id
            WHERE d.id != ? ORDER BY d.published_at DESC LIMIT 400
        """, (document_id,))

    corpus = corpus_stats(conn)
    target_vec = nlp.vector(target["body"], corpus)
    scored = []
    for row in candidates:
        score = nlp.cosine_similarity(target_vec, nlp.vector(row["body"], corpus))
        if score <= 0.02:
            continue
        scored.append({
            "document_id": row["id"], "title": row["title"], "doc_type": row["doc_type"],
            "published_at": row["published_at"], "ticker": row["ticker"], "similarity": round(score, 3),
        })
    scored.sort(key=lambda r: -r["similarity"])
    return scored[:limit]
