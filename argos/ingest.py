"""Corpus ingestion: documents in, searchable + scored chunks out.

Accepts a dict per document (from JSON/JSONL/CSV, an API, or the demo seeder),
splits it into retrieval-sized chunks, scores sentiment per chunk, extracts KPIs
and writes everything in one transaction so the FTS index can never drift from
the documents table.
"""

from __future__ import annotations

import csv
import json
import re
import sqlite3
from pathlib import Path
from typing import Any, Iterable, Iterator

from . import nlp
from .db import insert, query_one, upsert_company

DOC_TYPES = (
    "transcript",
    "filing",
    "research",
    "news",
    "press-release",
    "expert-call",
    "investor-day",
    "memo",
)

SPEAKER_RE = re.compile(r"^(?P<speaker>[A-Z][\w.'-]*(?: [A-Z][\w.'-]*){0,3}(?:, [^:]{3,40})?):\s*(?P<body>.+)$", re.S)
MIN_CHUNK_CHARS = 180
MAX_CHUNK_CHARS = 1400


def split_paragraphs(body: str) -> list[str]:
    parts = [p.strip() for p in re.split(r"\n\s*\n+", body or "") if p.strip()]
    return parts or ([body.strip()] if (body or "").strip() else [])


def chunk_body(body: str) -> list[dict[str, Any]]:
    """Paragraph-aware chunking with speaker attribution for transcripts.

    Short paragraphs are glued to their neighbour (an "Operator: next question"
    line is noise on its own) and very long ones are split on sentence
    boundaries so a snippet always has usable context.
    """
    chunks: list[dict[str, Any]] = []
    pending: dict[str, Any] | None = None

    def flush() -> None:
        nonlocal pending
        if pending and pending["text"].strip():
            chunks.append(pending)
        pending = None

    for para in split_paragraphs(body):
        match = SPEAKER_RE.match(para)
        speaker = match.group("speaker").strip() if match else None
        text = match.group("body").strip() if match else para

        if len(text) > MAX_CHUNK_CHARS:
            flush()
            buffer = ""
            for sentence in nlp.sentences(text) or [text]:
                if buffer and len(buffer) + len(sentence) > MAX_CHUNK_CHARS:
                    chunks.append({"speaker": speaker, "text": buffer.strip()})
                    buffer = ""
                buffer = f"{buffer} {sentence}".strip()
            if buffer:
                chunks.append({"speaker": speaker, "text": buffer.strip()})
            continue

        if pending and (len(pending["text"]) < MIN_CHUNK_CHARS) and pending.get("speaker") == speaker:
            pending["text"] = f"{pending['text']} {text}".strip()
            continue
        flush()
        pending = {"speaker": speaker, "text": text}
    flush()
    return chunks


def ingest_document(conn: sqlite3.Connection, doc: dict[str, Any], *, commit: bool = True) -> int | None:
    """Insert one document plus its chunks and KPIs. Returns the document id.

    Returns ``None`` when ``external_id`` already exists, which makes repeated
    ingest runs idempotent instead of duplicating a corpus.
    """
    required = ("title", "doc_type", "published_at", "body")
    missing = [k for k in required if not doc.get(k)]
    if missing:
        raise ValueError(f"document missing required field(s): {', '.join(missing)}")

    external_id = doc.get("external_id")
    if external_id:
        existing = query_one(conn, "SELECT id FROM documents WHERE external_id = ?", (external_id,))
        if existing:
            return None

    company_id = doc.get("company_id")
    if company_id is None and doc.get("ticker"):
        company = query_one(conn, "SELECT id FROM companies WHERE ticker = ?", (doc["ticker"].upper(),))
        if company:
            company_id = company["id"]
        elif doc.get("company_name"):
            company_id = upsert_company(conn, {"ticker": doc["ticker"].upper(), "name": doc["company_name"]})

    body = doc["body"]
    document_id = insert(conn, "documents", {
        "external_id": external_id,
        "title": doc["title"],
        "company_id": company_id,
        "doc_type": doc["doc_type"],
        "source": doc.get("source"),
        "author": doc.get("author"),
        "published_at": str(doc["published_at"])[:10],
        "language": doc.get("language", "en"),
        "url": doc.get("url"),
        "sentiment": round(nlp.score_sentiment(body), 4),
        "word_count": len(nlp.tokenize(body)),
        "body": body,
    })

    for seq, chunk in enumerate(chunk_body(body)):
        chunk_id = insert(conn, "chunks", {
            "document_id": document_id,
            "seq": seq,
            "speaker": chunk.get("speaker"),
            "text": chunk["text"],
            "sentiment": round(nlp.score_sentiment(chunk["text"]), 4),
        })
        for kpi in nlp.extract_kpis(chunk["text"]):
            insert(conn, "kpis", {
                "document_id": document_id,
                "chunk_id": chunk_id,
                "company_id": company_id,
                "metric": kpi["metric"],
                "value": kpi["value"],
                "unit": kpi["unit"],
                "period": doc.get("period") or str(doc["published_at"])[:7],
                "context": kpi["context"][:600],
            })

    if commit:
        conn.commit()
    return document_id


def ingest_many(conn: sqlite3.Connection, docs: Iterable[dict[str, Any]]) -> dict[str, int]:
    added = skipped = 0
    for doc in docs:
        if ingest_document(conn, doc, commit=False) is None:
            skipped += 1
        else:
            added += 1
    conn.commit()
    return {"added": added, "skipped": skipped}


def read_documents(path: Path) -> Iterator[dict[str, Any]]:
    """Read documents from .json (list or {documents: [...]}), .jsonl, .csv or .txt."""
    suffix = path.suffix.lower()
    if suffix == ".jsonl":
        with path.open(encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if line:
                    yield json.loads(line)
    elif suffix == ".json":
        payload = json.loads(path.read_text(encoding="utf-8"))
        rows = payload.get("documents", []) if isinstance(payload, dict) else payload
        yield from rows
    elif suffix == ".csv":
        with path.open(encoding="utf-8", newline="") as handle:
            yield from csv.DictReader(handle)
    elif suffix in (".txt", ".md"):
        yield {
            "title": path.stem.replace("_", " ").title(),
            "doc_type": "memo",
            "published_at": "1970-01-01",
            "source": path.name,
            "body": path.read_text(encoding="utf-8"),
        }
    else:
        raise ValueError(f"unsupported corpus file type: {path.name}")


def ingest_path(conn: sqlite3.Connection, path: Path) -> dict[str, int]:
    """Ingest a single corpus file or every corpus file in a directory."""
    paths = sorted(p for p in path.rglob("*") if p.is_file()) if path.is_dir() else [path]
    totals = {"added": 0, "skipped": 0, "files": 0}
    for candidate in paths:
        if candidate.suffix.lower() not in (".json", ".jsonl", ".csv", ".txt", ".md"):
            continue
        if candidate.name.startswith("companies") or candidate.name.startswith("transactions"):
            continue  # reference data, loaded by the seeder
        result = ingest_many(conn, read_documents(candidate))
        totals["added"] += result["added"]
        totals["skipped"] += result["skipped"]
        totals["files"] += 1
    return totals
