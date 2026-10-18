# HTTP API

Every endpoint returns JSON unless noted. The server is the Rails application
(`bin/rails server`, default `http://127.0.0.1:3000`); the retired Python
reference served the same paths from `python3 -m argos serve` on port 8787.

**There is no authentication.** The API is meant for a single analyst's
machine or a trusted network; put it behind a proxy before exposing it.
Unmatched `/api` paths answer in JSON (404, or 405 with the allowed verbs).

Valuation payloads carry the audited keys (docs/AUDIT.md): `basis_label`,
`ltm`, `ntm`, `ev_bridge`, `net_debt_as_of`, `other_claims`, `debt_note` on a
company's metrics; `wacc`, `dcf_note`, `ranges[].in_conclusion/reference/note`
and `concluded_range.methods` on a valuation. A value that is unknown is
`null`, never `0`.

## Research

| Method | Path | Notes |
|---|---|---|
| GET | `/api/health` | Status, document count, available export formats |
| GET | `/api/overview` | Dashboard payload: counts, coverage, tone, trending themes |
| GET | `/api/search` | `q`, repeated `doc_type`/`ticker`, `company`, `sector`, `source`, `author`, `sentiment`, `date_from`, `date_to`, `limit`, `offset`, `expand`, `summarize`. `total_documents` is the true document count and agrees with the facets. |
| GET | `/api/documents/{id}` | Full document: chunks, KPIs, summary, keywords, similar documents |
| GET | `/api/companies` | Company list with market data and coverage counts |
| GET | `/api/companies/{ticker}` | Profile: financials, KPIs, tone timeline, themes, multiples |
| GET | `/api/companies/{ticker}/charts` | Server-rendered SVG (revenue, margin, tone, volume) |
| GET | `/api/companies/{ticker}/suggest-comps` | Sector + size-ranked comparable suggestions |
| GET | `/api/trends` | `ticker`, `window_days`, `months`, `limit` |
| GET | `/api/dashboard-charts` | Server-rendered SVG for the dashboard |
| GET | `/api/transactions` | Precedent transactions with multiple/premium statistics |
| POST | `/api/ingest` | `{"documents": [...]}` or `{"path": "seed"}`. A `path` is resolved under the application's `data/` directory (symlinks followed): anything outside it is a 400, a missing path a 404. |
| POST | `/api/seed` | Load the synthetic demo dataset |

### Query syntax

`"quoted phrase"`, `-excluded`, `a OR b`, and the field filters `type:`,
`ticker:`, `company:`, `source:`, `author:`, `sentiment:` and `date:`
(`date:2026`, `date:2026-07`, `date:2026-01-01..2026-06-30`). A field given
several times keeps every value (`ticker:ITRI ticker:BMI` matches both). With
`expand=1` (default) bare terms also match lexicon synonyms — `guidance`
matches `outlook`.

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


## Rake tasks

The command line is `bin/rails "<task>[args]"`: quote the whole task for the
shell, separate arguments with commas, and separate the tickers of one list
with spaces (rake splits on commas). Surrounding quotes inside the brackets
are stripped. Flags are environment variables.

| Task | Notes |
|---|---|
| `argos:seed` | Load the synthetic demo dataset (idempotent) |
| `argos:ingest[path]` | Ingest a file or directory of documents |
| `argos:load_sec[ITRI BMI XYL,sector]` | Load real companies from EDGAR: financials (FY and LTM), consensus estimates and beta, latest balance sheet, quote, filings. `years=`, `annual=`, `quarterly=`, `press_releases=`, `no_documents=1` |
| `argos:load_estimates[ITRI BMI]` | Refresh consensus rows and beta for loaded companies (all of them with no argument) |
| `argos:load_transactions[path]` | Precedent transactions from a CSV (`docs/precedent-transactions-template.csv`) |
| `argos:search[query,limit]` | Run a research query; `json=1` prints JSON, `no_expand=1` disables synonyms |
| `argos:pitchbook[ticker,title,BMI XYL,format]` | Build a deck; `client=`, `banker=`, `out=` |
| `argos:export[id,format,out]` | Export an existing deck (html, pdf, pptx) |
| `argos:stats` | Corpus statistics as JSON |

Environment variables the tasks and the server honour: `ARGOS_DB` (another
SQLite file for the development app, e.g. `storage/real.sqlite3` for a real
corpus next to the demo; create it empty with `bin/rails db:schema:load`),
`ARGOS_TEST_DB` (the same for the test environment), `ARGOS_HTTP_CACHE`
(download cache, default `data/cache`), `ARGOS_EXPORT_DIR` (default
`data/exports`; tests write under `tmp/exports`) and `ARGOS_USER_AGENT` (the
SEC asks automated clients to identify themselves).

Saved searches return `filters` as a JSON object (the Python reference returned
the stored text).
