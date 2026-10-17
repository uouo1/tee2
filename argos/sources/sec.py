"""Load real company data from SEC EDGAR.

Three public endpoints do all the work:

* ``company_tickers.json`` maps a ticker to a CIK;
* ``submissions/CIK…json`` lists every filing a company has made;
* ``api/xbrl/companyfacts/CIK…json`` carries the tagged financial facts.

Fundamentals come from XBRL rather than from parsed text, so the figures that
reach a pitch book are the ones the company filed. Filing narrative is fetched
separately and ingested as the research corpus, which is what makes a deck built
this way auditable: every number has a tag and every quote has an accession
number.

EBITDA is operating income plus depreciation and amortisation — the standard
proxy, and not always what a company calls "adjusted EBITDA" in its own release.
"""

from __future__ import annotations

import sqlite3
from datetime import date
from typing import Any, Iterable, Sequence

from ..db import insert, query_one, upsert_company
from ..ingest import ingest_many
from .htmltext import html_to_text
from .http import fetch, fetch_json
from .market import fetch_estimates, fetch_quote

TICKER_INDEX_URL = "https://www.sec.gov/files/company_tickers.json"
SUBMISSIONS_URL = "https://data.sec.gov/submissions/CIK{cik}.json"
FACTS_URL = "https://data.sec.gov/api/xbrl/companyfacts/CIK{cik}.json"
ARCHIVE_BASE = "https://www.sec.gov/Archives/edgar/data/{cik}/{accession}"

# Preference order per concept: filers tag the same line differently.
TAGS: dict[str, tuple[str, ...]] = {
    "revenue": (
        "RevenueFromContractWithCustomerExcludingAssessedTax",
        "RevenueFromContractWithCustomerIncludingAssessedTax",
        "Revenues",
        "SalesRevenueNet",
        "SalesRevenueGoodsNet",
    ),
    "operating_income": ("OperatingIncomeLoss",),
    "dep_amort": (
        "DepreciationDepletionAndAmortization",
        "DepreciationAmortizationAndAccretionNet",
        "DepreciationAndAmortization",
        "DepreciationDepletionAndAmortizationNonproduction",
    ),
    "net_income": ("NetIncomeLoss", "ProfitLoss"),
    "eps": ("EarningsPerShareDiluted", "EarningsPerShareBasicAndDiluted"),
    "capex": (
        "PaymentsToAcquirePropertyPlantAndEquipment",
        "PaymentsToAcquireProductiveAssets",
    ),
    "pretax_income": (
        "IncomeLossFromContinuingOperationsBeforeIncomeTaxesExtraordinaryItemsNoncontrollingInterest",
        "IncomeLossFromContinuingOperationsBeforeIncomeTaxesMinorityInterestAndIncomeLossFromEquityMethodInvestments",
    ),
    "income_tax": ("IncomeTaxExpenseBenefit",),
    "diluted_shares": ("WeightedAverageNumberOfDilutedSharesOutstanding",),
}
INSTANT_TAGS: dict[str, tuple[str, ...]] = {
    "cash": (
        "CashAndCashEquivalentsAtCarryingValue",
        "CashCashEquivalentsRestrictedCashAndRestrictedCashEquivalents",
        "Cash",
    ),
    "short_term_investments": (
        "ShortTermInvestments", "MarketableSecuritiesCurrent",
        "AvailableForSaleSecuritiesDebtSecuritiesCurrent",
    ),
    "debt_current": (
        "LongTermDebtCurrent", "DebtCurrent",
        "LongTermDebtAndCapitalLeaseObligationsCurrent",
    ),
    "debt_noncurrent": (
        "LongTermDebtNoncurrent", "LongTermDebtAndCapitalLeaseObligations",
    ),
    # Borrowings as one line, for filers that tag neither split line.
    "debt_total": (
        "LongTermDebt", "DebtLongtermAndShorttermCombinedAmount",
        "DebtAndCapitalLeaseObligations", "DebtInstrumentCarryingAmount",
    ),
    "minority_interest": ("MinorityInterest",),
    "preferred_equity": ("PreferredStockValue", "PreferredStockCarryingAmount"),
    "assets_current": ("AssetsCurrent",),
    "liabilities_current": ("LiabilitiesCurrent",),
}

FORM_DOC_TYPES = {"10-K": "filing", "10-Q": "filing", "8-K": "press-release"}
ANNUAL_FORMS = ("10-K", "10-K/A")
QUARTERLY_FORMS = ("10-Q", "10-Q/A")
BALANCE_FORMS = ANNUAL_FORMS + QUARTERLY_FORMS
# Days in a year-to-date span on a Q1, Q2 or Q3 10-Q.
YTD_SPANS: dict[int, tuple[int, int]] = {1: (80, 100), 2: (170, 190), 3: (260, 280)}
MAX_FILING_CHARS = 320_000


# ------------------------------------------------------------------ lookup


def resolve_cik(ticker: str) -> str | None:
    """Ticker to zero-padded CIK via the SEC's own index."""
    index = fetch_json(TICKER_INDEX_URL)
    wanted = ticker.upper()
    for row in index.values():
        if str(row.get("ticker", "")).upper() == wanted:
            return str(row["cik_str"]).zfill(10)
    return None


def fetch_submissions(cik: str) -> dict[str, Any]:
    return fetch_json(SUBMISSIONS_URL.format(cik=cik), cache=False)


def fetch_facts(cik: str) -> dict[str, Any]:
    return fetch_json(FACTS_URL.format(cik=cik), cache=False)


# ------------------------------------------------------------------- facts


def _fiscal_year(end: str | date) -> int:
    """Fiscal year for a period end date.

    52/53-week filers end their year in the first days of January; Trimble's
    "fiscal 2025" ends 2 January 2026. Labelling by calendar year of the end
    date would call that FY2026, so early-January ends belong to the prior year.
    """
    ended = end if isinstance(end, date) else date.fromisoformat(end)
    return ended.year - 1 if (ended.month == 1 and ended.day <= 15) else ended.year


def _us_gaap(facts: dict[str, Any]) -> dict[str, Any]:
    return (facts.get("facts") or {}).get("us-gaap") or {}


# A preferred tag carrying less than this share of another tag's value for the
# same year is a sub-line, not the total: Charter tags one revenue stream
# (889m) under RevenueFromContractWithCustomerIncludingAssessedTax while
# Revenues holds the 55bn total. Only the revenue concept uses the guard.
SUB_LINE_RATIO = 0.2


def duration_entries(
    facts: dict[str, Any], names: Sequence[str], *, unit: str = "USD", sub_line_guard: bool = False,
) -> dict[int, dict[str, Any]]:
    """Annual observations by fiscal year for a duration concept.

    Returns ``{year: {"value", "period_end" (date), "filed", "tag"}}``.

    Tags are resolved PER YEAR in preference order: an earlier tag's value for
    a year wins, a later tag fills the years the earlier ones lack. Resolving
    once per company ("first tag with any data") lost every year after a tag
    switch and, for Xylem, dropped the whole current-debt line (audit finding,
    docs/RAILS_PORT.md item 11). Within a tag the most recently filed value
    wins: restatements.

    With ``sub_line_guard`` a year's preferred value that is under
    :data:`SUB_LINE_RATIO` of the largest value any listed tag carries for
    that year yields to the largest: preference order alone let a sub-line
    stand in for total revenue (Charter, ported from the Rails loader).
    """
    us_gaap = _us_gaap(facts)
    by_tag: list[dict[int, dict[str, Any]]] = []
    for name in names:
        per_tag: dict[int, dict[str, Any]] = {}
        for entry in (us_gaap.get(name) or {}).get("units", {}).get(unit, []) or []:
            if entry.get("form") not in ANNUAL_FORMS or entry.get("fp") != "FY":
                continue
            start, end = entry.get("start"), entry.get("end")
            if not start or not end:
                continue
            finish = date.fromisoformat(end)
            span = (finish - date.fromisoformat(start)).days
            if not 330 <= span <= 400:  # a full year, not a quarter or a stub
                continue
            year = _fiscal_year(finish)
            filed = str(entry.get("filed") or "")
            if year not in per_tag or filed > per_tag[year]["filed"]:
                per_tag[year] = {"value": float(entry["val"]), "period_end": finish, "filed": filed, "tag": name}
        by_tag.append(per_tag)
    out: dict[int, dict[str, Any]] = {}
    for per_tag in by_tag:
        for year, row in per_tag.items():
            out.setdefault(year, row)
    if not sub_line_guard:
        return out
    for year, row in out.items():
        candidates = [per_tag[year] for per_tag in by_tag if year in per_tag]
        largest = max(candidates, key=lambda c: abs(c["value"]))
        if abs(row["value"]) < abs(largest["value"]) * SUB_LINE_RATIO:
            out[year] = largest
    return out


def duration_values(facts: dict[str, Any], names: Sequence[str], *, unit: str = "USD") -> dict[int, float]:
    """Annual values by fiscal year for a duration concept (P&L, cash flow)."""
    return {year: row["value"] for year, row in duration_entries(facts, names, unit=unit).items()}


def instant_entries(
    facts: dict[str, Any], names: Sequence[str], *,
    forms: Sequence[str] = ("10-K", "10-K/A"), fiscal_year_only: bool = True,
) -> dict[date, dict[str, Any]]:
    """Balance-sheet observations by date for an instant concept.

    Returns ``{date: {"value", "filed", "form", "tag"}}`` from the given forms,
    with the same per-date tag preference and latest-filed rule as
    :func:`duration_entries`.
    """
    us_gaap = _us_gaap(facts)
    out: dict[date, dict[str, Any]] = {}
    for name in names:
        per_tag: dict[date, dict[str, Any]] = {}
        for entry in (us_gaap.get(name) or {}).get("units", {}).get("USD", []) or []:
            if entry.get("form") not in forms:
                continue
            if fiscal_year_only and entry.get("fp") != "FY":
                continue
            end = entry.get("end")
            if not end:
                continue
            when = date.fromisoformat(end)
            filed = str(entry.get("filed") or "")
            if when not in per_tag or filed > per_tag[when]["filed"]:
                per_tag[when] = {"value": float(entry["val"]), "filed": filed, "form": entry.get("form"), "tag": name}
        for when, row in per_tag.items():
            out.setdefault(when, row)
    return out


def instant_values(facts: dict[str, Any], names: Sequence[str]) -> dict[int, float]:
    """Year-end values for a balance-sheet concept (fiscal-year 10-K instants).

    When a fiscal year carries several FY instants, the latest date is the
    year end; the others are comparatives or opening balances.
    """
    dated: dict[int, tuple[date, float]] = {}
    for when, row in instant_entries(facts, names).items():
        year = _fiscal_year(when)
        if year not in dated or when > dated[year][0]:
            dated[year] = (when, row["value"])
    return {year: value for year, (_, value) in dated.items()}


# Kept for callers of the old private names; same per-year rules.
_duration_values = duration_values
_instant_values = instant_values


def latest_balance_sheet(facts: dict[str, Any]) -> dict[str, Any] | None:
    """The most recent balance sheet in the facts, 10-K or 10-Q, in millions.

    Every component is read at the one date of the newest cash figure. This is
    what an EV bridge needs: bridging a current price through the last fiscal
    year end missed, for Itron, a $600m convertible and a buyback filed since
    (audit finding, docs/RAILS_PORT.md item 11).

    Gross debt is the current plus non-current lines when either is tagged,
    else a total-debt tag; when no debt line exists at that date it is taken as
    zero WITH ``debt_note`` saying so, because a filer with no debt tags at all
    is usually debt-free but not always. Non-controlling interest and preferred
    equity are read for the bridge (zero when absent). ``as_of`` is an ISO date.
    """
    cash_by_date = instant_entries(facts, INSTANT_TAGS["cash"], forms=BALANCE_FORMS, fiscal_year_only=False)
    if not cash_by_date:
        return None
    as_of = max(cash_by_date)

    def at(key: str) -> float | None:
        row = instant_entries(facts, INSTANT_TAGS[key], forms=BALANCE_FORMS, fiscal_year_only=False).get(as_of)
        return row["value"] if row else None

    cash = cash_by_date[as_of]["value"]
    short_term_investments = at("short_term_investments")
    if short_term_investments is None:
        short_term_investments = 0.0
    debt_current = at("debt_current")
    debt_noncurrent = at("debt_noncurrent")
    debt_total = at("debt_total")
    debt_note = None
    if debt_current is not None or debt_noncurrent is not None:
        gross_debt = (debt_current or 0.0) + (debt_noncurrent or 0.0)
    elif debt_total is not None:
        gross_debt = debt_total
    else:
        debt_note = f"No debt line tagged at {as_of.isoformat()}; gross debt taken as zero."
        gross_debt = 0.0
    minority_interest = at("minority_interest")
    preferred_equity = at("preferred_equity")

    def millions(value: float | None) -> float | None:
        return None if value is None else round(value / 1e6, 1)

    return {
        "as_of": as_of.isoformat(),
        "form": cash_by_date[as_of]["form"],
        "cash": millions(cash),
        "short_term_investments": millions(short_term_investments),
        "debt_current": millions(debt_current),
        "debt_noncurrent": millions(debt_noncurrent),
        "debt_total": millions(debt_total),
        "gross_debt": millions(gross_debt),
        "minority_interest": millions(minority_interest if minority_interest is not None else 0.0),
        "preferred_equity": millions(preferred_equity if preferred_equity is not None else 0.0),
        "net_debt": millions(gross_debt - cash - short_term_investments),
        "debt_note": debt_note,
    }


def _cover_shares(facts: dict[str, Any]) -> float | None:
    """Shares outstanding from the most recent filing cover page."""
    entries = (
        facts.get("facts", {}).get("dei", {})
        .get("EntityCommonStockSharesOutstanding", {})
        .get("units", {}).get("shares", [])
    )
    if not entries:
        return None
    latest = max(entries, key=lambda row: (str(row.get("end", "")), str(row.get("filed", ""))))
    return float(latest["val"])


def shares(facts: dict[str, Any]) -> dict[str, Any]:
    """Diluted and basic share counts, in shares (not millions).

    Returns ``{"diluted", "basic", "basis", "fallback_reason"}``; ``basis``
    ("weighted_diluted", "cover_page" or "none") says which count ``diluted``
    really is.

    ``diluted`` is the latest annual weighted-average diluted count: per-share
    values divide by diluted shares, and using the cover-page count under a
    "diluted" label understated them by ~6% for Itron (43.79m vs 46.32m).
    ``basic`` is the cover-page count. Two guards an audit of 600 filers showed
    were needed (docs/RAILS_PORT.md item 15): the weighted count must belong to
    the latest fiscal year on file (a tag a filer stopped using left
    LyondellBasell with a count from 2011), and it must be of the cover count's
    order of magnitude (McDonald's tags the count in millions, which read as
    716 shares). Either failure falls back to the cover page. Multi-class
    filers report the cover count per class as dimensional facts, which the
    companyfacts feed omits, so ``diluted`` then stands alone and ``basic``
    stays None rather than borrowing it.
    """
    cover = _cover_shares(facts)
    if cover == 0:
        cover = None
    diluted = duration_entries(facts, TAGS["diluted_shares"], unit="shares")
    revenue_years = duration_values(facts, TAGS["revenue"])
    latest_year = max(revenue_years) if revenue_years else None
    year = max(diluted) if diluted else None
    weighted = diluted[year]["value"] if year is not None else None
    if weighted == 0:
        weighted = None
    reason = None
    if weighted is not None and latest_year is not None and year < latest_year:
        reason = f"diluted count is from FY{year}, revenue runs to FY{latest_year}"
        weighted = None
    elif weighted is not None and cover is not None and not 0.5 <= weighted / cover <= 2.0:
        reason = f"diluted count {round(weighted)} is off-scale against the cover page {round(cover)}"
        weighted = None
    if weighted is not None:
        basis = "weighted_diluted"
    elif cover is not None:
        basis = "cover_page"
    else:
        basis = "none"
    return {
        "diluted": weighted if weighted is not None else cover,
        "basic": cover,
        "basis": basis,
        "fallback_reason": reason,
    }


def shares_outstanding(facts: dict[str, Any]) -> float | None:
    """The share count a per-share bridge divides by: ``shares(facts)["diluted"]``.

    Kept as a thin wrapper for older callers; the guards live in :func:`shares`.
    """
    return shares(facts)["diluted"]


def build_financials(facts: dict[str, Any], *, years: int = 6) -> list[dict[str, Any]]:
    """Annual income-statement and cash-flow rows, newest `years` fiscal years,
    followed by one trailing-twelve-month row when a 10-Q extends the last year.

    Each row carries ``period_type`` ("FY" or "LTM") and ``period_end`` (ISO
    date). The LTM row shares its fiscal_year with the year it extends (see
    :func:`ltm_row`). Amounts are converted to millions to match the rest of
    the application.
    """
    entries = {
        key: duration_entries(facts, names, sub_line_guard=key == "revenue")
        for key, names in TAGS.items() if key != "eps"
    }
    series = {key: {year: row["value"] for year, row in rows.items()} for key, rows in entries.items()}
    if not series["dep_amort"]:
        # Some filers (Badger Meter, for one) never tag a combined line.
        depreciation = duration_values(facts, ("Depreciation",))
        amortisation = duration_values(facts, ("AmortizationOfIntangibleAssets",))
        series["dep_amort"] = {
            year: depreciation.get(year, 0.0) + amortisation.get(year, 0.0)
            for year in set(depreciation) | set(amortisation)
        }
    eps = duration_values(facts, TAGS["eps"], unit="USD/shares")
    balance = {key: instant_values(facts, names) for key, names in INSTANT_TAGS.items()}

    available = sorted(series["revenue"])[-years:]
    rows: list[dict[str, Any]] = []
    for year in available:
        revenue = series["revenue"].get(year)
        if not revenue:
            continue
        operating_income = series["operating_income"].get(year)
        dep_amort = series["dep_amort"].get(year)
        ebitda = (operating_income + dep_amort) if (operating_income is not None and dep_amort is not None) else None
        pretax = series["pretax_income"].get(year)
        tax = series["income_tax"].get(year)
        tax_rate = None
        if pretax and tax is not None and pretax > 0:
            tax_rate = max(0.0, min(0.5, tax / pretax))

        working_capital = _operating_working_capital(balance, year)
        prior_working_capital = _operating_working_capital(balance, year - 1)
        nwc_change = (
            (working_capital - prior_working_capital) / 1e6
            if working_capital is not None and prior_working_capital is not None else None
        )

        rows.append({
            "fiscal_year": year,
            "period_type": "FY",
            "period_end": entries["revenue"][year]["period_end"].isoformat(),
            "is_estimate": 0,
            "revenue": round(revenue / 1e6, 1),
            "ebitda": round(ebitda / 1e6, 1) if ebitda is not None else None,
            "ebit": round(operating_income / 1e6, 1) if operating_income is not None else None,
            "net_income": round(series["net_income"][year] / 1e6, 1) if year in series["net_income"] else None,
            "eps": round(eps[year], 2) if year in eps else None,
            "dep_amort": round(dep_amort / 1e6, 1) if dep_amort is not None else None,
            "capex": round(series["capex"][year] / 1e6, 1) if year in series["capex"] else None,
            "nwc_change": round(nwc_change, 1) if nwc_change is not None else None,
            "tax_rate": round(tax_rate, 4) if tax_rate is not None else None,
        })
    if rows:
        last_year = rows[-1]["fiscal_year"]
        fy_tags = {key: by_year[last_year]["tag"] for key, by_year in entries.items() if last_year in by_year}
        ltm = ltm_row(facts, rows[-1], fy_tags=fy_tags)
        if ltm:
            rows.append(ltm)
    return rows


def ltm_row(
    facts: dict[str, Any], fy_row: dict[str, Any], *, fy_tags: dict[str, str] | None = None,
) -> dict[str, Any] | None:
    """Trailing twelve months to the latest 10-Q after the last fiscal year.

    Fiscal year + current year-to-date − prior-year year-to-date, per flow.
    Bankers quote LTM (and NTM) multiples, not last-fiscal-year ones; storing
    annual rows only left Itron's multiples on a year that had ended nine
    months before the pricing date (audit finding, docs/RAILS_PORT.md item 12).

    EPS is rolled the same way (an approximation when the share count moved).
    D&A falls back to the fiscal-year figure when the quarterlies do not tag
    it, since it barely moves within a year. Working capital is not rolled.
    Returns None when no 10-Q extends the last fiscal year or the prior-year
    comparable is missing.

    ``fy_tags`` maps a flow to the tag its fiscal-year figure came from; that
    tag is tried first so FY + YTD − prior YTD never mixes two definitions of
    the line (Charter: an 889m FY sub-line rolled with the 27bn Revenues YTD
    gave an LTM of 511m).
    """
    fy_tags = fy_tags or {}

    def tags_for(key: str) -> tuple[str, ...]:
        own = fy_tags.get(key)
        return ((own,) if own else ()) + tuple(t for t in TAGS[key] if t != own)

    fy_end = date.fromisoformat(str(fy_row["period_end"]))
    revenue = latest_ytd(facts, tags_for("revenue"), after=fy_end)
    if revenue is None or revenue["prior_value"] is None:
        return None

    quarter_end = revenue["period_end"]
    ytd: dict[str, dict[str, Any] | None] = {"revenue": revenue}
    for key in ("operating_income", "dep_amort", "net_income", "capex"):
        ytd[key] = latest_ytd(facts, tags_for(key), after=fy_end, period_end=quarter_end)
    ytd["eps"] = latest_ytd(facts, tags_for("eps"), unit="USD/shares", after=fy_end, period_end=quarter_end)

    def roll(key: str, fy_value: float | None, scale: float) -> float | None:
        current = ytd[key]
        if current is None or current["prior_value"] is None or fy_value is None:
            return None
        return fy_value + (current["value"] - current["prior_value"]) / scale

    ltm_revenue = roll("revenue", fy_row["revenue"], 1e6)
    ebit = roll("operating_income", fy_row["ebit"], 1e6)
    dep_amort = roll("dep_amort", fy_row["dep_amort"], 1e6)
    if dep_amort is None:
        dep_amort = fy_row["dep_amort"]
    net_income = roll("net_income", fy_row["net_income"], 1e6)
    eps = roll("eps", fy_row["eps"], 1.0)
    capex = roll("capex", fy_row["capex"], 1e6)
    return {
        "fiscal_year": fy_row["fiscal_year"],
        "period_type": "LTM",
        "period_end": quarter_end.isoformat(),
        "is_estimate": 0,
        "revenue": round(ltm_revenue, 1) if ltm_revenue is not None else None,
        "ebitda": round(ebit + dep_amort, 1) if ebit is not None and dep_amort is not None else None,
        "ebit": round(ebit, 1) if ebit is not None else None,
        "net_income": round(net_income, 1) if net_income is not None else None,
        "eps": round(eps, 2) if eps is not None else None,
        "dep_amort": round(dep_amort, 1) if dep_amort is not None else None,
        "capex": round(capex, 1) if capex is not None else None,
        "nwc_change": None,
        "tax_rate": fy_row["tax_rate"],
    }


def _year_earlier(when: date) -> date:
    """The same day a year before; 29 February maps to the 28th (Ruby's ``<< 12``)."""
    try:
        return when.replace(year=when.year - 1)
    except ValueError:
        return when.replace(year=when.year - 1, day=28)


def _near(when: date, target: date, *, days: int = 10) -> bool:
    return abs((when - target).days) <= days


def latest_ytd(
    facts: dict[str, Any], names: Sequence[str], *, unit: str = "USD",
    after: date, period_end: date | None = None,
) -> dict[str, Any] | None:
    """The latest year-to-date 10-Q observation of a duration concept.

    Only periods ending after ``after`` (and exactly on ``period_end`` when
    given) qualify; the span must be a Q1, Q2 or Q3 year-to-date span. Returns
    ``{"quarter", "period_start", "period_end", "value", "prior_value", "tag"}``
    — ``prior_value`` being the prior-year comparable of the same span, None
    when not filed — or None. The first tag with a qualifying period wins.
    """
    us_gaap = _us_gaap(facts)
    for name in names:
        durations = [
            entry for entry in (us_gaap.get(name) or {}).get("units", {}).get(unit, []) or []
            if entry.get("start") and entry.get("end")
        ]
        current = []
        for entry in durations:
            if entry.get("form") not in QUARTERLY_FORMS:
                continue
            start = date.fromisoformat(entry["start"])
            finish = date.fromisoformat(entry["end"])
            span = (finish - start).days
            quarter = next((q for q, (low, high) in YTD_SPANS.items() if low <= span <= high), None)
            if quarter is None or finish <= after:
                continue
            if period_end is not None and finish != period_end:
                continue
            current.append((entry, start, finish, quarter))
        if not current:
            continue
        # Latest end, then latest filed; at a full tie the longer span wins. A
        # Q2 10-Q tags the three months (~91 days, inside the Q1 window) and
        # the six months to the same date; rolling the three months would drop
        # Q1's change. Filers list the longer span first, which the Ruby port
        # relies on by order; the explicit key does not depend on it.
        entry, start, finish, quarter = max(
            current, key=lambda item: (item[2], str(item[0].get("filed") or ""), (item[2] - item[1]).days))
        prior_start, prior_end = _year_earlier(start), _year_earlier(finish)
        priors = [
            e for e in durations
            if _near(date.fromisoformat(e["end"]), prior_end) and _near(date.fromisoformat(e["start"]), prior_start)
        ]
        prior = max(priors, key=lambda e: str(e.get("filed") or "")) if priors else None
        return {
            "quarter": quarter,
            "period_start": start,
            "period_end": finish,
            "value": float(entry["val"]),
            "prior_value": float(prior["val"]) if prior else None,
            "tag": name,
        }
    return None


def _operating_working_capital(balance: dict[str, dict[int, float]], year: int) -> float | None:
    """Current assets less cash, minus current liabilities less debt.

    Using raw current assets and liabilities would count a convertible note
    moving into "current" as a working-capital release — a real bug this
    replaced, which once added the whole note to every projected cash flow.
    """
    if year not in balance["assets_current"] or year not in balance["liabilities_current"]:
        return None
    assets = (
        balance["assets_current"][year]
        - balance["cash"].get(year, 0.0)
        - balance["short_term_investments"].get(year, 0.0)
    )
    liabilities = balance["liabilities_current"][year] - balance["debt_current"].get(year, 0.0)
    return assets - liabilities


def net_debt(facts: dict[str, Any], fiscal_year: int) -> float | None:
    """Gross debt less cash and short-term investments at a fiscal year end, in millions.

    This is the year-end view; the loader stores :func:`latest_balance_sheet`.
    """
    balance = {key: instant_values(facts, names) for key, names in INSTANT_TAGS.items()}
    debt = balance["debt_current"].get(fiscal_year, 0.0) + balance["debt_noncurrent"].get(fiscal_year, 0.0)
    cash = balance["cash"].get(fiscal_year)
    if cash is None and not debt:
        return None
    liquid = (cash or 0.0) + balance["short_term_investments"].get(fiscal_year, 0.0)
    return round((debt - liquid) / 1e6, 1)


# --------------------------------------------------------------- documents


def _recent_filings(submissions: dict[str, Any]) -> list[dict[str, Any]]:
    recent = submissions.get("filings", {}).get("recent", {})
    keys = ("form", "accessionNumber", "filingDate", "reportDate", "primaryDocument", "primaryDocDescription")
    columns = {key: recent.get(key, []) for key in keys}
    count = len(columns["form"])
    return [{key: columns[key][index] if index < len(columns[key]) else None for key in keys} for index in range(count)]


def _exhibit_url(cik: str, accession: str) -> str | None:
    """The earnings release exhibit (EX-99.1) inside an 8-K, when present.

    Filers name the file however their agent likes — ``exh_991.htm``,
    ``bmi-ex99_pressrelease.htm``, ``d12345dex991.htm`` — so the match runs on
    the name with punctuation removed and prefers an explicit 99.1.
    """
    import re

    base = ARCHIVE_BASE.format(cik=int(cik), accession=accession)
    try:
        index = fetch_json(f"{base}/index.json")
    except Exception:
        return None
    candidates: list[tuple[int, str]] = []
    for item in index.get("directory", {}).get("item", []):
        name = str(item.get("name", ""))
        if not name.lower().endswith((".htm", ".html", ".txt")):
            continue
        normalised = re.sub(r"[^a-z0-9]", "", name.lower())
        if "ex99" in normalised or "exh99" in normalised:
            priority = 0 if ("ex991" in normalised or "exh991" in normalised) else 1
            candidates.append((priority, name))
    if not candidates:
        return None
    candidates.sort()
    return f"{base}/{candidates[0][1]}"


def collect_documents(
    cik: str, submissions: dict[str, Any], *,
    annual: int = 1, quarterly: int = 2, press_releases: int = 4,
) -> list[dict[str, Any]]:
    """Fetch filing text and return records ready for :func:`argos.ingest.ingest_many`."""
    company_name = submissions.get("name", "").title()
    ticker = (submissions.get("tickers") or [None])[0]
    wanted = {"10-K": annual, "10-Q": quarterly, "8-K": press_releases}
    collected: list[dict[str, Any]] = []
    counts = {form: 0 for form in wanted}

    for filing in _recent_filings(submissions):
        form = filing["form"]
        if form not in wanted or counts[form] >= wanted[form]:
            continue
        accession = (filing["accessionNumber"] or "").replace("-", "")
        if not accession:
            continue
        base = ARCHIVE_BASE.format(cik=int(cik), accession=accession)
        if form == "8-K":
            url = _exhibit_url(cik, accession)
            if not url:
                continue  # an 8-K with no earnings release is not research material
        else:
            if not filing["primaryDocument"]:
                continue
            url = f"{base}/{filing['primaryDocument']}"

        try:
            text = html_to_text(fetch(url), max_chars=MAX_FILING_CHARS)
        except Exception:
            continue
        if len(text) < 500:
            continue

        period = filing["reportDate"] or filing["filingDate"]
        label = {"10-K": "Annual Report (10-K)", "10-Q": "Quarterly Report (10-Q)"}.get(form, "Earnings Release (8-K)")
        collected.append({
            "external_id": f"{accession}-{form}",
            "title": f"{company_name} {label} — {period}",
            "ticker": ticker,
            "company_name": company_name,
            "doc_type": FORM_DOC_TYPES[form],
            "source": "SEC EDGAR",
            "author": company_name,
            "published_at": filing["filingDate"],
            "period": period,
            "url": url,
            "body": text,
        })
        counts[form] += 1
    return collected


# ------------------------------------------------------------------ loader


def load_company(
    conn: sqlite3.Connection,
    ticker: str,
    *,
    sector: str | None = None,
    years: int = 6,
    annual: int = 1,
    quarterly: int = 2,
    press_releases: int = 4,
    with_documents: bool = True,
    with_quote: bool = True,
    with_estimates: bool = True,
) -> dict[str, Any]:
    """Load one real company: profile, financials, market data and filings.

    Financials are the fiscal-year rows, the LTM row when a 10-Q extends the
    last year, and — with ``with_estimates`` — up to two consensus rows
    (``is_estimate`` = 1) so forward (NTM) multiples rest on published
    estimates rather than nothing. Market data bridges through the latest
    balance sheet, dated, not the last fiscal year end.
    """
    cik = resolve_cik(ticker)
    if not cik:
        raise ValueError(f"no SEC filer found for ticker {ticker.upper()}")

    submissions = fetch_submissions(cik)
    facts = fetch_facts(cik)
    addresses = submissions.get("addresses", {}).get("business", {})
    name = (submissions.get("name") or ticker).title()

    company_id = upsert_company(conn, {
        "ticker": ticker.upper(),
        "name": name,
        "sector": sector or submissions.get("sicDescription") or "Unclassified",
        "industry": submissions.get("sicDescription"),
        "country": addresses.get("stateOrCountryDescription") or "United States",
        "hq": ", ".join(part for part in (addresses.get("city"), addresses.get("stateOrCountry")) if part),
        "currency": "USD",
        "description": (
            f"{name} (CIK {int(cik)}, SIC {submissions.get('sic')} — {submissions.get('sicDescription')}). "
            f"Profile, financials and filings loaded from SEC EDGAR."
        ),
    })

    financial_rows = build_financials(facts, years=years)
    fiscal_rows = [row for row in financial_rows if row["period_type"] == "FY"]
    ltm = next((row for row in financial_rows if row["period_type"] == "LTM"), None)
    estimates = fetch_estimates(ticker) if with_estimates else None
    estimate_rows = _estimate_rows(estimates, {row["fiscal_year"] for row in fiscal_rows})

    # Replace rather than merge: a restated year must not leave stale rows.
    conn.execute("DELETE FROM financials WHERE company_id = ?", (company_id,))
    for row in financial_rows + estimate_rows:
        insert(conn, "financials", {"company_id": company_id, **row})

    quote = fetch_quote(ticker) if with_quote else None
    share_counts = shares(facts)
    balance = latest_balance_sheet(facts)
    if quote and share_counts["diluted"]:
        conn.execute("DELETE FROM market_data WHERE company_id = ?", (company_id,))
        insert(conn, "market_data", {
            "company_id": company_id,
            "as_of": quote.get("as_of") or date.today().isoformat(),
            "share_price": quote["share_price"],
            "shares_diluted": round(share_counts["diluted"] / 1e6, 2),   # millions, as elsewhere
            "shares_basic": round(share_counts["basic"] / 1e6, 2) if share_counts["basic"] else None,
            # The latest balance sheet (10-K or 10-Q), dated, with the other
            # claims the EV bridge deducts — not the last fiscal year end.
            "net_debt": balance["net_debt"] if balance else None,
            "net_debt_as_of": balance["as_of"] if balance else None,
            "balance_sheet_form": balance["form"] if balance else None,
            "minority_interest": balance["minority_interest"] if balance else None,
            "preferred_equity": balance["preferred_equity"] if balance else None,
            "debt_note": balance["debt_note"] if balance else None,
            "week52_low": quote.get("week52_low"),
            "week52_high": quote.get("week52_high"),
            "beta": estimates.get("beta") if estimates else None,
        })
    conn.commit()

    documents = collect_documents(
        cik, submissions, annual=annual, quarterly=quarterly, press_releases=press_releases,
    ) if with_documents else []
    ingested = ingest_many(conn, documents) if documents else {"added": 0, "skipped": 0}

    return {
        "ticker": ticker.upper(),
        "name": name,
        "cik": cik,
        "fiscal_years": [row["fiscal_year"] for row in fiscal_rows],
        "latest_revenue": fiscal_rows[-1]["revenue"] if fiscal_rows else None,
        "ltm_period_end": ltm["period_end"] if ltm else None,
        "shares_basis": share_counts["basis"],
        "net_debt_as_of": balance["as_of"] if balance else None,
        "estimate_years": [row["fiscal_year"] for row in estimate_rows],
        "share_price": quote["share_price"] if quote else None,
        # The quote cache refreshes daily; saying which day the price is from
        # lets a reader tell a fresh load from one served out of the cache.
        "quote_as_of": quote.get("as_of") if quote else None,
        "documents_added": ingested["added"],
        "documents_skipped": ingested["skipped"],
    }


def _estimate_rows(estimates: dict[str, Any] | None, actual_years: set[int]) -> list[dict[str, Any]]:
    """Consensus estimates as financials rows (``is_estimate`` = 1, FY).

    A year that already has a reported FY row is skipped: the actual wins, and
    the (company, year, period_type) key would refuse the duplicate anyway —
    which happens for a few days after a 10-K while Yahoo's "0y" still points
    at the year just reported. EBITDA stays None: there is no consensus EBITDA
    in the feed, and operating income plus D&A cannot be built from it.
    """
    if not estimates:
        return []
    rows = []
    for estimate in estimates.get("estimates") or []:
        if estimate["fiscal_year"] in actual_years:
            continue
        rows.append({
            "fiscal_year": estimate["fiscal_year"],
            "period_type": "FY",
            "period_end": estimate["period_end"],
            "is_estimate": 1,
            "estimate_source": estimate["source"],
            "revenue": estimate["revenue"],
            "eps": estimate["eps"],
            "ebitda": None,
        })
    return rows


def load_companies(
    conn: sqlite3.Connection, tickers: Iterable[str], **kwargs
) -> dict[str, Any]:
    """Load several companies, reporting per-ticker results and any failures."""
    loaded: list[dict[str, Any]] = []
    failures: list[dict[str, str]] = []
    for ticker in tickers:
        try:
            loaded.append(load_company(conn, ticker, **kwargs))
        except Exception as exc:  # one bad ticker must not sink the batch
            failures.append({"ticker": ticker.upper(), "error": f"{type(exc).__name__}: {exc}"})
    return {
        "loaded": loaded,
        "failures": failures,
        "companies": len(loaded),
        "documents_added": sum(row["documents_added"] for row in loaded),
    }


def load_transactions_csv(conn: sqlite3.Connection, path) -> dict[str, int]:
    """Load precedent transactions from a CSV you supply.

    Deal multiples are not in EDGAR in any consistent, machine-readable form, so
    this is the hook for a licensed screen or your own deal log. Columns:
    announced_on, target, acquirer, sector, ev, ev_revenue, ev_ebitda,
    premium_1day, consideration, note.
    """
    import csv
    from pathlib import Path

    # utf-8-sig: a spreadsheet's byte-order mark must not become part of the
    # first header ("\ufeffannounced_on"), which would silently skip every row.
    with Path(path).open(encoding="utf-8-sig", newline="") as handle:
        rows = list(csv.DictReader(handle))
    added = 0
    for row in rows:
        if not row.get("announced_on") or not row.get("target"):
            continue
        payload = {
            "announced_on": row["announced_on"][:10],
            "target": row["target"],
            "acquirer": row.get("acquirer") or "Undisclosed",
            "sector": row.get("sector") or None,
            "note": row.get("note") or None,
            "consideration": row.get("consideration") or None,
        }
        for key in ("ev", "ev_revenue", "ev_ebitda", "premium_1day"):
            value = (row.get(key) or "").strip()
            payload[key] = float(value) if value else None
        insert(conn, "transactions", payload)
        added += 1
    conn.commit()
    return {"added": added, "rows": len(rows)}
