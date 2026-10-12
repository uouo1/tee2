# HTTP API

Every endpoint returns JSON unless noted. The server is `python3 -m argos serve`
(default `http://127.0.0.1:8787`).

## Research

| Method | Path | Notes |
|---|---|---|
| GET | `/api/health` | Status, document count, available export formats |
| GET | `/api/overview` | Dashboard payload: counts, coverage, tone, trending themes |
| GET | `/api/search` | `q`, repeated `doc_type`/`ticker`, `company`, `sector`, `source`, `author`, `sentiment`, `date_from`, `date_to`, `limit`, `offset`, `expand`, `summarize` |
| GET | `/api/documents/{id}` | Full document: chunks, KPIs, summary, keywords, similar documents |
| GET | `/api/companies` | Company list with market data and coverage counts |
| GET | `/api/companies/{ticker}` | Profile: financials, KPIs, tone timeline, themes, multiples |
| GET | `/api/companies/{ticker}/charts` | Server-rendered SVG (revenue, margin, tone, volume) |
| GET | `/api/companies/{ticker}/suggest-comps` | Sector + size-ranked comparable suggestions |
| GET | `/api/trends` | `ticker`, `window_days`, `months`, `limit` |
| GET | `/api/dashboard-charts` | Server-rendered SVG for the dashboard |
| GET | `/api/transactions` | Precedent transactions with multiple/premium statistics |
| POST | `/api/ingest` | `{"documents": [...]}` or `{"path": "/corpus"}` |
| POST | `/api/seed` | Load the synthetic demo dataset |

### Query syntax

`"quoted phrase"`, `-excluded`, `a OR b`, and the field filters `type:`,
`ticker:`, `company:`, `source:`, `author:`, `sentiment:`. With `expand=1`
(default) bare terms also match lexicon synonyms — `guidance` matches `outlook`.

## Monitoring

| Method | Path | Notes |
|---|---|---|
| GET/POST | `/api/watchlists` | `{"name": ..., "tickers": [...]}` |
| POST | `/api/watchlists/{id}/items` | `{"tickers": [...]}` |
| DELETE | `/api/watchlists/{id}/items/{ticker}` | |
| DELETE | `/api/watchlists/{id}` | |
| GET/POST | `/api/saved-searches` | `{"name", "query", "filters"}` |
| DELETE | `/api/saved-searches/{id}` | |
| GET | `/api/alerts` | `mark_seen=1` acknowledges what it returns |

## Pitch books

| Method | Path | Notes |
|---|---|---|
| GET | `/api/pitchbooks` | Index plus available export formats |
| POST | `/api/pitchbooks` | `{"target_ticker", "title", "client_name", "banker", "comp_tickers", "assumptions"}` |
| GET/DELETE | `/api/pitchbooks/{id}` | Full deck with slides, comps and evidence |
| POST | `/api/pitchbooks/{id}/rebuild` | Regenerate unpinned slides from current data |
| POST | `/api/pitchbooks/{id}/comps` | `{"tickers": [...]}`, then rebuilds |
| POST | `/api/pitchbooks/{id}/assumptions` | Partial DCF overrides, then rebuilds |
| GET | `/api/pitchbooks/{id}/valuation` | Football field, comps, precedents, DCF, sensitivity |
| GET | `/api/pitchbooks/{id}/valuation-charts` | The same, pre-rendered as SVG/HTML |
| GET | `/api/pitchbooks/{id}/preview` | Deck markup for embedding |
| GET | `/api/pitchbooks/{id}/export` | `format=html\|pptx\|pdf`; `download=0` returns metadata instead of the file |
| POST | `/api/pitchbooks/{id}/evidence` | `{"quote", "document_id", "chunk_id", "slide_id", "note"}` |
| POST | `/api/pitchbooks/{id}/reorder` | `{"slide_ids": [...]}` |
| PATCH/POST | `/api/slides/{id}` | `{"title", "subtitle", "payload", "pin"}` — editing pins the slide |
| DELETE | `/api/evidence/{id}` | |

## Errors

Failures return `{"error": "..."}` with 400 (bad input), 404 (missing), 405
(wrong method), 413 (body too large) or 500.
