# Audit of Argos, 17 October 2026

## Headline

An investment analyst and two engineering auditors reviewed the project; a third auditor and most of the verification agents did not run (organisation spend limit), so the lead-auditor synthesis below was written by the author from the raw findings, and every finding acted on was reproduced by the author before it was fixed. The Python build is a credible prototype whose data is genuine but whose Itron valuation is overstated by a stale net-debt figure, fiscal-year rather than trailing multiples, a constant WACC and several DCF mechanics; the backtest's statistics were confirmed exactly but its data construction had defects that changed the point estimates without changing the conclusion. The Rails services and the backtest now carry the fixes listed here with regression tests; the Python build does not, and the modules still to be ported carry new binding requirements (docs/RAILS_PORT.md, items 11–22).

## Scope and method

| Reviewer | Ran | What it did |
|---|---|---|
| Investment analyst (ten years buy-side, ex-IB associate persona) | yes | Ran the Python app on the real Itron corpus (`data/real.db`), exercised search, the company page, the deck and the exports; re-derived peer quartiles, the DCF and the EV bridge by hand; read the backtest as a PM would. |
| Rails-port correctness auditor | yes | Diffed every ported Ruby service against the Python reference on the same inputs: 5,220 real chunks, 213 cached filing HTML files, 600 cached companyfacts files, the demo database, one deck exported by both stacks. All 10 Rails test files green (391 runs, 2,873 assertions). |
| Backtest method-and-data auditor | yes | Recomputed every statistic from the stored results (identical to 4 dp), re-implemented the runner in Python (per-date IC within 5e-5), ran 19 mutants against the runner test, ran sensitivities, sampled stored facts against the raw EDGAR files. |
| Claims-and-delivery auditor | no (spend limit) | Was to check README/TUTORIAL claims against reality and boot the Rails server. Its ground is covered partly by the two audits above and by the status section below. |
| Verification skeptics | 2 of 16 | Confirmed the share-count finding and the FTS bootstrap finding; the other 14 findings were reproduced by the author instead (reproduction steps are in the per-finding rows). |

Commands run by the author to verify and fix, from the repository root with `export PATH="/opt/rbenv/versions/3.3.6/bin:$PATH"`:

```
ARGOS_TEST_DB=storage/test-<name>.sqlite3 PARALLEL_WORKERS=1 bin/rails test test/services/<file>_test.rb
bin/rails "backtest:universe[2016,600]" && bin/rails "backtest:fundamentals[2016]" && bin/rails "backtest:prices[2016]" && bin/rails "backtest:run[comps-2016,2016]"
```

## Status: what exists and works

| Component | State on 17 October 2026 |
|---|---|
| Python application (`argos/`) | Complete and runnable; the only product with a UI today. Carries every valuation defect below; retained as the reference until the Rails port reaches parity, then deleted. |
| Rails services ported and green | Nlp, Charts, Valuation (+DcfAssumptions), Sources::{Http,HtmlText,Market,Sec}, Exporters::{Pptx,Pdf}, Ingest, Seed::Demo, SearchIndex, Backtest::* (12 test files, all green after this audit's fixes). |
| Rails modules not yet ported | Search, Analytics, Pitchbooks (slide builders), Exporters::Html and the deck views, the web UI (controllers, views, CSS, JS), the JSON API controllers, `lib/tasks/argos.rake`. `bin/rails server` boots but serves no product page. |
| Real data | `data/real.db`: 7 companies (ITRI BMI XYL TRMB VNT ZBRA WTS), 49 documents (21 10-K/10-Q filings, 28 8-K press releases), six fiscal years each, one quote per name dated 12 October 2026. Itron FY2024 revenue $2,440.8m and net income $239.1m match the filed figures. |
| Backtest data | 600-member 2016 universe; after this audit 488,857 point-in-time facts, 51,862 monthly bars, 120 split events; results in `docs/backtests/comps-2016.md`. |

## Confirmed defects and what was done

Severity: critical = a wrong number in a published result or a security problem; high = a wrong number shown to a user; medium = a wrong number in an edge case or a misleading output; low = cosmetic or latent. "Fixed" means fixed in the Rails code with a regression test in this commit.

### Valuation (analyst findings, reproduced by the author)

| Sev. | Where | Finding | Action |
|---|---|---|---|
| blocker | `argos/sources/sec.py:430`, `app/services/sources/sec.rb` | Net debt read from the last fiscal year end ($228m, Dec-2025) while the price is from Oct-2026; the Jun-2026 10-Q in the corpus shows cash 745.2 and debt 1,575.2 (net debt ≈ $830m) plus $21.9m NCI. EV/EBITDA 11.0x should be ≈ 12.7x, DCF base $89 → ≈ $75. | Fixed in Rails: `Sources::Sec.latest_balance_sheet` reads the newest 10-K or 10-Q at one date, stores `net_debt_as_of`, `balance_sheet_form`, `minority_interest`, `preferred_equity`; `Valuation` bridges EV through net debt plus other claims and reports the dates. Python unchanged. |
| blocker | `argos/valuation.py:75`, `sec.py` | No LTM or NTM multiples; every multiple is on the last fiscal year, nine months stale for Itron. | Fixed in Rails for LTM: `build_financials` adds a `period_type: "LTM"` row (FY + YTD − prior YTD from the latest 10-Q; D&A falls back to the FY figure); `Valuation` quotes on it when present and labels the basis. NTM needs a consensus or guidance input and is not built. |
| high | `argos/valuation.py:550` | WACC is a constant (9.5% + 2pts per unit of beta, beta never loaded); 73% of DCF value is terminal. | Fixed in Rails: `Valuation.wacc_build` (CAPM cost of equity, risk-free + spread for debt, market weights, after-tax), echoed with notes ("beta not loaded" when assumed). Inputs are house defaults, stated as such. |
| high | `argos/valuation.py:297` (`valuation.rb:229`) | ΔNWC charged as intensity × revenue level, so flat revenue tied up $42m a year for Itron. | Fixed: ΔNWC = intensity × change in revenue; zero at zero growth; terminal year on terminal growth. |
| high | `argos/valuation.py:470-508` | The 52-week trading range was averaged into the concluded range as if it were a methodology; EV/Revenue given full weight for a margin outlier. | Fixed: the 52-week bar is `reference: true` and never in the conclusion; an EV/Revenue bar on a target whose margin lies outside the peer interquartile range is shown with a note and excluded. The conclusion lists the methods it rests on and is nil when none remain. |
| high | `argos/valuation.py:546-554` | No valuation date: a full first projected year discounted from a fiscal year end while the price is nine months later. | Fixed: `stub_fraction` from the price date to the first projected year end; year 1 counts only its remainder; every flow and the terminal value are discounted from the valuation date. |
| medium | `argos/valuation.py:327` (`valuation.rb:263`) | Exit-multiple terminal value discounted at N − ½ under the mid-year convention. | Fixed: exit multiple at N; Gordon stays at N − ½ (mid-year flows). Implied exit multiple and implied growth are returned as cross-checks. |
| medium | `argos/valuation.py:318` | Growth path flips a negative first year straight to +2.5% in year 2. | Fixed: linear interpolation from year 1 to the terminal rate, whatever the sign. |
| medium | DCF defaults | Terminal capex below D&A forever. | Fixed: terminal-year capex floored at D&A (`terminal_capex_floor`, default on, switchable). |
| medium | `app/services/valuation.rb:470` | The Rails DCF bridged unknown net debt at zero and a missing share count at one share. | Fixed: nil stays nil; the DCF returns an enterprise value, `bridge_note`, no per-share value; the football field omits the DCF bar and says why. |
| medium | `argos/sources/sec.py:149-166` | Tags resolved once per company ("first tag with any data"): Xylem lost its current-debt line, Badger Meter had no net debt at all. | Fixed in Rails: `duration_entries` / `instant_entries` resolve per year and per date in preference order; `debt_total`, `MinorityInterest` and `PreferredStockValue` tags added; a filer with no debt line is bridged at zero debt with `debt_note` set. |
| high (confirmed by skeptic) | `app/services/sources/sec.rb:187-193` | The Rails diluted share count took the newest weighted-diluted fact with no recency or scale check: LyondellBasell FY2011's 572m, McDonald's "716 shares", 29 of 523 filers off by more than 2×. | Fixed: used only when from the latest fiscal year and within 0.5–2× of the cover count; otherwise the cover page, with `basis` and `fallback_reason` returned. |

Not fixed, by design or scope: adjusted EBITDA normalisation across peers (SBC, restructuring), a treasury-stock-method diluted count with convertible tests, pension and lease policy, NTM multiples from consensus, LBO and premiums-paid pages, analyst targets, named strategic and sponsor buyer screens. These are listed for the pitch-book port as items 16–22 of `docs/RAILS_PORT.md` or as product work below.

### Backtest (auditor findings, reproduced by the author)

| Sev. | Where | Finding | Action |
|---|---|---|---|
| high | `backtest/universe.rb` ticker map | Kept the shortest ticker per CIK: Comcast priced as CCZ (a note), TVA as TVC (a bond), CHS as CHSCL (a preferred); TVC and CHSCL sat in the cheapest quintile on all 105 dates with zero shares. | Fixed: first-listed ticker; names with a cover count ≤ 0 excluded (213 name-dates). |
| high | `backtest/runner.rb` net debt | Missing debt set to zero whenever cash was known: 17.7% of observations, AT&T at 2.4x with $180bn of debt ignored. | Fixed: a debt line (split lines or a total-debt tag) and a cash line are both required; `debt_total` concept added with `LongTermDebt`-type tags; 554 name-dates now excluded as `no_debt_line` instead of mis-valued. |
| high (known) | prices | Yahoo's `close` is split-adjusted, so market cap was understated before splits (about 93 of 454 names). | Fixed: split events fetched (`events=splits`, table `split_events`), close multiplied back for splits after t, cover count rolled forward through splits between filing and t, split months skipped (97 name-dates). |
| high (known) | fundamentals | One tag per company for all years dropped years after a tag switch and names with rarer D&A tags. | Fixed: per-period tag resolution, `DepreciationAmortizationAndOther`, Depreciation + AmortizationOfIntangibleAssets sums. Coverage rose from 230 to 263 names per date; facts from 463,671 to 488,857. |
| high | `test/services/backtest_runner_test.rb` | 14 of 19 mutants passed: backward windows, off-by-one months, next-month price look-ahead, 14-day filing look-ahead were all invisible to the fixture. | Fixed: a hand-computed cross-section with exact expected multiples, signals, IC of 1.0 at every horizon only for the true forward window, a filing dated t, a split name, and zero-share and no-debt names. |
| medium | universe selection | The 2016 frame values were filed in 2018–2020 (566 of 600) and 17 members did not exist as filers in 2016. | Fixed in part: members with no filing before 30 June 2017 are dropped as `not_a_filer_in_anchor_year` (13); the ranking-on-restated-values limit is now stated in the method and the biases. |
| medium | report | `no_current_ticker` presented as a survivorship count though it holds Exxon (new CIK), BNSF and other debt-only subsidiaries; price panel is survivor-only. | Wording fixed everywhere it appears; stated as an upper bound. |
| medium | report | Q1−Q5 spreads shown without t-statistics (0.73/0.76/1.24, insignificant); bias list omitted most known defects. | Fixed: spread t-statistics and hit rates, construction rules, exclusion counts, a spread chart, and an honest bias list are printed with every run. |
| low | runner | Same-day filings used at that day's close (458 name-dates). | Fixed: `filed < t` everywhere, including `PitFact.known_on`. |
| low | runner | EBITDA mixes fiscal years when the newer 10-K lacks D&A (145 name-dates); balance sheet from a different date than the P&L. | Counted and reported, not excluded; documented. |

Result after the fixes (run 3, 105 month-ends 2017-01 to 2025-09, 263 names per date):

| Horizon | Mean IC | t (NW) | IC hit rate | Q1−Q5 ann. | t spread |
|---|---:|---:|---:|---:|---:|
| 3m | −0.033 | −1.24 | 36% | −1.9% | −0.42 |
| 6m | −0.044 | −1.25 | 32% | −1.8% | −0.36 |
| 12m | −0.045 | −1.04 | 34% | −1.3% | −0.28 |

The first run's point estimates (−0.003, −0.001, +0.011) moved to small negatives once the mis-mapped instruments, the zero-debt names and the split-understated market caps were removed; nothing is significant at any horizon. The conclusion stands and is slightly stronger: an unconditional cheap-versus-peers EV/EBITDA gap did not rank forward returns in this universe, so a comps bar must never be described as upside.

### Rails port (auditor findings, reproduced by the author)

| Sev. | Where | Finding | Action |
|---|---|---|---|
| low→medium (confirmed) | `search_index.rb` | A database built from `schema.rb` has no FTS table; chunks ingested before `ensure!` were never indexed and deleting them raised `SQLite3::CorruptException`. | Fixed: `ensure!` rebuilds when the table is new or its row count disagrees with `chunks`; `Ingest` calls it before the first write. |
| medium | `exporters/pptx.rb:126`, `pdf.rb:136` | `Kernel#format` rounds half-up on the shortest decimal (29.95 → 30.0) where Python and the HTML say 29.9. | Fixed: both use `Charts.fixed`. |
| medium | `nlp.rb` KPI patterns | Minus signs dropped: "-$12 million" stored as +12; the test guarding it could never fail. | Fixed: sign captured before or after the currency symbol and as "negative"; negative FCF and margins kept, negative backlog rejected; the test now asserts the sign. |
| low | `html_text.rb` | Words glued on stray or misnested close tags and whitespace-only spans ("theFASB", 57 Ruby-only cases in 213 filings). | Fixed with tests. |
| low | `exporters/pdf.rb` | Non-Windows-1252 characters printed as "?", so quoted filing passages were not verbatim. | Fixed: DejaVu Sans TrueType when present (glyph-checked), Helvetica transliteration otherwise. |
| low | `seed/demo.rb` | `Float#round` drift from the Python seed in two rows. | Fixed: Python-compatible rounding. |
| low | `docs/RAILS_PORT.md` | KPI bounds wording disagreed with the code. | Contract updated (item 6). |

### Refuted or narrowed

* "`db:prepare` leaves chunks unindexed": refuted by the skeptic; `db:prepare` seeds, and the seeder calls `ensure!` first. The defect needed `schema:load` followed by an ingest, which is now handled anyway.
* "The Rails tests merely run code": mostly refuted. The suite pins reference values and verifies the deck with python-pptx; the two tautological or weak spots (the KPI sign test, the seed spot-check) are fixed.

## Analyst gap review

Accepted and turned into work (fixed where marked):

| Area | Gap | Disposition |
|---|---|---|
| Valuation | Stale net debt, no LTM, constant WACC, NWC and terminal mechanics, valuation date, 52-week in the conclusion | Fixed in Rails (above). |
| Pitch book | Circular peer selection (sector label stamped by the loader), buyers list = comp set, no ability-to-pay | Binding on the `Pitchbooks` port: seed comps from the issuer's 10-K peer group and competitor mentions in the corpus; named strategics from competitor lists; ability-to-pay before "cash offer" wording (RAILS_PORT items 16, 19). |
| Pitch book | Missing pages: share-price performance, WACC build, DCF bridge with D&A and ΔNWC, implied exit multiple, premiums paid, LBO, analyst targets | WACC build, DCF bridge rows and cross-checks exist in the service now and must be rendered (item 18); share-price performance is cheap once price history is stored; LBO, premiums-paid and analyst targets are product work beyond the contract. |
| Research terminal | Only filings and 8-K exhibits; no transcripts, broker research, expert calls; 10-Q text gutted in the shipped Python corpus | The extractor is fixed in Rails (defect 1) and the corpus must be reloaded with it; transcripts need a source or upload (product decision). |
| Research terminal | KPI tiles read segment and table rows as company KPIs (Itron "gross margin 29.9%" is a segment column; headline adjusted GM 41.4%) | Binding (item 20); needs table-row and segment detection plus a period label. |
| Research terminal | Theme bigrams are junk on real filings ("loss net", "east conflict"); hard-coded narrative sentence | Binding (item 19). |
| Search | Totals disagree with facets ("tariff" 15 vs 28); one value per field filter; no `date:` | Binding (items 5 and 21). |
| Alerts | Pull-only, capped at 10, no scheduler | Product work; out of the port contract. |
| Backtest | Does not test the deck's claim (hand-picked peers, margin-adjusted value, M&A outcomes); report stale against its data store | Re-run on the current data (done, run 3); conditioned and M&A legs are listed as next steps below. |
| Workflow | Shipped deck and exports disagree with current code ("median n/a premium"); no data/code stamp | Binding (item 22); the shipped Python deck is to be regenerated or removed with the Python tree. |

Disputed in part: the analyst's "15–20% of a day's AlphaSense use" is a judgement, not a measurement, and the gap list treats a filings-only corpus as a defect where it is a data-licensing boundary. The gaps themselves stand.

## Finance errors and the correct treatment

Each error below is in the Python build; the Rails treatment is what the code now does.

| Error | Correct treatment (now in Rails) |
|---|---|
| ΔNWC = intensity × revenue level | ΔNWC = intensity × (Rev_t − Rev_{t−1}); terminal ΔNWC on terminal growth |
| Growth max(terminal, g × (1 − fade)) flips sign in year 2 | Linear interpolation from year-1 growth to terminal growth |
| Exit-multiple TV at N − ½ | Exit multiple at N; Gordon at N − ½ under the mid-year convention; implied exit multiple and implied growth shown |
| Terminal capex below D&A | Terminal capex floored at D&A (switchable) |
| No valuation date | Stub fraction from the price date; partial-period discounting |
| EV = market cap + (debt − cash) from the last FY | EV = market cap + latest-balance-sheet net debt + NCI + preferred, dated; unknown net debt → no bridge |
| WACC constant | CAPM build with stated inputs and weights |
| Concluded range averages the 52-week range and a revenue multiple on a margin outlier | Reference bars excluded; revenue multiple excluded when the margin is outside the peer IQR |
| Multiples on the last fiscal year | LTM when a 10-Q allows, labelled; NTM still absent |

Still open in both stacks: GAAP EBITDA without a consistent adjusted definition across peers; basic cover count used where a treasury-stock-method diluted count is wanted; P/E on GAAP EPS.

## Backtest: is the stated conclusion trustworthy?

Yes, as stated, and more so after the re-run. The statistics were reproduced exactly by an independent implementation; every sensitivity the auditor ran (filing lags, excluded instruments, 10-K-only balance sheets, required debt, ±1-month windows) kept |t| ≤ 0.65 on the first run, and the corrected construction gives |t| ≤ 1.25 with the sign now negative. What the result does not say: whether a margin- or growth-conditioned relative-value signal works, whether hand-picked sub-industry peers behave differently, or whether cheapness predicts takeover incidence or premia, which is the question a sell-side M&A deck actually raises. Those are the next legs, and until they are run the comps page may say "implied value at peer multiples" and may not say "upside".

## Recommendations, in order

1. Port `Pitchbooks` and the deck views against `docs/RAILS_PORT.md` items 7 and 16–22, rendering `basis_label`, the EV bridge dates, the WACC build and the terminal-year row from the service output.
2. Port `Search` with document-level totals, multi-value filters and `date:` (items 5, 21), then `Analytics`, the API and the web UI; reload the real corpus with the fixed extractor and delete `argos/`.
3. Add table-row and segment detection to KPI extraction and a period label on every tile (item 20) in `app/services/nlp.rb` and `ingest.rb`.
4. Seed comp sets from the issuer's 10-K peer group and competitor mentions, and build a buyers list with ability-to-pay, in the `Pitchbooks` port.
5. Add an NTM input (guidance or consensus) to `financials` as estimate rows and quote NTM EV/EBITDA beside LTM in `Valuation`.
6. Run the conditioned backtest legs (margin-residual signal, sub-industry peers, an M&A incidence leg that keeps delisted names) in `app/services/backtest/runner.rb` before any deck language changes from "implied value" to anything stronger.
7. Normalise EBITDA across peers (one stated policy on SBC and restructuring) and add a treasury-stock-method share count in `Sources::Sec` and `Valuation`.
8. Stamp every deck with data, price and code dates and regenerate or remove the shipped Python deck and exports (item 22).

## Open questions for the author

* Should the product's "no debt line tagged" case be bridged at zero debt with a note (current) or excluded as the backtest does? The two stacks now differ deliberately; a single policy would be cleaner.
* Is a consensus or guidance feed acceptable for NTM, or should NTM stay out until a licensed source exists?
* Which transcript source, if any, is in scope for the research terminal?
