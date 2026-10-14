# Backtest: comps-2016

Run 1 on 2026-10-14. Method: `docs/BACKTEST.md`.

## Universe and data

| | |
|---|---:|
| Anchor year | 2016 |
| Members selected | 600 |
| With a current ticker | 454 |
| Dropped: no current ticker | 146 |
| Dropped: no price history | 0 |
| **Priced and evaluated** | **454** |
| Median anchor-year revenue | $9.0bn |
| Point-in-time fact rows | 388134 |
| Price bars | 52892 (0 unadjusted fallback) |
| Dates | 2017-01-31 → 2025-09-30 (105 month-ends) |

## Results — comps signal, long-only cross-section

Signal: `ln(peer median EV/EBITDA / own EV/EBITDA)`; positive = cheap versus peers. IC is the Spearman rank correlation between the signal and the forward return across names on one date; the t-statistic uses Newey–West with h−1 lags for the overlapping windows.

| Horizon | Dates | Avg names | Mean IC | SD IC | t (NW) | Hit rate | Q1 (cheap) | Q5 (rich) | Q1−Q5 ann. | Universe ann. |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 3m | 105 | 230.2 | -0.0034 | 0.1428 | -0.17 | +45.7% | +4.0% | +3.3% | +2.8% | +13.9% |
| 6m | 105 | 230.2 | -0.0008 | 0.1345 | -0.03 | +43.8% | +8.4% | +6.9% | +3.0% | +14.0% |
| 12m | 105 | 230.2 | 0.0109 | 0.1174 | 0.41 | +40.0% | +17.5% | +13.3% | +4.1% | +14.1% |

![Mean IC by horizon](comps-2016-ic-by-horizon.svg)

![12-month IC by date](comps-2016-ic-12m.svg)

## How to read it

A mean IC near zero with a t-statistic inside ±2 means the signal did not rank future returns in this sample. A positive IC with |t| above 2 and a hit rate well above 50% would be evidence that cheap-versus-peers, as the pitch book defines it, carried information — before costs, in this universe, over this window.

## Known biases (stated, not hidden)

- Survivorship in the price leg: members without a current ticker or price history are excluded from returns; their counts are in `universe`.
- Point-in-time: only facts with filed <= t are used, so restatements are not seen before they existed.
- Fiscal-year lag: annual figures become usable on their filing date, not at period end; figures older than 18 months are not used.
- Share counts are the latest cover-page figure known at t.
- Unadjusted Nasdaq fallback bars understate total return; their count is in `data.unadjusted_bars`.
- Top-N by revenue tilts the universe large; the median anchor revenue is reported.
- No transaction costs, no shorting, no sector neutralisation beyond the peer-group signal.

