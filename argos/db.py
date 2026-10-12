"""SQLite storage for Argos.

One database backs both halves of the product: the research corpus (documents,
chunks, an FTS5 index, extracted KPIs) and the pitch book side (companies,
financials, comp sets, decks, slides, evidence). Keeping them together is what
makes "pin this quote onto slide 7" a single transaction rather than an
integration.
"""

from __future__ import annotations

import json
import sqlite3
from pathlib import Path
from typing import Any, Iterable, Sequence

from .config import CONFIG

SCHEMA = """
PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS companies (
    id            INTEGER PRIMARY KEY,
    ticker        TEXT NOT NULL UNIQUE,
    name          TEXT NOT NULL,
    sector        TEXT,
    industry      TEXT,
    country       TEXT,
    hq            TEXT,
    employees     INTEGER,
    currency      TEXT DEFAULT 'USD',
    description   TEXT,
    is_private    INTEGER DEFAULT 0
);

CREATE TABLE IF NOT EXISTS financials (
    id            INTEGER PRIMARY KEY,
    company_id    INTEGER NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
    fiscal_year   INTEGER NOT NULL,
    is_estimate   INTEGER DEFAULT 0,
    revenue       REAL,
    ebitda        REAL,
    ebit          REAL,
    net_income    REAL,
    eps           REAL,
    dep_amort     REAL,
    capex         REAL,
    nwc_change    REAL,
    tax_rate      REAL,
    UNIQUE (company_id, fiscal_year)
);

CREATE TABLE IF NOT EXISTS market_data (
    company_id      INTEGER PRIMARY KEY REFERENCES companies(id) ON DELETE CASCADE,
    as_of           TEXT,
    share_price     REAL,
    shares_diluted  REAL,
    net_debt        REAL,
    week52_low      REAL,
    week52_high     REAL,
    beta            REAL
);

CREATE TABLE IF NOT EXISTS documents (
    id            INTEGER PRIMARY KEY,
    external_id   TEXT UNIQUE,
    title         TEXT NOT NULL,
    company_id    INTEGER REFERENCES companies(id) ON DELETE SET NULL,
    doc_type      TEXT NOT NULL,
    source        TEXT,
    author        TEXT,
    published_at  TEXT NOT NULL,
    language      TEXT DEFAULT 'en',
    url           TEXT,
    sentiment     REAL DEFAULT 0,
    word_count    INTEGER DEFAULT 0,
    body          TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_documents_company ON documents(company_id);
CREATE INDEX IF NOT EXISTS idx_documents_type ON documents(doc_type);
CREATE INDEX IF NOT EXISTS idx_documents_date ON documents(published_at);

CREATE TABLE IF NOT EXISTS chunks (
    id            INTEGER PRIMARY KEY,
    document_id   INTEGER NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
    seq           INTEGER NOT NULL,
    speaker       TEXT,
    text          TEXT NOT NULL,
    sentiment     REAL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_chunks_document ON chunks(document_id);

CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts USING fts5(
    text,
    content='chunks',
    content_rowid='id',
    tokenize='porter unicode61'
);

CREATE TRIGGER IF NOT EXISTS chunks_ai AFTER INSERT ON chunks BEGIN
    INSERT INTO chunks_fts(rowid, text) VALUES (new.id, new.text);
END;
CREATE TRIGGER IF NOT EXISTS chunks_ad AFTER DELETE ON chunks BEGIN
    INSERT INTO chunks_fts(chunks_fts, rowid, text) VALUES('delete', old.id, old.text);
END;
CREATE TRIGGER IF NOT EXISTS chunks_au AFTER UPDATE ON chunks BEGIN
    INSERT INTO chunks_fts(chunks_fts, rowid, text) VALUES('delete', old.id, old.text);
    INSERT INTO chunks_fts(rowid, text) VALUES (new.id, new.text);
END;

CREATE TABLE IF NOT EXISTS kpis (
    id            INTEGER PRIMARY KEY,
    document_id   INTEGER NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
    chunk_id      INTEGER REFERENCES chunks(id) ON DELETE CASCADE,
    company_id    INTEGER REFERENCES companies(id) ON DELETE SET NULL,
    metric        TEXT NOT NULL,
    value         REAL,
    unit          TEXT,
    period        TEXT,
    context       TEXT
);

CREATE INDEX IF NOT EXISTS idx_kpis_company ON kpis(company_id, metric);

CREATE TABLE IF NOT EXISTS transactions (
    id              INTEGER PRIMARY KEY,
    announced_on    TEXT NOT NULL,
    target          TEXT NOT NULL,
    acquirer        TEXT NOT NULL,
    sector          TEXT,
    ev              REAL,
    ev_revenue      REAL,
    ev_ebitda       REAL,
    premium_1day    REAL,
    consideration   TEXT,
    note            TEXT
);

CREATE TABLE IF NOT EXISTS watchlists (
    id         INTEGER PRIMARY KEY,
    name       TEXT NOT NULL UNIQUE,
    created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS watchlist_items (
    watchlist_id INTEGER NOT NULL REFERENCES watchlists(id) ON DELETE CASCADE,
    company_id   INTEGER NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
    PRIMARY KEY (watchlist_id, company_id)
);

CREATE TABLE IF NOT EXISTS saved_searches (
    id         INTEGER PRIMARY KEY,
    name       TEXT NOT NULL,
    query      TEXT NOT NULL,
    filters    TEXT NOT NULL DEFAULT '{}',
    created_at TEXT NOT NULL,
    last_seen_document_id INTEGER DEFAULT 0
);

CREATE TABLE IF NOT EXISTS pitchbooks (
    id                INTEGER PRIMARY KEY,
    title             TEXT NOT NULL,
    subtitle          TEXT,
    client_name       TEXT,
    target_company_id INTEGER REFERENCES companies(id) ON DELETE SET NULL,
    banker            TEXT,
    status            TEXT DEFAULT 'draft',
    assumptions       TEXT NOT NULL DEFAULT '{}',
    created_at        TEXT NOT NULL,
    updated_at        TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS slides (
    id           INTEGER PRIMARY KEY,
    pitchbook_id INTEGER NOT NULL REFERENCES pitchbooks(id) ON DELETE CASCADE,
    seq          INTEGER NOT NULL,
    kind         TEXT NOT NULL,
    title        TEXT NOT NULL,
    subtitle     TEXT,
    payload      TEXT NOT NULL DEFAULT '{}',
    is_pinned    INTEGER DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_slides_book ON slides(pitchbook_id, seq);

CREATE TABLE IF NOT EXISTS comp_members (
    pitchbook_id INTEGER NOT NULL REFERENCES pitchbooks(id) ON DELETE CASCADE,
    company_id   INTEGER NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
    kind         TEXT NOT NULL DEFAULT 'trading',
    PRIMARY KEY (pitchbook_id, company_id, kind)
);

CREATE TABLE IF NOT EXISTS evidence (
    id           INTEGER PRIMARY KEY,
    pitchbook_id INTEGER NOT NULL REFERENCES pitchbooks(id) ON DELETE CASCADE,
    slide_id     INTEGER REFERENCES slides(id) ON DELETE SET NULL,
    document_id  INTEGER REFERENCES documents(id) ON DELETE SET NULL,
    chunk_id     INTEGER REFERENCES chunks(id) ON DELETE SET NULL,
    quote        TEXT NOT NULL,
    note         TEXT,
    created_at   TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_evidence_book ON evidence(pitchbook_id);
"""


def connect(db_path: Path | str | None = None) -> sqlite3.Connection:
    """Open a connection with row access by name and foreign keys enforced."""
    path = Path(db_path) if db_path else CONFIG.db_path
    if str(path) != ":memory:":
        path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(path), check_same_thread=False)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    return conn


def init_db(conn: sqlite3.Connection) -> sqlite3.Connection:
    """Create every table/index/trigger. Safe to call repeatedly."""
    conn.executescript(SCHEMA)
    conn.commit()
    return conn


def open_db(db_path: Path | str | None = None) -> sqlite3.Connection:
    return init_db(connect(db_path))


def rows_to_dicts(rows: Iterable[sqlite3.Row]) -> list[dict[str, Any]]:
    return [dict(row) for row in rows]


def query(conn: sqlite3.Connection, sql: str, params: Sequence[Any] = ()) -> list[dict[str, Any]]:
    return rows_to_dicts(conn.execute(sql, params).fetchall())


def query_one(conn: sqlite3.Connection, sql: str, params: Sequence[Any] = ()) -> dict[str, Any] | None:
    row = conn.execute(sql, params).fetchone()
    return dict(row) if row else None


def scalar(conn: sqlite3.Connection, sql: str, params: Sequence[Any] = (), default: Any = None) -> Any:
    row = conn.execute(sql, params).fetchone()
    if row is None or row[0] is None:
        return default
    return row[0]


def insert(conn: sqlite3.Connection, table: str, values: dict[str, Any]) -> int:
    """Insert a row from a dict and return its new id."""
    cols = ", ".join(values)
    marks = ", ".join("?" for _ in values)
    cur = conn.execute(f"INSERT INTO {table} ({cols}) VALUES ({marks})", list(values.values()))
    return int(cur.lastrowid)


def upsert_company(conn: sqlite3.Connection, company: dict[str, Any]) -> int:
    """Insert or update a company by ticker and return its id."""
    fields = (
        "ticker", "name", "sector", "industry", "country", "hq",
        "employees", "currency", "description", "is_private",
    )
    values = {k: company.get(k) for k in fields if k in company}
    existing = query_one(conn, "SELECT id FROM companies WHERE ticker = ?", (values["ticker"],))
    if existing:
        sets = ", ".join(f"{k} = ?" for k in values if k != "ticker")
        if sets:
            conn.execute(
                f"UPDATE companies SET {sets} WHERE id = ?",
                [v for k, v in values.items() if k != "ticker"] + [existing["id"]],
            )
        return int(existing["id"])
    return insert(conn, "companies", values)


def load_json(value: str | None, default: Any = None) -> Any:
    if not value:
        return {} if default is None else default
    try:
        return json.loads(value)
    except (TypeError, ValueError):
        return {} if default is None else default


def dump_json(value: Any) -> str:
    return json.dumps(value, separators=(",", ":"), default=str)
