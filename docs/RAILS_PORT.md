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
Columns match the Python schema in `argos/db.py` plus `market_data.shares_basic`
and, since the October 2026 audit (docs/AUDIT.md, migration
`20261017110000_add_valuation_bridge_and_ltm.rb`): `financials.period_type`
(`"FY"` or `"LTM"`), `financials.period_end`, and on `market_data`
`net_debt_as_of`, `balance_sheet_form`, `minority_interest`,
`preferred_equity`, `debt_note`. The unique key on financials is
(company_id, fiscal_year, period_type); an LTM row shares its fiscal_year with
the last reported year it extends. Models with associations exist in
`app/models/`. `SearchIndex.ensure!` creates the FTS objects idempotently and
rebuilds the index when it is new or out of step with `chunks` (migration,
test helper, seeder, and `Ingest` before the first write).

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
Valuation.company_metrics(ticker, forward_years: 2) -> Hash | nil   # latest_actual (last FY), ltm (or nil), valuation_basis (LTM when present, else FY),
                                                                     # basis_label ("LTM Jun-26" / "FY2025"), ntm (or nil), ev_bridge, net_debt_as_of, other_claims, forward, financials
Valuation.ntm_metrics(fiscal_rows, basis, as_of:, enterprise_value:, price:) -> Hash | nil   # calendarised next twelve months: weight_current_year, revenue, eps,
                                                                     # ebitda (consensus when a row has it, else derived at the basis margin and flagged ebitda_derived), ev_revenue, ev_ebitda, pe, fiscal_years, source
Valuation.comps_table(tickers, exclude: nil) -> {rows:, stats:, labels:, bases:}   # rows carry basis, price_date, net_debt_as_of, other_claims, ev_revenue_ntm, ev_ebitda_ntm, pe_ntm;
                                                                                    # stats cover MULTIPLES and NTM_MULTIPLES
Valuation.precedent_transactions(sector: nil) -> {rows:, stats:}
Valuation.implied_from_multiple(low, high, metric_value:, kind:, net_debt:, shares:, other_claims: 0.0) -> Hash | nil
Valuation.wacc_build(metrics, risk_free_rate:, equity_risk_premium:, debt_spread:, beta:, tax_rate:) -> Hash   # CAPM build with inputs, weights, notes
Valuation::DcfAssumptions   # Data with keyword init; .coerce(hash) drops unknown/blank keys and casts; #with_overrides(hash); #to_h
                            # fields: base_revenue, revenue_growth (year 1), ebitda_margin, margin_expansion, da_pct_revenue, capex_pct_revenue,
                            # nwc_pct_revenue (per unit of revenue CHANGE), tax_rate, wacc, terminal_growth, exit_multiple, years, net_debt (nil = unknown),
                            # other_claims, shares_diluted (nil = unknown), mid_year_convention, terminal_capex_floor, stub_fraction, start_year, valuation_date
Valuation.run_dcf(assumptions) -> Hash           # projections (with fcf_full_year, period_fraction, discount_period), terminal_year, pv_explicit, terminal_value,
                                                 # pv_terminal, terminal_method, terminal_discount_period, terminal_share_of_ev, implied_exit_multiple,
                                                 # implied_terminal_growth, enterprise_value, net_debt, other_claims, equity_value, value_per_share, bridge_note, implied_ev_ebitda
                                                 # raises ArgumentError: wacc <= 0, base_revenue <= 0, years < 1, stub_fraction outside (0, 1], terminal_growth >= wacc (growth method)
Valuation.dcf_sensitivity(assumptions, wacc_steps: nil, terminal_steps: nil) -> {wacc_axis:, terminal_axis:, grid:, min:, max:}
Valuation.football_field(target_ticker, comp_tickers, assumptions: nil) -> Hash   # target, ranges (each with in_conclusion, reference, note), axis, reference_price,
                                                                                   # comps, precedents, wacc, dcf, dcf_note, sensitivity, concluded_range {low, high, methods}
Valuation.default_assumptions(metrics, wacc: nil) -> DcfAssumptions   # growth from the last two FYs; margin/D&A/capex from the LTM row when present;
                                                                      # 3-year NWC average clamped [-3%, 5%]; WACC from wacc_build; stub from the price date
```
DCF mechanics (each a corrected audit finding; see docs/AUDIT.md): growth
interpolates linearly from year 1 to the terminal rate; ΔNWC = intensity ×
change in revenue; year 1 counts only its `stub_fraction` and every flow is
discounted from the valuation date; the terminal year is built explicitly with
capex floored at D&A; a Gordon terminal value sits at N − ½ under the mid-year
convention, an exit-multiple value at N; unknown net debt gives an enterprise
value and no per-share figure. Football-field DCF band is WACC ±100bps ×
terminal ±50bps (the displayed sensitivity grid is ±150/±100). The concluded
range is the median low / median high of the bars with `in_conclusion`: the
52-week range is a reference bar only, and the EV/Revenue bar is excluded
when the target's EBITDA margin lies outside the peers' interquartile range.
EV = market cap + net debt + minority interest + preferred equity, with the
balance-sheet date and form reported beside it. Multiples are quoted on the
LTM row when the loader built one, else the last fiscal year, and every page
must print `basis_label` next to them. NTM: the loader stores consensus
revenue and EPS for the fiscal year in progress and the next as estimate rows
(`estimate_source` names the source and analyst count); `ntm_metrics` blends
them by the share of the current year still ahead at the price date; a
"Trading comps — NTM EV/EBITDA" bar leads the football field when the target
has an NTM EBITDA and at least `MIN_NTM_PEERS` (3) peers carry one, and its
basis says whether the EBITDA was derived from consensus revenue at the
current margin (no public source publishes consensus EBITDA). Omit the
precedent bar when no transactions exist (never fabricate).

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
Sources::Sec.build_financials(facts, years: 6) -> [Hash]            # FY rows (period_type "FY", period_end) then one LTM row when a 10-Q extends the last year;
                                                                     # tags resolved PER YEAR in preference order; early-January year ends -> prior FY; D&A fallback; operating NWC excludes cash & debt
Sources::Sec.duration_entries(facts, names, unit:) -> {year => {value:, period_end:, filed:, tag:}}
Sources::Sec.instant_entries(facts, names, forms:, fiscal_year_only:) -> {Date => {value:, filed:, form:, tag:}}
Sources::Sec.latest_balance_sheet(facts) -> Hash | nil             # newest 10-K/10-Q balance sheet at one date: cash, debt lines, gross_debt, net_debt, minority_interest, preferred_equity, debt_note
Sources::Sec.ltm_row(facts, fy_row) -> Hash | nil                   # FY + YTD − prior YTD per flow; D&A falls back to the FY figure
Sources::Sec.net_debt(facts, fiscal_year) -> Float | nil            # the fiscal-year-end view
Sources::Market.fetch_estimates(ticker, cache: true, on: Date.today) -> Hash | nil   # consensus revenue/EPS for the current and next fiscal year plus beta,
                                                                     # via the quote summary (cookie + crumb; neither cached); parsed payload cached per (ticker, day)
Sources::Sec.shares(facts) -> {diluted:, basic:, basis:, fallback_reason:}   # weighted diluted only if from the latest FY and within 0.5–2x of the cover count
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

## Phase plan and file ownership — status

Phase A (services) and Phase B (Pitchbooks + deck partials + Exporters::Html,
the web UI, the JSON API and rake tasks) are ported and green: 694 tests,
5,280 assertions across the whole suite on 18 October 2026. Phase C
(integration, server run, screenshots) is done. On 18 October the real-data
tutorial was regenerated on the Rails build (`ARGOS_DB=storage/real.sqlite3`
points the development app at a separate file; `TUTORIAL.md` and
`docs/images/real-*.png` now show the Rails pages) and the Python and Rails
builds were checked against each other on that corpus: identical passage
counts (10,739 from 49 filings), identical Itron valuation to the cent. The
Python tree stays as the reference implementation; its removal is a separate
decision once the adversarial review of the port has closed.

Integration notes: the formatting helpers live in
`DashboardController::Formatting` (every view controller includes it);
`Api::BaseController::Error(message, status)` is the API error class and a
JSON catch-all route closes the `api` namespace; `Exporters::Pptx::Wording`
holds the sentences the PPTX and PDF writers share; the valuation test seed
replaces the demo rows it collides with so test classes can run in any order.

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
   visible words. (Back-ported to the Python converter on 18 October 2026 with
   the same tests; on Itron's June 2026 10-Q both now produce the same 177,759
   characters where the old converter kept 4,632.)
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
6. **KPI extraction needs sanity bounds and signs.** Reject headcount values
   that look like years (1900–2100) or that are below 10; reject margins
   outside ±100%, churn and capex intensity outside 0–100%, net retention above
   300% and growth above 1,000% (retention and growth above 100% are real);
   reject negative headcount/ARR/backlog but keep a negative free cash flow or
   margin WITH its sign (the reference stored "-$12 million" as +12). Real
   filings produced `headcount = 2004` (from "2004 Stock Incentive Plan") and
   `ebitda_margin = 120`.
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

## Findings of the October 2026 audit — binding on the modules still to port

An investment-analyst review and two engineering audits (docs/AUDIT.md) added
the following. Items 11–15 are fixed in the ported services and must not be
undone; items 16–22 bind `Pitchbooks`, the deck views, `Search`, `Analytics`,
the API and the web UI.

11. **EV bridge.** Net debt comes from the latest balance sheet (10-K or 10-Q)
    with its date and form stored; non-controlling interest and preferred
    equity are deducted; a filer with no debt line is bridged at zero debt with
    `debt_note` set. Tags resolve per year/date, never once per company.
12. **LTM and NTM.** `build_financials` adds a trailing-twelve-month row from
    the latest 10-Q; `Valuation` quotes multiples on it when present and labels
    the basis. `load_company` stores consensus revenue and EPS estimate rows and
    beta; `Valuation` calendarises them to NTM and leads the comps with an NTM
    EV/EBITDA bar, flagging a derived EBITDA.
13. **DCF mechanics** as listed under `Valuation` above: ΔNWC on revenue
    change, linear growth path, stub period, terminal year with a capex floor,
    exit multiple at N, built-up WACC, no bridge through unknown net debt.
14. **Football field.** The 52-week range never enters the concluded range; an
    EV/Revenue bar on a margin outlier is shown but excluded with a note.
15. **Share-count guards.** A weighted diluted count is used only when it is
    from the latest fiscal year and within 0.5–2× of the cover count.
16. **No "upside" language.** Comps bars are "implied value at peer multiples",
    never upside or a price target; the executive summary and process slides
    state the implied range against the price without calling it a move. The
    repository's own backtest found no evidence that cheap-versus-peers predicts
    returns, and the deck must not imply otherwise.
17. **Every multiple names its period and date.** Comps and valuation pages
    print `basis_label` (LTM Jun-26 / FY2025), the price date, the
    balance-sheet date, the share-count basis (`shares_basic` vs
    `shares_diluted`) and an EBITDA-definition footnote (GAAP operating income
    plus D&A, no adjustments).
18. **DCF slide.** Shows the WACC build (`wacc_build` inputs and notes, including
    "beta not loaded" when assumed), the stub fraction and valuation date, a
    projections table with D&A and ΔNWC so UFCF ties, the terminal-year row,
    and the implied exit multiple / implied growth cross-checks.
19. **Prose is data-driven.** Profitability compares the target's margin with the
    peer median (with both numbers); leverage comes from net debt / EBITDA
    bands; no fixed adjectives ("modest"), no SaaS diligence bullet, no
    counterparty rationale that calls every peer "accretive"; themes used in
    prose must pass the boilerplate stoplist and may not emit tokens such as
    "n/a".
20. **KPI tiles** carry a period and, when the sentence is a segment or table
    row, are not shown as company-level; the company page labels adjusted vs
    GAAP where the sentence says so.
21. **Search** reports document-level totals that agree with the facets, accepts
    several values per field filter (`ticker:ITRI ticker:BMI`) and a `date:`
    filter.
22. **Decks are stamped** with the data as-of date, the price date and the code
    version, and the UI warns when the data is newer than the slides.
