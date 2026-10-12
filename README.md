# Argos — research intelligence and pitch books in one application

Argos is two products that are usually bought separately, built as one:

* a **research terminal** over a corpus of filings, transcripts, broker notes,
  news and expert calls — ranked search, facets, sentiment, extracted KPIs,
  emerging themes, saved-search alerts; and
* a **pitch book generator** — trading comparables, precedent transactions, a
  DCF with sensitivity, a football field valuation and a fourteen-slide deck
  that exports to PowerPoint, PDF or HTML.

They share one database, which is the point. A passage you find in a transcript
can be pinned onto a deck and stays traceable to its document; the executive
summary quotes the corpus with citations; the market overview slide *is* the
trending-theme model. Change a comp set or a WACC and the deck rebuilds.

Everything runs locally on the Python standard library — no framework, no
service, no API key, no network call. The two optional dependencies only widen
the export menu.

## Quick start

```bash
git clone <this repo> && cd tee2
./run.sh                      # seeds the demo corpus on first run, then serves
```

Open <http://127.0.0.1:8787>. Or step by step:

```bash
python3 -m argos seed         # 116 synthetic documents, 7 companies, 6 precedent deals
python3 -m argos serve        # the web application
```

Optional, for PowerPoint and PDF export:

```bash
pip install -r requirements.txt
```

Requires Python 3.11 or newer. Nothing else is needed for search, valuation,
the web UI or HTML export.

## The two halves

### Research

Search understands `"quoted phrases"`, `-exclusions`, `a OR b` and field
filters (`type:transcript`, `ticker:NVG`). Bare terms are expanded through a
finance lexicon, so *guidance* also matches *outlook* and *forecast* — the
vocabulary gap between how analysts ask and how filings are written is the most
common reason naive search returns nothing.

Results are BM25 ranked, then re-weighted for recency and document type, and
collapsed to the best passage per document (with a count of how many other
passages matched). Each result set comes with a cited summary of the top
matches, facet counts across type, company, sector, year and tone, and a reader
that shows extracted metrics, per-passage sentiment and nearest-neighbour
documents.

```bash
python3 -m argos search "pricing pressure" --limit 5
python3 -m argos search 'ticker:NVG "interconnection queue"' --json
```

### Pitch books

```bash
python3 -m argos pitchbook NVG --title "Project Lighthouse" \
    --client "Board of NovaGrid Systems" --export pptx
```

Fourteen slides: cover, disclaimer, executive summary, company overview, market
overview, financial performance, valuation summary (football field), trading
comparables, precedent transactions, DCF, DCF sensitivity, potential
counterparties, process considerations, and an evidence appendix built from
whatever you pinned.

The valuation stack is explicit rather than hand-waved: multiples come from the
latest *actual* fiscal year, EV bridges through net debt, the DCF discounts
unlevered free cash flow with a mid-year convention and either Gordon growth or
an exit multiple, and the concluded range is the median low and median high
across methodologies — so one wide methodology cannot dictate the answer.
Edit any slide and it is pinned: a rebuild regenerates everything around your
wording without overwriting it.

## How it fits together

```
documents ──ingest──▶ chunks ──FTS5──▶ search ──▶ summaries, themes, KPIs
                                         │                    │
companies, financials, market data ──────┼──▶ valuation ──────┤
                                         │                    ▼
                                         └──────────────▶ pitch book slides
                                                              │
                                              HTML · PPTX · PDF · web UI
```

| Module | Responsibility |
|---|---|
| `argos/db.py` | SQLite schema: corpus, companies, decks, evidence; FTS5 index kept in step by triggers |
| `argos/ingest.py` | Chunking with speaker attribution, sentiment scoring, KPI extraction |
| `argos/nlp.py` | Finance sentiment lexicon, tf-idf keywords, extractive summaries, theme lift |
| `argos/search.py` | Query parsing, synonym expansion, BM25 + recency ranking, facets, snippets |
| `argos/analytics.py` | Dashboards, company profiles, tone timelines, trending themes, alerts |
| `argos/valuation.py` | Comps, precedents, DCF, sensitivity, football field |
| `argos/pitchbook.py` | Slide generation, pinning, evidence, assumptions |
| `argos/charts.py` | Server-rendered SVG on a validated palette |
| `argos/exporters/` | HTML, PPTX (native editable charts), PDF |
| `argos/api.py`, `argos/server.py` | JSON API and the stdlib HTTP server |
| `argos/static/` | The web UI |

Charts are rendered **once**, in Python, and reused by the web UI, the HTML
deck and the preview — so what you see on screen is what ships in the deck. The
PowerPoint export uses native PowerPoint charts instead of pictures, so numbers
stay editable after handover. Colour tokens are served from `/tokens.css`,
generated from the same palette the exporters use, with light and dark modes.

## Command line

```
argos serve     [--host --port --db --quiet]   run the web application
argos seed      [--db]                         load the demo dataset
argos ingest    <path> [--db]                  ingest .json/.jsonl/.csv/.txt, or a directory
argos search    <query> [--limit --json --no-expand]
argos pitchbook <ticker> [--title --client --banker --comps --export --out]
argos export    <id> [--format html|pptx|pdf --out]
argos stats                                    corpus statistics as JSON
```

`ARGOS_DB`, `ARGOS_HOST`, `ARGOS_PORT`, `ARGOS_SEED_DIR` and `ARGOS_EXPORT_DIR`
override the defaults.

## Loading your own data

The demo corpus is synthetic and generated locally — fictional companies, with
a narrative arc across periods so themes and tone have something real-shaped to
find. Replace it with your own:

```bash
python3 -m argos ingest ~/corpus/        # directory of documents
python3 -m argos ingest filings.jsonl    # or a single file
```

See [docs/data-format.md](docs/data-format.md) for the document schema and how
to load company fundamentals, market data and precedent transactions, and
[docs/api.md](docs/api.md) for the HTTP API.

## Tests

```bash
python3 -m unittest discover -s tests -t .
```

166 tests covering sentiment and KPI extraction, query parsing and ranking,
facets and snippet escaping, DCF mechanics (mid-year convention, exit multiples,
terminal-growth validation, sensitivity monotonicity), slide generation and
pinning, evidence, every API route, path-traversal and XSS defences, the
exporters and the CLI. No network access and no fixtures to download.

## Limitations worth knowing

* Sentiment is lexicon-based, not a trained model: directionally useful across a
  corpus, not a calibrated score for a single sentence.
* Theme lift needs volume. On a thin window (a handful of documents) it will
  surface phrasing quirks; widen the window instead of trusting a 2-document
  lift.
* Valuation is only as good as the fundamentals you load. The demo numbers are
  invented, and the models make no attempt to adjust for leases, minorities,
  options or stock-based compensation.
* The server binds to localhost and has no authentication. It is a desktop-class
  analyst tool; put it behind something before exposing it.
