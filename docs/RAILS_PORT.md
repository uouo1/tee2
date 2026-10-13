# Rails port contract

Argos is being ported from the Python package in `argos/` (the **reference
implementation** — read it, port behaviour 1:1 unless this document says
otherwise) to a Ruby on Rails 8.1 application at the repository root. The Python
tests in `tests/` are the behavioural spec; port them to Minitest.

This file is the contract between the people/agents porting modules in
parallel. Interfaces here are binding; internals are yours.

## Stack and conventions

* Ruby 3.3.6, Rails 8.1.4, SQLite (the `sqlite3` gem bundles SQLite 3.53 with
  FTS5), Minitest, importmap + Turbo + Stimulus, Propshaft. **No Node build
  step.** `bin/rails` needs `PATH="/opt/rbenv/versions/3.3.6/bin:$PATH"` in
  non-interactive shells here.
* Services are plain Ruby modules under `app/services/` (autoloaded by Zeitwerk;
  `app/services/valuation/dcf.rb` defines `Valuation::Dcf`). Module functions
  via `module_function` or `def self.x`.
* **Hashes use symbol keys** everywhere inside Ruby. JSON persisted in `slides.payload`,
  `pitchbooks.assumptions`, `saved_searches.filters` is read back with
  `symbolize_names: true` (see `Slide#payload_hash`). JSON API responses render
  whatever keys the Python API used (strings over the wire).
* Keyword arguments for options; positional for the one or two obvious inputs.
  Match the Python signatures listed below.
* Money in **millions** of reporting currency; per-share values absolute; rates
  as decimals (0.095). Dates are `Date`; ISO strings only at the API boundary.
* `# frozen_string_literal: true` on every file. Comments explain *why*, at the
  density of the existing Python files. No external network calls in tests.
* Tests live in `test/services/<name>_test.rb`, `test/controllers/...`,
  `test/lib/...`. Run one file with `bin/rails test test/services/nlp_test.rb`.
  `test/test_helper.rb` already recreates the FTS index; use
  `Seed::Demo.seed!` (ported from `argos/seed.py`) inside a `setup` when a test
  needs a corpus — it must be deterministic.
* Never shell out to Python. The Python code is reference only and will be
  deleted when the port reaches parity.

## Schema (already migrated — `db/migrate/20261013030000_create_argos_schema.rb`)

Tables: `companies`, `financials`, `market_data` (model `MarketDatum`),
`documents`, `chunks`, `chunks_fts` (FTS5, external content, porter unicode61,
triggers `chunks_ai/ad/au`), `kpis`, `transactions` (model `Transaction` —
precedent M&A deals), `watchlists`, `watchlist_items`, `saved_searches`,
`pitchbooks`, `slides`, `comp_members`, `evidences` (model `Evidence`).
Columns match the Python schema in `argos/db.py` plus `market_data.shares_basic`.
Models with associations exist in `app/models/`. `SearchIndex.ensure!` creates
the FTS objects idempotently (migration, test helper, seeder).

One deliberate change from Python: `market_data.shares_diluted` must hold the
**diluted weighted-average** share count (us-gaap
`WeightedAverageNumberOfDilutedSharesOutstanding`, latest fiscal year) when the
filer reports one, falling back to the cover-page count; the cover-page count
is stored in `shares_basic`. A verifier found the Python version used basic
shares under a "diluted" label (43.79m vs 46.32m for Itron — ~6% on every
per-share value).

## Module contracts

### `Nlp` (`app/services/nlp.rb`) — port of `argos/nlp.py`

```ruby
Nlp::STOPWORDS, Nlp::FILING_BOILERPLATE, Nlp::SYNONYMS, Nlp::POSITIVE_LEXICON, Nlp::NEGATIVE_LEXICON
Nlp.tokenize(text) -> [String]                 # lowercased word tokens
Nlp.content_tokens(text) -> [String]           # minus stopwords, len > 2, non-numeric
Nlp.sentences(text) -> [String]
Nlp.score_sentiment(text) -> Float             # [-1, 1]; negation look-back of 3, intensifiers
Nlp.sentiment_label(score) -> "positive" | "neutral" | "negative"   # thresholds ±0.18
Nlp.expand_query_terms(terms) -> [String]      # ordered, unique, lexicon synonyms appended
Nlp::Corpus                                    # #add(text), #idf(token), #doc_count
Nlp.keywords(text, corpus: nil, limit: 8) -> [[String, Float]]   # sublinear tf-idf, min-count floor, bigrams
Nlp.summarize(text, limit: 4, query_terms: []) -> [String]        # extractive, source order, skips table rows
Nlp.extract_kpis(text) -> [{metric:, value:, unit:, context:}]    # same KPI_PATTERNS; billions -> millions
Nlp.cosine_similarity(a, b) -> Float           # a, b are Hash{String => Numeric}
Nlp.vector(text, corpus = nil) -> Hash
Nlp.theme_trends(recent, baseline, limit: 10, min_recent: 2) -> [{theme:, mentions:, prior_mentions:, lift:, rank:}]
Nlp.looks_like_table_row(text) -> bool
Nlp.looks_like_heading(text) -> bool
Nlp.strip_leading_heading(text) -> String
```
Keep every heuristic (sentence prose-only features, phrase-first dedupe of
contained themes, `rank = lift * 1.25-if-phrase * (1 + 0.4*ln(mentions))`).

### `Ingest` (`app/services/ingest.rb`) — port of `argos/ingest.py`

```ruby
Ingest::DOC_TYPES, Ingest::MIN_CHUNK_CHARS (180), Ingest::MAX_CHUNK_CHARS (1400)
Ingest.split_paragraphs(body) -> [String]
Ingest.chunk_body(body) -> [{speaker: String|nil, text: String}]   # speaker regex, glue short paragraphs, split long
Ingest.ingest_document(attrs) -> Document | nil   # nil when external_id already present; attrs keys as Python
Ingest.ingest_many(docs) -> {added:, skipped:}    # one transaction
Ingest.read_documents(path) -> Enumerator          # .json (list or {documents:}), .jsonl, .csv, .txt/.md
Ingest.ingest_path(path) -> {added:, skipped:, files:}
```
`attrs` accepts `:ticker` + `:company_name` to resolve/create the company,
exactly like Python. Chunk sentiment and KPIs are written on ingest.

### `Search` (`app/services/search.rb`) — port of `argos/search.py`

```ruby
Search::ParsedQuery = Struct(raw, terms, phrases, or_groups, excluded, fields) with #empty?, #all_terms
Search.parse_query(raw) -> ParsedQuery
Search.build_match_expression(parsed, expand: true) -> String   # FTS5 syntax; quotes neutralised
Search.search(q = "", filters = {}, limit: 25, offset: 0, expand: true, summarize: true, today: Date.today) -> Hash
  # keys: :query, :parsed, :match_expression, :expanded, :total_documents, :returned, :offset,
  #       :results (one per document: chunk_id, document_id, seq, speaker, chunk_sentiment, title, doc_type, source,
  #                 author, published_at, url, doc_sentiment, word_count, ticker, company, sector, score,
  #                 snippet_html (escaped, <mark>), sentiment_label, match_count),
  #       :facets {doc_type:, ticker:, sector:, year:, sentiment: => [{label:, value:, count:}]},
  #       :summary {bullets: [{text:, document_id:, title:, ticker:, doc_type:, published_at:, chunk_id:, sentiment:}],
  #                 themes: [{theme:, weight:}], sentiment:, sentiment_label:}, :took_ms
Search.get_document(id, query_terms: []) -> Hash | nil   # chunks, kpis, summary, keywords, similar, sentiment_label
Search.similar_documents(id, limit: 5) -> [{document_id:, title:, doc_type:, published_at:, ticker:, similarity:}]
Search.corpus_stats -> Nlp::Corpus               # cached per document count
```
Ranking: `-bm25 * DOC_TYPE_WEIGHT * recency` (half-life 420 days); browse mode
(no query) is strictly newest-first with score 0. Filters: `doc_type`/`ticker`
(array or string), `company`, `sector`, `source`, `author`, `date_from`,
`date_to`, `sentiment`, `min_document_id`. Inline `type:`/`ticker:` fields
merge with explicit filters. Summary bullets: no questions, no table rows, no
headings, ≥ 8 words, deduplicated by normalised prefix, capitalised.

### `Analytics` (`app/services/analytics.rb`) — port of `argos/analytics.py`

```ruby
Analytics::KPI_LABELS
Analytics.overview -> Hash                         # as_of, counts, by_type, coverage, recent, sentiment, trending(180d)
Analytics.sentiment_timeline(ticker: nil, months: 24) -> [{month:, sentiment:, documents:}]
Analytics.volume_by_type(ticker: nil, months: 24) -> {months:, series: [{name:, values:}]}
Analytics.trending_themes(window_days: 120, ticker: nil, limit: 12) -> {as_of:, window_days:, recent_documents:, baseline_documents:, themes:}
  # uses chunk text (speaker-stripped) grouped per document, not documents.body
Analytics.company_profile(ticker) -> Hash | nil    # financials, market_data, document_count, sentiment, documents, kpis, sentiment_timeline, themes, metrics
Analytics.kpi_series(ticker) -> [{metric:, label:, unit:, points:, latest:, observations:}]
Analytics.check_alerts(mark_seen: false) -> [{saved_search_id:, name:, query:, new_documents:, hits:}]
```
"As of" is the newest document date, never `Date.today`.

### `Valuation` (`app/services/valuation.rb` + `valuation/*.rb`) — port of `argos/valuation.py`

```ruby
Valuation::MULTIPLES, Valuation::MULTIPLE_LABELS
Valuation.percentile(values, pct) -> Float | nil   # linear interpolation
Valuation.describe(values) -> {count:, min:, p25:, median:, p75:, max:, mean:}
Valuation.company_metrics(ticker, forward_years: 2) -> Hash | nil   # latest_actual multiples, forward, financials, EV bridge
Valuation.comps_table(tickers, exclude: nil) -> {rows:, stats:, labels:}
Valuation.precedent_transactions(sector: nil) -> {rows:, stats:}
Valuation.implied_from_multiple(low, high, metric_value:, kind:, net_debt:, shares:) -> Hash | nil
Valuation::DcfAssumptions   # Data/Struct with keyword init and the Python defaults;
                            # .coerce(hash) drops unknown/blank keys and casts; #with_overrides(hash); #to_h
Valuation.run_dcf(assumptions) -> Hash           # projections, pv_explicit, terminal_value, pv_terminal, terminal_method,
                                                 # terminal_share_of_ev, enterprise_value, net_debt, equity_value, value_per_share, implied_ev_ebitda
                                                 # raises ArgumentError: wacc <= 0, base_revenue <= 0, terminal_growth >= wacc (growth method)
Valuation.dcf_sensitivity(assumptions, wacc_steps: nil, terminal_steps: nil) -> {wacc_axis:, terminal_axis:, grid:, min:, max:}
Valuation.football_field(target_ticker, comp_tickers, assumptions: nil) -> Hash   # target, ranges, axis, reference_price, comps, precedents, dcf, sensitivity, concluded_range
Valuation.default_assumptions(metrics) -> DcfAssumptions   # 3-year NWC average clamped [-3%, 5%], tax clamped [15%, 35%]
```
Football-field DCF band is WACC ±100bps × terminal ±50bps (the displayed
sensitivity grid is ±150/±100); concluded range = median low / median high.
Omit the precedent bar when no transactions exist (never fabricate).

### `Charts` (`app/services/charts.rb`) — port of `argos/charts.py`

```ruby
Charts::PALETTE (light/dark hashes, identical hex values), Charts::SERIES_SLOTS, Charts::MAX_SERIES
Charts.css_tokens(mode = "light", selector: ".viz") -> String
Charts.football_field_svg(ranges, reference_price: nil, concluded: nil, currency_symbol: "$", width: 760, row_height: 44) -> String
Charts.column_chart_svg(labels, values, title: "", value_format: ->(v) { ... }, highlight_index: nil, estimate_from: nil, width: 620, height: 240, label_every: 1)
Charts.line_chart_svg(labels, values, title: "", value_format: ->(v) { "%.1f%%" % v }, width: 620, height: 200)
Charts.diverging_bar_svg(labels, values, title: "", width: 620, height: 210, value_format: ->(v) { "%+.2f" % v })
Charts.stacked_bar_svg(labels, series, title: "", width: 620, height: 230)
Charts.heatmap_html(grid, row_labels:, column_labels:, row_title: "", column_title: "", value_format: ->(v) { ... }, reference: nil)
Charts.table_html(columns, rows, caption: "", highlight_key: nil)   # columns: [{key:, label:, numeric:, format: Proc|nil}]
```
Output strings are `html_safe`-able SVG/HTML using CSS custom properties
(`var(--series-1)`), never literal hex. Keep `nice_ticks` (log10 magnitude,
≤ 24 ticks). Escape every label.

### `Pitchbooks` (`app/services/pitchbooks.rb`, `pitchbooks/slides/*.rb`) — port of `argos/pitchbook.py`

```ruby
Pitchbooks::SLIDE_ORDER   # 14 [kind, default title] pairs, same order as Python
Pitchbooks::DISCLAIMER
Pitchbooks.create!(title:, target_ticker:, comp_tickers: nil, client_name: nil, subtitle: nil, banker: nil, assumptions: nil) -> Pitchbook
Pitchbooks.suggest_comps(target_ticker, limit: 6) -> [String]
Pitchbooks.rebuild_slides!(pitchbook) -> [Slide]         # pinned slides survive, seq renumbered
Pitchbooks.update_slide!(slide, title: nil, subtitle: nil, payload: nil, pin: nil) -> Slide   # edits pin unless pin: false
Pitchbooks.reorder_slides!(pitchbook, slide_ids) -> [Slide]
Pitchbooks.add_evidence!(pitchbook, quote:, document_id: nil, chunk_id: nil, slide_id: nil, note: nil) -> Evidence   # refreshes appendix
Pitchbooks.delete_evidence!(evidence) -> true
Pitchbooks.set_comps!(pitchbook, tickers) -> [String]    # then rebuild
Pitchbooks.set_assumptions!(pitchbook, hash) -> Hash     # merge, then rebuild
Pitchbooks.summary(pitchbook) -> Hash                    # index row: slide_count, evidence_count, ticker, target_name
```
Each slide builder returns `{title:, subtitle:, payload:}` with the **same
payload keys as Python** (see `argos/pitchbook.py` `_slide_*`), because the
views, PDF and PPTX exporters read those keys. Executive summary cites the
corpus via `Search.search("guidance OR margin OR demand OR pricing OR retention", {ticker: ...})`
and takes themes from that summary; tone wording handles the neutral case;
precedent-less decks say so on the precedents, process and counterparties slides.

### `Exporters` — HTML via views; PDF and PPTX in `app/services/exporters/`

```ruby
Exporters.available_formats -> {html: true, pptx: true, pdf: true}
Exporters.export(pitchbook, format, path) -> Pathname
Exporters::Html.render(pitchbook) -> String          # full self-contained document (tokens inline, both colour schemes)
Exporters::Html.render_body(pitchbook) -> String     # just the <section class="slide"> markup (used by the in-app preview)
Exporters::Pdf.write(pitchbook, path)                # Prawn, landscape A4, one page per slide, football field drawn as vectors
Exporters::Pptx.write(pitchbook, path)               # OOXML writer on rubyzip; native bar/line charts and tables
```
HTML slide rendering is ERB partials under `app/views/decks/slides/_<kind>.html.erb`
rendered with `ApplicationController.render(partial:, locals:)`, so the in-app
preview and the export are the same markup. The PPTX writer must reproduce the
structure python-pptx emits — a reference deck is unpacked at
`/tmp/claude-0/-home-user-tee2/cbdc55dd-1c9d-5f18-9051-a71999adcb00/scratchpad/pptx-reference/`
(chart XML parts with embedded worksheet caches, slide XML with table and chart
graphic frames, `[Content_Types].xml`, rels). Validate output by opening it
with python-pptx (`python3 -c "from pptx import Presentation; ..."` is
available for *verification only*) and by `zipfile` integrity.

### `Sources` (`app/services/sources/*.rb`) — port of `argos/sources/`

```ruby
Sources::Http.fetch(url, cache: true, timeout: 45, user_agent: nil) -> String   # throttled (≥150ms), cached under data/cache, backoff, 4xx raise
Sources::Http.fetch_json(url, **opts) -> Hash
Sources::HtmlText.html_to_text(markup, max_chars: nil) -> String   # drop script/style/hidden ix, zero-width chars, page numbers, TOC rows, "Table of Contents" prefixes; rejoin wrapped lines
Sources::Market.fetch_quote(ticker, cache: true) -> Hash | nil      # share_price, currency, week52_low/high, as_of, exchange
Sources::Sec.resolve_cik(ticker), .fetch_submissions(cik), .fetch_facts(cik)
Sources::Sec.build_financials(facts, years: 6) -> [Hash]            # same tag preference order; early-January year ends -> prior FY; D&A fallback; operating NWC excludes cash & debt
Sources::Sec.net_debt(facts, fiscal_year) -> Float | nil
Sources::Sec.shares(facts) -> {diluted:, basic:}                    # see schema note above
Sources::Sec.collect_documents(cik, submissions, annual: 1, quarterly: 2, press_releases: 4) -> [Hash]   # EX-99.1 by normalised name
Sources::Sec.load_company(ticker, sector: nil, years: 6, annual: 1, quarterly: 2, press_releases: 4, with_documents: true, with_quote: true) -> Hash
Sources::Sec.load_companies(tickers, **opts) -> {loaded:, failures:, companies:, documents_added:}
Sources::Sec.load_transactions_csv(path) -> {added:, rows:}
```
User-Agent defaults to a generic identifier; `ARGOS_USER_AGENT` overrides.
Never send a personal email address. Tests use hand-built fact fixtures
(port `tests/test_sources.py`) and never touch the network.

### `Seed::Demo` (`app/services/seed/demo.rb`) — port of `argos/seed.py`

`Seed::Demo.seed!(rng_seed: 20261012) -> Hash` with the same fictional
companies, financial-series back-cast, market derivation from target EV/EBITDA,
sentence banks and narrative arc. Deterministic via `Random.new(seed)`.
`db/seeds.rb` calls it.

### Rake tasks (`lib/tasks/argos.rake`) — port of `argos/__main__.py`

`argos:seed`, `argos:ingest[path]`, `argos:load_sec[tickers,sector]`
(tickers space-separated in one arg), `argos:load_transactions[path]`,
`argos:search[query,limit]`, `argos:pitchbook[ticker,title,comps,export]`,
`argos:export[id,format,out]`, `argos:stats`. Print JSON where the Python CLI did.

### Web (controllers, views, JS)

Server-rendered ERB with Turbo; Stimulus only for the theme toggle, the
pin-to-deck dialog and the comp picker. Pages: `/` dashboard, `/research`
(GET form; facets are links), `/documents/:id`, `/companies`, `/companies/:ticker`,
`/pitchbooks` (+ new form), `/pitchbooks/:id` (toolbar, assumptions form, deck
preview), `/monitor` (alerts, saved searches, watchlists). Keep the look of
`argos/static/app.css` (port it to `app/assets/stylesheets/application.css`) and
serve palette tokens at `/tokens.css` from `Charts.css_tokens`.
JSON API at `/api/...` with the **same paths and response keys** as `docs/api.md`
(`Api::*` controllers), so the existing API documentation stays true.

## Phase plan and file ownership

Phase A (parallel, disjoint files): Nlp · Ingest+HtmlText · Search+Analytics ·
Valuation · Charts · Sources (Http/Market/Sec) · Seed::Demo · Exporters::Pptx ·
Exporters::Pdf. Each owns its service file(s) and its test file(s) only.
Phase B (parallel): Pitchbooks + deck partials + Exporters::Html · controllers,
routes, views, layout, CSS/JS for research/dashboard/companies/monitor ·
rake tasks + API controllers. Phase C: integration, full suite, run the server,
screenshots, adversarial review, delete the Python tree, update README/TUTORIAL.

## Defects found by independent verification — the port must fix these

An adversarial verification of the Python build (fresh clone, raw EDGAR
re-fetch, filing provenance, code audit, skeptic) confirmed that it runs from
the repository and that its Itron fundamentals and filings are genuine EDGAR
data. It also found the following. The Rails version fixes each one and carries
a regression test for it; porting the Python behaviour verbatim is wrong here.

1. **HTML extractor drops most 10-Q text.** `argos/sources/htmltext.py` enters
   hidden mode on *any* tag whose style contains `display:none` but only leaves
   it on `</div>` or `</ix:header>`, so a hidden `<span>` swallows everything
   after it; 10 of 14 real 10-Qs retained 2–9% of their words. `Sources::HtmlText`
   must keep a stack of (tag name, hidden?) and un-hide only when the *same*
   tag that opened the hidden block closes. Test: a hidden `<span>` followed by a
   visible `<p>` keeps the paragraph; a 10-Q-sized fixture retains > 80% of its
   visible words.
2. **Share count.** Store diluted weighted-average shares in `shares_diluted`
   and the cover-page count in `shares_basic` (already in the contract). The
   company page and the comps table label which was used.
3. **Missing net debt is not zero.** When a filer has no debt tags *and* no cash
   tag, `net_debt` is nil and `Valuation.company_metrics` must report EV and
   EV-based multiples as nil (shown as n/a, excluded from percentile statistics),
   not compute them with net debt = 0. Add more cash fallbacks first:
   `CashCashEquivalentsRestrictedCashAndRestrictedCashEquivalents`, `Cash`.
4. **Quotes are cached forever.** `Sources::Market.fetch_quote` must key its
   cache by (ticker, calendar day) so a reload refreshes the price; the
   loader's summary says the quote date.
5. **Search totals and pagination are wrong for broad queries.** The Python
   ranked a top-k of chunks (`min(limit*6+offset, 600)`) then collapsed to
   documents, so `total_documents` changes with page size. `Search.search` must
   rank *documents*: one SQL that takes the best (lowest) bm25 per document
   over *all* matching chunks (`GROUP BY document_id`, `MIN(bm25)`), weights
   and sorts in Ruby, counts the true total, then paginates. Sentiment facet and
   sentiment filter must both be document-level (`documents.sentiment`).
6. **KPI extraction needs sanity bounds.** Reject headcount values that look like
   years (1900–2100) or that are below 10; reject any margin/retention/growth
   value above 100% (or below −100%); reject negative headcount/ARR/backlog.
   Real filings produced `headcount = 2004` (from "2004 Stock Incentive Plan")
   and `ebitda_margin = 120`.
7. **Hardcoded analysis in slides.** Replace fixed-threshold prose with
   data-driven comparisons: profitability vs the *peer median* margin
   (above/in line/below with the numbers); leverage phrased from net debt /
   EBITDA (net cash, < 1x, 1–3x, > 3x) rather than always "modest"; remove the
   domain-specific "subscription pricing" diligence bullet (use a generic
   bullet plus the company's own top themes); note on the DCF slide when beta
   was not loaded so WACC is the default. Counterparty rationale must reflect
   each peer's actual margin and multiple relative to the target.
8. **Deck editing in the UI.** Slide title/subtitle editing (which pins),
   reorder (move up/down), comp-set change and assumption edits must all be
   reachable from the pitch-book page, not only from the API.
9. **`POST /api/ingest` with `path`** must only read under `Rails.root/data`
   (reject anything that resolves outside it). Document that there is no
   authentication.
10. **Test isolation.** Exports written during tests go to `tmp/` (set
    `Exporters.export_dir` from an env/config value, `Rails.root/tmp/exports`
    in test), never into `data/exports`.
