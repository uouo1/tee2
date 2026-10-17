# Backtest: comps-2016

Run 3 on 2026-10-17. Method: `docs/BACKTEST.md`.

## Universe and data

| | |
|---|---:|
| Anchor year | 2016 |
| Members selected | 600 |
| With a current ticker | 454 |
| Dropped: no current ticker (upper bound on delistings; includes debt-only subsidiaries and renamed CIKs) | 146 |
| Dropped: not a filer in the anchor year | 13 |
| Dropped: no price history | 0 |
| **Priced and evaluated** | **441** |
| Names that received a signal on at least one date | 302 |
| Median anchor-year revenue | $9.0bn |
| Point-in-time fact rows | 488857 |
| Price bars | 51862 (0 unadjusted fallback) |
| Split events applied | 120 |
| Dates | 2017-01-31 → 2025-09-30 (105 month-ends) |

## Construction rules

- A fact is known from the day after it was filed (filed < t), never on its filing date.
- Operating income and D&A come from 10-K rows only; cash, investments, debt and the cover-page share count from the latest filing of any form.
- Inputs older than 18 months are not used.
- Market cap = unadjusted close × cover-page shares: Yahoo's split-adjusted close is multiplied back by every split after t, the share count is rolled forward through splits between its filing date and t, and a name is skipped in a month that contains a split.
- A share count of zero or less (a bond or preferred ticker) excludes the name.
- Net debt needs a known cash line and a known debt line (current or non-current, else a total-debt tag); a name with cash but no debt line is excluded rather than treated as debt-free.
- EBITDA must be positive and 0 < EV/EBITDA < 200.
- Peer group is the 2-digit SIC when it has at least 8 names with a multiple, otherwise the whole cross-section; the signal is ln(median of the OTHER names' multiples / own multiple).
- Forward return = adj_close(t+h) / adj_close(t) − 1; a date needs at least 20 names.

## Why names drop out of a cross-section (name-dates, all dates)

| Reason | Name-dates |
|---|---:|
| ebitda_mixed_periods (operating income and D&A from different years; counted, not excluded) | 145 |
| multiple_out_of_range | 134 |
| no_cash | 116 |
| no_debt_line | 554 |
| no_dep_amort | 1634 |
| no_operating_income | 9855 |
| no_price | 563 |
| no_shares | 4452 |
| non_positive_ebitda | 1036 |
| non_positive_shares | 213 |
| split_in_month | 97 |

## Results — comps signal, long-only cross-section

Signal: `ln(peer median EV/EBITDA / own EV/EBITDA)`; positive = cheap versus peers. IC is the Spearman rank correlation between the signal and the forward return across names on one date; the t-statistic uses Newey–West with h−1 lags for the overlapping windows.

| Horizon | Dates | Avg names | Mean IC | SD IC | t IC (NW) | IC hit rate | Q1 (cheap) | Q5 (rich) | Q1−Q5 ann. | t spread (NW) | Names-with-signal ann. |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 3m | 105 | 263.3 | -0.0328 | 0.187 | -1.24 | 36.2% | +3.4% | +3.9% | -1.9% | -0.42 | +14.3% |
| 6m | 105 | 263.3 | -0.0436 | 0.1834 | -1.25 | 32.4% | +7.2% | +8.1% | -1.8% | -0.36 | +14.4% |
| 12m | 105 | 263.3 | -0.0449 | 0.1695 | -1.04 | 34.3% | +15.5% | +16.9% | -1.3% | -0.28 | +14.5% |

![Mean IC by horizon](comps-2016-ic-by-horizon.svg)

![12-month IC by date](comps-2016-ic-12m.svg)

![12-month Q1−Q5 spread by date](comps-2016-spread-12m.svg)

## How to read it

A mean IC near zero with a t-statistic inside ±2 means the signal did not rank future returns in this sample. A positive IC with |t| above 2 and a hit rate well above 50% would be evidence that cheap-versus-peers, as the pitch book defines it, carried information — before costs, in this universe, over this window. The Q1−Q5 column is the mean return of the cheapest fifth minus the richest fifth; read it with its own t-statistic, which adjusts for the overlapping windows, not on its own. A hit rate below 50% beside a positive mean IC means a few dates carry the mean. The last column is the equal-weight return of the names that had a signal on each date, not of the whole universe.

## Known biases (stated, not hidden)

- Survivorship in the price leg: only members with a current ticker that Yahoo still serves have returns. `no_current_ticker` is an upper bound on delistings, not a clean count: it also holds debt-only subsidiaries, predecessor CIKs and registrants whose ticker now maps to a new CIK (Exxon Mobil). Forward prices are never missing for a priced name, which is the same fact seen from the other side.
- Universe selection: the revenue frame that ranks the anchor year carries no filing date and mostly holds values filed two to four years later as restated comparatives, so the ranking is not strictly point-in-time. Members with no filing before mid-way through the following year are dropped as `not_a_filer_in_anchor_year` and counted.
- Point-in-time: only facts with filed < t are used, so restatements are not seen before they existed and nothing filed on t is used at t's close.
- Fiscal-year lag: annual figures become usable on their filing date, not at period end; figures older than 18 months are not used. Operating income and D&A can come from different fiscal years when the newer 10-K lacks a D&A tag (counted in `exclusions`/`data`), and balance-sheet items from a newer 10-Q than the P&L.
- Share counts are the cover-page figure known at t, rolled forward through splits; between filings the last known count is used.
- Instrument mapping: the first-listed SEC ticker is taken as the common stock; names whose cover-page count is zero or negative (bonds, preferreds, cooperatives) are excluded.
- Names with a cash line but no debt line are excluded, not treated as debt-free; names with neither are excluded too. Both choices shrink the cross-section.
- Unadjusted Nasdaq fallback bars understate total return; their count is in `data.unadjusted_bars`.
- Top-N by revenue tilts the universe large; the median anchor revenue is reported.
- No transaction costs, no shorting, no sector neutralisation beyond the peer-group signal; the result says whether the signal ranks, not whether it could be harvested.

