# Backtest data and method

The research and valuation tools in Argos produce opinions — a peer-implied
range, a DCF, a tone score. A backtest asks whether those opinions, formed with
only what was knowable on a past date, said anything about what happened next.
This document is the contract for acquiring the data and running the test. It is
binding for the modules named below; internals are theirs.

Everything here uses free public sources. That buys a lot (every SEC filer, ten
years, filing dates for point-in-time reconstruction, dividend-adjusted prices)
and it costs something specific, listed under **Known biases** — none of which
is hidden in the output.

## Sources

| Need | Source | Notes |
|---|---|---|
| Universe (who filed what, when) | `https://data.sec.gov/api/xbrl/frames/us-gaap/<Concept>/USD/CY<year>.json` | All filers for one concept and calendar period in one request (~0.5 MB). Fields: `accn, cik, entityName, loc, start, end, val`. **No filing date** — for universe construction only. |
| Point-in-time fundamentals | `https://data.sec.gov/api/xbrl/companyfacts/CIK##########.json` | Every filed value with `filed`, `start`/`end`, `form`, `fy`, `fp`, `accn`. This is the only source used for values the backtest consumes. |
| Sector, name | `https://data.sec.gov/submissions/CIK##########.json` | `sic`, `sicDescription`, `tickers`, `exchanges`. |
| Ticker map | `https://www.sec.gov/files/company_tickers.json` | Current tickers only. |
| Prices | `https://query1.finance.yahoo.com/v8/finance/chart/<T>?range=10y&interval=1mo&events=splits` | `close` (split-adjusted) and `adjclose` (splits and dividends) per month, plus the split events needed to recover the unadjusted close. |
| Prices, fallback | `https://api.nasdaq.com/api/quote/<T>/historical?assetclass=stocks&fromdate=&todate=&limit=9999` | Daily unadjusted close; resample to month-end; flag `adjusted=false`. |

All requests go through `Sources::Http` (throttled, cached under `data/cache`,
identified User-Agent from `ARGOS_USER_AGENT`). SEC asks for ≤ 10 requests/s;
stay at ≤ 6.

## Tables (migration `20261014060000_create_backtest_tables.rb`)

```
universe_members  cik, ticker, name, sic, sic_description, exchange, loc,
                  revenue_anchor (USD, anchor-year frame value), has_prices,
                  dropout_reason, selected_at
pit_facts         cik, ticker, concept, fiscal_year, period_start, period_end,
                  value (USD or shares, raw units), filed, accession, form
                  — unique on (cik, concept, period_end, filed)
price_bars        ticker, month_end (date), close, adj_close, source, adjusted
                  — unique on (ticker, month_end)
split_events      ticker, date, ratio (shares after per share before), source
                  — unique on (ticker, date)
backtest_runs     name, params (JSON), results (JSON), created_at
```

`concept` is one of: `revenue, operating_income, dep_amort, net_income, eps,
cash, short_term_investments, debt_current, debt_noncurrent, debt_total,
shares_cover, shares_diluted`, resolved through the same tag-preference tables
as `Sources::Sec::TAGS` / `INSTANT_TAGS`. Tags are resolved **per period and
filing**: for each (period_end, filed) the first tag in preference order that
carries a value wins, so a filer that switched tags keeps every year (an
earlier "first tag with any data, per company" rule lost later years and
dropped names whose D&A sat under a rarer tag). `dep_amort` also accepts
`DepreciationAmortizationAndOther` and, for filings with no combined line, the
sum of `Depreciation` and `AmortizationOfIntangibleAssets`. `debt_total`
(`LongTermDebt` and similar one-line tags) is for filers that tag neither
split debt line. Store **every** filed observation, not just the latest: a value
restated in a later 10-K is a second row with its own `filed`.

## Universe (module `Backtest::Universe`)

1. Anchor year `A` (default 2016). Take the revenue frame for CY`A` (tag
   `Revenues`, then `RevenueFromContractWithCustomerExcludingAssessedTax`;
   union by CIK, first non-null). Keep US filers (`loc` starts with `US-`).
2. Rank by revenue, take the top `N` (default 600; `UNIVERSE_SIZE`).
3. Join current tickers, taking the **first-listed** ticker for a CIK (the
   primary common listing; the shortest-ticker rule once priced Comcast off an
   exchangeable note and TVA off a bond). CIKs without a ticker are kept as
   members with `dropout_reason = "no_current_ticker"`. That count is an
   **upper bound** on delistings, not a clean survivorship measure: it also
   holds debt-only subsidiaries, predecessor CIKs and registrants whose ticker
   now maps to a new CIK (Exxon Mobil).
4. Fetch submissions for sector (`sic`), name and exchange.
5. After the fundamentals are loaded, members with no filing before 30 June of
   `A+1` get `dropout_reason = "not_a_filer_in_anchor_year"`: the frame carried
   their anchor-year revenue as a comparative in a later 10-K (a successor CIK,
   a later IPO or spin-off), so they did not exist as registrants at the start
   of the window.

Selecting on the **start** of the window (not the end) is deliberate: picking
companies that still report in 2024 would exclude everything that failed. One
limit remains: the frame values that rank the anchor year carry no filing
date, and most were filed two to four years later as restated comparatives,
so the ranking itself is not strictly point-in-time.

## Fundamentals (module `Backtest::Fundamentals`)

For every member with a CIK, fetch `companyfacts` and write `pit_facts` rows
for all 10-K **and** 10-Q observations from fiscal 2014 onward (quarterlies are
needed for trailing-twelve-month construction; store them with `form`). Shares
from `dei:EntityCommonStockSharesOutstanding` (`shares_cover`) and
`us-gaap:WeightedAverageNumberOfDilutedSharesOutstanding` (`shares_diluted`).
Keep raw units (USD, shares); scale at use.

## Prices (module `Backtest::Prices`)

For every member with a ticker, fetch Yahoo 10-year monthly bars with their
split events (`split_events`); on failure after retries, fall back to Nasdaq
daily and resample to the last trading day of each month (`adjusted = false`,
no split events: those closes are already unadjusted). Members with no bars get
`dropout_reason = "no_price_history"`. Record counts of each source.

## Method (module `Backtest::Runner`)

Monthly, point-in-time, long-only cross-sectional test of the valuation signal.

* Dates `t`: month-ends from `A+1`-01-31 through the last month-end with a full
  12-month forward window.
* At each `t`, for each member with prices and no dropout reason: the latest
  **annual** (10-K) observations with `filed < t` (a filing dated `t` reaches
  EDGAR after that day's close) and `period_end >= t - 18 months` for
  operating_income and dep_amort; the latest observation of **any form**
  (10-K or 10-Q, same `filed < t` and staleness rules) for cash, short-term
  investments, debt and `shares_cover`; the price at `t`.
  * Market cap uses the **unadjusted** close: Yahoo's `close` is split-adjusted,
    so it is multiplied back by every split dated after `t`; the cover-page
    count is rolled forward through splits between its filing date and `t`;
    a name is skipped in a month that contains a split (Yahoo's month bar
    straddles it). Adjusted closes are for returns only.
  * A `shares_cover` of zero or less (a bond, preferred or cooperative ticker)
    excludes the name.
  * `EBITDA = operating_income + dep_amort`; require `EBITDA > 0`.
  * `net_debt = gross_debt - cash - short_term_investments`, where gross debt
    is `debt_current + debt_noncurrent` when either is known, else
    `debt_total`. Cash **and** a debt line must be known; a name with cash but
    no debt line is excluded rather than treated as debt-free (AT&T carried
    $180bn under a tag the split lines missed). Never zero by default.
  * `EV = close × shares_cover + net_debt`; `multiple = EV / EBITDA`;
    require `0 < multiple < 200`.
* Peer group: 2-digit SIC, if ≥ 8 names have a multiple at `t`; otherwise the
  whole cross-section.
* Signal: `ln(peer_median_multiple / own_multiple)` — positive means cheap
  relative to peers. This is the comps logic the pitch book uses, applied
  cross-sectionally.
* Forward return: `adj_close(t + h) / adj_close(t) - 1` for `h` in 3, 6, 12
  months. Names without a price at `t + h` are **dropped from that date's
  cross-section and counted** (not filled).
* Evaluation per horizon: monthly Spearman rank correlation between signal and
  forward return (the information coefficient); its mean, its standard
  deviation, a t-statistic that adjusts for overlapping windows
  (Newey–West with `h - 1` lags); equal-weight quintile portfolio returns and
  the Q1 (cheap) − Q5 (expensive) spread, annualised, **with its own
  Newey–West t-statistic**; hit rates of the IC and of the spread; the
  equal-weight return of the names that had a signal as the benchmark;
  coverage counts per date and a count of every exclusion reason.
* Results go to `backtest_runs.results` as JSON (with the construction rules
  and biases spelled out) and to a Markdown report with three SVGs (mean IC by
  horizon, 12-month IC by date, 12-month Q1−Q5 spread by date) via `Charts`.

Optional second signal (same evaluation): the default-assumption DCF value per
share from `Valuation.run_dcf` with inputs from the point-in-time facts, as
`ln(dcf_value / close)`.

## Known biases — reported with the results, never silently

* **Survivorship (price leg).** Current tickers only: companies that delisted
  inside the window have fundamentals but no prices and drop out. The report
  states how many anchor-year members had no ticker or no price history, and
  says that the no-ticker count is an upper bound (subsidiaries, predecessor
  CIKs and renamed registrants sit in it). The price panel holds only names
  Yahoo still serves, so forward prices are never missing for a priced name.
* **Universe selection.** The anchor-year frame carries no filing date and
  mostly holds restated values filed years later; members that were not
  filers in the anchor year are dropped and counted, but the ranking itself is
  not strictly point-in-time.
* **Instrument mapping.** The first-listed SEC ticker is taken as the common
  stock and zero-share names are excluded; a residual risk of pricing a class
  other than the one on the cover page remains for multi-class filers.
* **Mixed periods.** Operating income and D&A can come from different fiscal
  years when the newer 10-K lacks a D&A tag, and the balance sheet from a newer
  10-Q than the P&L; both are counted in the results.
* **Restatements.** Each observation carries the date it was filed, and the
  runner uses only rows with `filed <= t`, so a restated value is not seen
  before it existed. Frames (which can carry restated values) are never used
  for signal inputs.
* **Fiscal-year lag.** A 10-K filed in late February is known from its `filed`
  date; the runner never assumes year-end data is available at year-end.
* **Shares timing.** Cover-page counts are as of the filing's cover date;
  between filings the last known count is used, rolled forward through splits.
* **Unadjusted fallback prices.** Nasdaq daily closes are not dividend-adjusted;
  returns for those names understate total return. Flagged per bar and counted.
* **Universe size and tilt.** Top-N by revenue tilts large. `N` is a parameter;
  the report prints the median revenue of the universe.
* **No transaction costs, no shorting, no sector neutralisation beyond the peer
  group definition.** This measures whether the signal ranks, not whether a
  fund could harvest it.

## Rake tasks (`lib/tasks/backtest.rake`)

```
backtest:universe[anchor_year,size]   build universe_members
backtest:fundamentals[anchor_year]    fill pit_facts for every member
backtest:prices[anchor_year]          fill price_bars for every member with a ticker
backtest:acquire[anchor_year,size]    the three in order
backtest:run[name,anchor_year]        evaluate; prints the JSON summary; writes docs/backtests/<name>.md + SVGs
```

Progress goes to stderr; a 600-name acquisition is roughly 1,800 requests and
takes 15–25 minutes the first time, seconds afterwards from the cache.

## Audit trail

The first run (14 October 2026) was reviewed by an independent recomputation
and a methodology audit (docs/AUDIT.md). The audit confirmed the statistics
and found construction defects, all fixed before the second run on 17 October:
split-adjusted closes, zero share counts, one-tag-per-company resolution,
missing debt treated as zero, the shortest-ticker mapping, same-day filings,
non-filers in the anchor year, and a report that omitted the spread's
t-statistic and most of these biases.

## File ownership

`app/services/backtest/universe.rb`, `fundamentals.rb`, `prices.rb`,
`runner.rb`, `report.rb`; `app/services/sources/frames.rb`,
`app/services/sources/price_history.rb`; `lib/tasks/backtest.rake`;
`test/services/backtest_*_test.rb`. Tests use hand-built fixtures and never the
network; the acquisition itself is run once by the task owner and its counts
recorded in the report.
