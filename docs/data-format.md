# Loading your own corpus

`argos ingest <path>` accepts a file or a directory of `.json`, `.jsonl`, `.csv`,
`.txt` or `.md`. Each document is a flat record:

```json
{
  "external_id": "NVG-FY26Q2-call",
  "title": "NovaGrid Systems FY26 Q2 Earnings Call Transcript",
  "doc_type": "transcript",
  "ticker": "NVG",
  "company_name": "NovaGrid Systems",
  "source": "Company call",
  "author": "Investor Relations",
  "published_at": "2026-07-23",
  "url": "https://example.invalid/transcript",
  "period": "FY26 Q2",
  "body": "Operator: Good morning…\n\nAvery Lin, Chief Executive Officer: Revenue grew 16.8%…"
}
```

* **Required:** `title`, `doc_type`, `published_at`, `body`.
* **`external_id`** makes ingestion idempotent — re-running a load skips
  documents already present rather than duplicating them.
* **`ticker`** links the document to a company; with `company_name` a missing
  company is created.
* **`doc_type`** is free text; `transcript`, `filing`, `research`, `news`,
  `press-release`, `expert-call`, `investor-day` and `memo` carry ranking
  weights (transcripts and filings outrank wire copy).
* **`body`** is split on blank lines. A leading `Name, Title:` is captured as
  the speaker and removed from the passage text, so speaker names never pollute
  search snippets or theme extraction.

On ingest each document is scored for sentiment, chunked, indexed in FTS5 and
scanned for KPIs (growth rates, margins, net retention, churn, ARR, backlog,
headcount, free cash flow).

## Companies, financials and market data

Company fundamentals are not documents; load them directly:

```python
from argos.db import open_db, insert, upsert_company

conn = open_db("data/argos.db")
company_id = upsert_company(conn, {
    "ticker": "NVG", "name": "NovaGrid Systems", "sector": "Grid & Energy Software",
    "industry": "Grid orchestration software", "country": "United States",
    "hq": "Austin, TX", "employees": 4280, "currency": "USD", "description": "…",
})
insert(conn, "financials", {
    "company_id": company_id, "fiscal_year": 2026, "is_estimate": 0,
    "revenue": 1840.0, "ebitda": 482.1, "ebit": 386.4, "net_income": 283.0,
    "eps": 1.55, "dep_amort": 95.7, "capex": 75.4, "nwc_change": 22.1, "tax_rate": 0.23,
})
insert(conn, "market_data", {
    "company_id": company_id, "as_of": "2026-10-09", "share_price": 44.10,
    "shares_diluted": 182.0, "net_debt": 410.0,
    "week52_low": 31.78, "week52_high": 50.74, "beta": 1.21,
})
conn.commit()
```

Amounts are in millions of the reporting currency; per-share figures are
absolute; rates are decimals. Precedent transactions go in the `transactions`
table with `ev_revenue`, `ev_ebitda` and `premium_1day`.
