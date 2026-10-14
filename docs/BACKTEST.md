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
| Prices | `https://query1.finance.yahoo.com/v8/finance/chart/<T>?range=10y&interval=1mo` | `close` and `adjclose` (splits and dividends) per month. |
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
backtest_runs     name, params (JSON), results (JSON), created_at
```

`concept` is one of: `revenue, operating_income, dep_amort, net_income, eps,
cash, short_term_investments, debt_current, debt_noncurrent, shares_cover,
shares_diluted`, resolved through the same tag-preference tables as
`Sources::Sec::TAGS` / `INSTANT_TAGS` (first tag with data wins, per concept,
per company). Store **every** filed observation, not just the latest: a value
restated in a later 10-K is a second row with its own `filed`.

## Universe (module `Backtest::Universe`)

1. Anchor year `A` (default 2016). Take the revenue frame for CY`A` (tag
   `Revenues`, then `RevenueFromContractWithCustomerExcludingAssessedTax`;
   union by CIK, first non-null). Keep US filers (`loc` starts with `US-`).
2. Rank by revenue, take the top `N` (default 600; `UNIVERSE_SIZE`).
3. Join current tickers; CIKs without a ticker are kept as members with
   `dropout_reason = "no_current_ticker"` — they are the companies that
   delisted, merged or went private, and counting them is how the survivorship
   bias is measured rather than ignored.
4. Fetch submissions for sector (`sic`), name and exchange.

Selecting on the **start** of the window (not the end) is deliberate: picking
companies that still report in 2024 would exclude everything that failed.

## Fundamentals (module `Backtest::Fundamentals`)

For every member with a CIK, fetch `companyfacts` and write `pit_facts` rows
for all 10-K **and** 10-Q observations from fiscal 2014 onward (quarterlies are
needed for trailing-twelve-month construction; store them with `form`). Shares
from `dei:EntityCommonStockSharesOutstanding` (`shares_cover`) and
`us-gaap:WeightedAverageNumberOfDilutedSharesOutstanding` (`shares_diluted`).
Keep raw units (USD, shares); scale at use.

## Prices (module `Backtest::Prices`)

For every member with a ticker, fetch Yahoo 10-year monthly bars; on failure
after retries, fall back to Nasdaq daily and resample to the last trading day of
each month (`adjusted = false`). Members with no bars get
`dropout_reason = "no_price_history"`. Record counts of each source.

## Method (module `Backtest::Runner`)

Monthly, point-in-time, long-only cross-sectional test of the valuation signal.

* Dates `t`: month-ends from `A+1`-01-31 through the last month-end with a full
  12-month forward window.
* At each `t`, for each member with prices: the latest **annual** (10-K)
  observations with `filed <= t` and `period_end >= t - 18 months` for
  operating_income, dep_amort, cash, short-term investments, debt; the latest
  `shares_cover` with `filed <= t`; the price at `t` (unadjusted `close` for
  market cap — adjusted closes are for returns only).
  * `EBITDA = operating_income + dep_amort`; require `EBITDA > 0`.
  * `net_debt = debt_current + debt_noncurrent - cash - short_term_investments`
    (missing cash **and** missing debt → skip the name at `t`; never zero).
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
  the Q1 (cheap) − Q5 (expensive) spread, annualised; hit rate of the sign;
  the equal-weight universe return as the benchmark; coverage counts per date.
* Results go to `backtest_runs.results` as JSON and to a Markdown report with
  one SVG (mean IC by horizon, Q1−Q5 cumulative spread) via `Charts`.

Optional second signal (same evaluation): the default-assumption DCF value per
share from `Valuation.run_dcf` with inputs from the point-in-time facts, as
`ln(dcf_value / close)`.

## Known biases — reported with the results, never silently

* **Survivorship (price leg).** Current tickers only: companies that delisted
  inside the window have fundamentals but no prices and drop out. The report
  states how many anchor-year members had no ticker or no price history.
* **Restatements.** Each observation carries the date it was filed, and the
  runner uses only rows with `filed <= t`, so a restated value is not seen
  before it existed. Frames (which can carry restated values) are never used
  for signal inputs.
* **Fiscal-year lag.** A 10-K filed in late February is known from its `filed`
  date; the runner never assumes year-end data is available at year-end.
* **Shares timing.** Cover-page counts are as of the filing's cover date;
  between filings the last known count is used.
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

## File ownership

`app/services/backtest/universe.rb`, `fundamentals.rb`, `prices.rb`,
`runner.rb`, `report.rb`; `app/services/sources/frames.rb`,
`app/services/sources/price_history.rb`; `lib/tasks/backtest.rake`;
`test/services/backtest_*_test.rb`. Tests use hand-built fixtures and never the
network; the acquisition itself is run once by the task owner and its counts
recorded in the report.
