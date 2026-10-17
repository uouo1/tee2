# Tutorial: from an empty database to a pitch book, on real SEC data

This walks through one complete session with Argos using live public data:
seven US-listed companies, their actual filed financials, their 10-Ks, 10-Qs
and earnings releases, and a current quote. By the end you will have a
searchable corpus of 49 real filings and an exported pitch book for Itron,
Inc. (NASDAQ: ITRI) — and, more usefully, you will know what every number on
its valuation page is made of.

Everything below was run on 12–13 October 2026. Prices move and companies file,
so your figures will differ in detail; the shape of the exercise will not.

> **Read before trusting the numbers (added 17 October 2026).** An
> investment-analyst audit of this tutorial's output (`docs/AUDIT.md`) found
> that the Itron valuation below is overstated: net debt was read from the
> December 2025 10-K ($228m) while the June 2026 10-Q in the same corpus shows
> about $830m after a $600m convertible, so EV/EBITDA is nearer 12.7x than
> 11.0x and the DCF base nearer $75 than $89; the multiples are on fiscal 2025
> rather than the latest twelve months; the WACC is a constant; and the
> "+13% to +86%" wording treats a peer-multiple range as upside, which the
> repository's own backtest does not support. The Rails services in `app/`
> correct the mechanics (`docs/RAILS_PORT.md`, items 11–22); the Python build
> this tutorial drives does not. The search count "15 documents" for `tariff`
> is also a known artefact of top-k chunk ranking (its facet says 28).

> **Data sources.** Fundamentals and filings come from SEC EDGAR's public APIs
> (`data.sec.gov`, `sec.gov/Archives`). The quote comes from a public quote
> endpoint. Neither is a licensed data feed: fine for learning and for internal
> work, not something to redistribute as a product. SEC asks automated clients
> to identify themselves — set `ARGOS_USER_AGENT="YourName your@email"` before
> loading at any volume.

---

## 0. Setup (two minutes)

```bash
git clone -b claude/alpha-sense-pitch-book-7wu8xc https://github.com/uouo1/tee2.git
cd tee2
pip install -r requirements.txt     # optional: only for PowerPoint and PDF export
python3 -m unittest discover -s tests -t .
```

Argos needs nothing beyond Python 3.11+ for search, valuation, the web UI and
HTML export. The suite should report `OK`.

We will keep the real data in its own database file so the synthetic demo
corpus (`argos seed`) stays available for comparison:

```bash
export ARGOS_DB=data/real.db
```

---

## 1. Load a target and its peers from EDGAR

Itron sells smart meters and grid-edge software to utilities. A defensible
trading-comp set is companies that sell measurement and control technology into
utility and industrial customers: Badger Meter (BMI), Xylem (XYL), Trimble
(TRMB), Vontier (VNT), Zebra Technologies (ZBRA) and Watts Water (WTS). All are
SEC filers, so one command loads all of them:

```bash
python3 -m argos load-sec ITRI BMI XYL TRMB VNT ZBRA WTS \
    --sector "Smart Infrastructure & Measurement"
```

Three minutes later (downloads are cached under `data/cache/`, so a re-run takes
seconds):

```json
{
  "companies": 7,
  "documents_added": 49,
  "failures": [],
  "loaded": [
    {"ticker": "ITRI", "name": "Itron, Inc.", "cik": "0000780571",
     "fiscal_years": [2020, 2021, 2022, 2023, 2024, 2025],
     "latest_revenue": 2367.2, "share_price": 85.57, "documents_added": 7},
    ...
  ]
}
```

### What just happened

For each ticker the loader did four things, and it is worth knowing which
number came from where, because that is what makes the deck defensible later.

**1. Resolved the company.** `sec.gov/files/company_tickers.json` maps ITRI to
CIK 780571. The submissions feed supplies the legal name, SIC code and business
address. `--sector` overrides the SIC description with one label for the whole
set, which is what the comp-suggestion and precedent-transaction screens key on.

**2. Pulled six years of fundamentals from XBRL**, not from parsed text. The
`companyfacts` API carries every tagged value the company ever filed. The loader
selects, per fiscal year, the **full-year** value (330–400 day spans, so a
fourth-quarter figure is never mistaken for a year) from the **most recently
filed** 10-K (so restatements win), using a preference order of tags because
filers tag the same line differently:

| Concept | Tags tried, in order |
|---|---|
| Revenue | `RevenueFromContractWithCustomerExcludingAssessedTax`, `Revenues`, `SalesRevenueNet` … |
| EBIT | `OperatingIncomeLoss` |
| D&A | `DepreciationDepletionAndAmortization` …, else `Depreciation` + `AmortizationOfIntangibleAssets` |
| Net income, EPS, capex, pre-tax income, tax | the usual `us-gaap` tags |
| Net debt | `LongTermDebtCurrent` + `LongTermDebtNoncurrent` − cash − short-term investments, at fiscal year end |
| Shares | cover-page `EntityCommonStockSharesOutstanding`, else weighted diluted (multi-class filers) |

**EBITDA is operating income plus D&A.** That is the standard proxy and it is
*not* the "adjusted EBITDA" a company reports in its own release (which adds
back stock compensation, restructuring and so on). Keep that in mind when you
compare the multiples below to a broker's.

Here is what came back for Itron (USD millions, fiscal years to 31 December):

| FY | Revenue | EBITDA | EBIT | Net income | EPS | Capex | Tax rate |
|---|---:|---:|---:|---:|---:|---:|---:|
| 2020 | 2,173.3 | 86.9 | −10.4 | −58.0 | −1.44 | 46.2 | — |
| 2021 | 1,981.6 | 4.9 | −79.3 | −81.3 | −1.83 | 34.7 | — |
| 2022 | 1,795.6 | 59.3 | −7.4 | −9.7 | −0.22 | 19.7 | — |
| 2023 | 2,173.6 | 184.6 | 128.9 | 96.9 | 2.11 | 26.9 | 22.8% |
| 2024 | 2,440.8 | 320.4 | 264.1 | 239.1 | 5.18 | 30.6 | 15.3% |
| 2025 | 2,367.2 | 362.6 | 313.1 | 301.1 | 6.50 | 22.9 | 11.4% |

Net debt at FY2025: $1,248.3m of debt (convertible notes, current and
non-current) less $1,020.4m of cash = **$227.9m**. Shares outstanding from the
latest cover page: **43.79m**.

**3. Fetched a quote**: $85.57 on 12 October 2026, 52-week range $77.77–$142.00.

**4. Downloaded the filings and indexed them.** The latest 10-K, the two most
recent 10-Qs and the four most recent 8-K earnings releases (the loader finds
the EX-99.1 exhibit inside each 8-K; filers name that file every way
imaginable). Each document is converted from inline-XBRL HTML to paragraphs,
chunked, scored for tone, scanned for KPIs and indexed in FTS5. The 49 documents
became 5,220 searchable passages and 133 extracted metrics.

Check the result:

```bash
python3 -m argos stats
```

---

## 2. Research the target

Start the application on the real database and open <http://127.0.0.1:8787>:

```bash
python3 -m argos serve
```

![Dashboard on real data](docs/images/real-dashboard.png)

### A search that pays off immediately

Go to **Research** and search `backlog ticker:ITRI`.

![Backlog search](docs/images/real-research.png)

Four documents match. The summary card at the top has done the first hour of an
analyst's work: it has pulled, from three consecutive earnings releases, the
sentences that carry the number —

> Backlog at quarter end was $4.5 billion compared with $4.7 billion in the prior year. *(8-K, 17 Feb 2026)*
> Backlog at quarter end was $4.4 billion compared with $4.7 billion in the prior year. *(8-K, 28 Apr 2026)*
> Backlog at quarter end was $4.4 billion compared with $4.5 billion in the prior year. *(8-K, 28 Jul 2026)*

— and, from the 10-K, the caveat that backlog includes contracts with
termination-for-convenience clauses. That is the research finding and its
footnote, each traceable to an accession number.

Notice the line under the result count: `matched on ("backlog" OR "rpo" OR
"remaining performance obligations" OR "order book")`. Synonym expansion is on
by default because filings and analysts use different words for the same
thing; untick **Expand synonyms** to see only literal matches.

Try a few more. `tariff` finds 15 documents across the set — Watts, Badger
Meter and Xylem all discuss reciprocal tariffs and the Supreme Court case in
their 2026 10-Qs. `margin expansion type:press-release` surfaces Vontier's
guidance language ("adjusted operating profit margin expansion of approximately
110 basis points"). `"data center" OR datacenter` shows Badger Meter attributing
component demand to hyperscale build-out.

Click any result: the reader on the right shows the whole document, the metrics
parsed from it, per-passage tone, nearest-neighbour filings, and a **Pin to
deck** button on every passage. We will use that in step 5.

### The company page

**Companies → ITRI**:

![Itron company page](docs/images/real-company.png)

Tiles show the live capital structure — $85.57, market cap $3.7bn, EV $4.0bn,
11.0x EV/EBITDA, 15.3% margin. The revenue chart shows the FY2021–22 trough and
recovery; the margin chart shows the expansion from 4% to 15% that is the whole
Itron equity story. Below are the KPIs extracted from narrative text (gross
margin observed 24 times, backlog five times, free cash flow six) with the
sentence each came from.

---

## 3. Generate the pitch book

From the company page, **Generate deck**, or from the command line:

```bash
python3 -m argos pitchbook ITRI --title "Project Meter" \
    --client "Board of Itron, Inc." --banker "Argos Advisory" \
    --comps BMI,XYL,TRMB,VNT,ZBRA,WTS --export pptx
```

```
pitchbook 1: Project Meter — 14 slides
   0  cover                  Project Meter
   1  disclaimer             Disclaimer
   2  executive_summary      Executive summary
   3  company_overview       Itron, Inc. — company overview
   4  market_overview        Smart Infrastructure & Measurement — market overview
   5  financial_performance  Itron, Inc. — financial performance
   6  valuation_summary      Valuation summary
   7  trading_comps          Trading comparables
   8  precedent_transactions Precedent transactions
   9  dcf                    Discounted cash flow analysis
  10  dcf_sensitivity        DCF sensitivity
  11  buyers                 Potential counterparties
  12  process                Process considerations and next steps
  13  evidence_appendix      Appendix — sources and evidence
exported: data/exports/pitchbook-1.pptx
```

Open **Pitch books** in the UI to read it. The executive summary quotes the
corpus — the three backlog sentences above appear with their document ids — and
the market overview is the theme model run across the whole set.

![Executive summary](docs/images/real-execsummary.png)

---

## 4. Read the valuation page like a banker

![Valuation summary](docs/images/real-valuation.png)

This is the slide that matters, so here is every bar.

**Trading comps — EV/EBITDA: $115–$176.** The six peers trade between 9.6x
(Vontier) and 23.4x (Zebra) FY2025 EBITDA. Argos takes the interquartile range,
14.55x–21.93x, applies it to Itron's $362.6m of EBITDA, subtracts $227.9m of
net debt and divides by 43.79m shares.

**Trading comps — EV/Revenue: $154–$221.** Same mechanics on 2.94x–4.19x
revenue.

**DCF: $73–$115, base case $89.48.** Five years of unlevered free cash flow,
mid-year discounting, Gordon-growth terminal value. The assumptions are seeded
from Itron's own filings: year-one revenue growth −3.0% (FY2025 was down on
FY2024), fading toward 2.5% terminal growth; 15.3% EBITDA margin expanding 40bps
a year; capex at 1.0% of revenue; working-capital investment at 1.8% of
revenue (a three-year average); tax at the 15% floor of a normalised band
(Itron's filed effective rate was 11.4%); WACC 9.5%. The bar is the range across
WACC ±100bps and terminal growth ±50bps; the full sensitivity grid is the next
slide.

**52-week range: $78–$142.** Where the market has actually been.

**Concluded range: $96.53–$159.19** — the median of the lows and the median of
the highs. Not the widest bar, and not the narrowest: one methodology cannot
dictate the answer.

### Reading it honestly

The comps bars sit well above the current price while the DCF straddles it.
That is not a bug; it is the finding. Itron trades at 11.0x EBITDA against a
peer set at 14.6x–21.9x because its margin (15.3%) is the lowest in the group —
every peer "supports a cash offer with an accretive margin profile", as the
counterparties slide puts it. A comps-driven valuation says "re-rate to the
peers"; a cash-flow valuation says "the current price is about right for the
cash this business generates today". A real pitch would argue which one the
buyer should believe, and this page gives you both with their inputs exposed.

Change an input and watch it move: on the deck page, open **DCF assumptions —
edit and rebuild**, set WACC to `0.11`, apply. The DCF bar drops; the comps bars
do not. Change the comp set (remove Zebra and Watts, the two most expensive
names) and the comps bars drop instead. Hand-edited slides are pinned and
survive these rebuilds.

### The precedent transactions page is empty — on purpose

Deal multiples are not in EDGAR in any consistent, machine-readable form, so
Argos does not pretend to have them. The slide says so, and the valuation
summary omits the precedent bar rather than inventing one. When you have a
transaction screen, load it:

```bash
python3 -m argos load-transactions deals.csv
python3 -m argos export 1 --format pptx      # or Rebuild in the UI
```

with the columns in `docs/precedent-transactions-template.csv`
(`announced_on, target, acquirer, sector, ev, ev_revenue, ev_ebitda,
premium_1day, consideration, note`). The precedent range, the control-premium
bullet on the process slide and the sponsor rationale all fill in.

---

## 5. Pin evidence

Back in **Research**, search `tariff ticker:BMI`, open the Badger Meter 10-Q and
press **Pin to deck** on the paragraph about reciprocal tariffs. Pick *Project
Meter*, add a note ("diligence: tariff exposure in the peer set"), pin.

The appendix slide now carries the quote, the filing it came from, its date and
your note. Pin a dozen passages while you research and the evidence appendix
writes itself — every claim in the front half of the deck has a source in the
back half.

---

## 6. Export

From the deck toolbar, or:

```bash
python3 -m argos export 1 --format pptx --out project-meter.pptx
python3 -m argos export 1 --format pdf  --out project-meter.pdf
python3 -m argos export 1 --format html --out project-meter.html
```

The PowerPoint charts are native, editable chart objects — the football field
is a stacked bar with an invisible base series, exactly as you would build it
by hand — so a banker can retype a number at 11pm without coming back to the
application. The HTML is a single self-contained file that prints to PDF.

---

## 7. Keep it current

Every command is idempotent. Re-run the load after the next earnings release
and only the new 8-K is ingested; rebuild the deck and the executive summary
picks up the new backlog figure:

```bash
python3 -m argos load-sec ITRI BMI XYL TRMB VNT ZBRA WTS --sector "Smart Infrastructure & Measurement"
curl -X POST http://127.0.0.1:8787/api/pitchbooks/1/rebuild
```

Save the backlog search (**Save this search**) and the **Monitor** tab will
list new matches each time you load.

---

## What to be careful about

These are the judgement calls the loader makes. They are reasonable defaults,
and you should know them before you put a number in front of anyone.

* **EBITDA is EBIT + D&A**, not adjusted EBITDA. Zebra's release reports a
  27.7% *adjusted* EBITDA margin; the XBRL-derived figure is lower. Compare like
  with like.
* **Fiscal years are labelled by period end**, with early-January year ends
  assigned to the prior year (Trimble's year ending 2 January 2026 is FY2025).
* **Working capital excludes cash and debt.** Itron's convertible notes moved
  into current liabilities in 2025; counting that as a working-capital release
  would add $460m to every projected cash flow. (It did, in an earlier version
  of this loader — the DCF came out at $266 a share. That bug is why the
  tutorial explains the inputs.)
* **The tax rate in the DCF is held between 15% and 35%**; a single year's
  effective rate is not a forecast.
* **Multi-class filers** (Watts Water) have no single cover-page share count in
  the facts feed; the loader falls back to the weighted diluted count.
* **Theme detection on filing text is noisy.** Earnings releases carry the
  signal ("tariff refunds", "Middle East conflict" rose in the last 180 days);
  10-Q boilerplate is filtered but not perfectly. Treat the market-overview
  theme table as a prompt for reading, not a conclusion.
* **The quote is a public endpoint**, unlicensed and occasionally unavailable.
  If a company loads with no market data, re-run; the fundamentals and filings
  are unaffected.
* **Beta is not loaded**, so every company's WACC starts at the 9.5% default.
  Set it per deck through the assumptions panel.

---

## Reproduce exactly

```bash
export ARGOS_DB=data/real.db ARGOS_USER_AGENT="Your Name your@email.example"
python3 -m argos load-sec ITRI BMI XYL TRMB VNT ZBRA WTS --sector "Smart Infrastructure & Measurement"
python3 -m argos pitchbook ITRI --title "Project Meter" --client "Board of Itron, Inc." \
    --banker "Argos Advisory" --comps BMI,XYL,TRMB,VNT,ZBRA,WTS --export pptx
python3 -m argos serve
```

The HTTP API (`docs/api.md`) exposes everything the UI does, so the same session
can be scripted end to end.
