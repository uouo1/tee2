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
from .market import fetch_quote

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
    "assets_current": ("AssetsCurrent",),
    "liabilities_current": ("LiabilitiesCurrent",),
}

FORM_DOC_TYPES = {"10-K": "filing", "10-Q": "filing", "8-K": "press-release"}
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


def _fiscal_year(end: str) -> int:
    """Fiscal year for a period end date.

    52/53-week filers end their year in the first days of January; Trimble's
    "fiscal 2025" ends 2 January 2026. Labelling by calendar year of the end
    date would call that FY2026, so early-January ends belong to the prior year.
    """
    ended = date.fromisoformat(end)
    return ended.year - 1 if (ended.month == 1 and ended.day <= 15) else ended.year


def _duration_values(facts: dict[str, Any], names: Sequence[str], *, unit: str = "USD") -> dict[int, float]:
    """Annual values by fiscal year for a duration concept (P&L, cash flow)."""
    us_gaap = facts.get("facts", {}).get("us-gaap", {})
    out: dict[int, tuple[str, float]] = {}
    for name in names:
        units = us_gaap.get(name, {}).get("units", {}).get(unit, [])
        for entry in units:
            if entry.get("form") not in ("10-K", "10-K/A") or entry.get("fp") != "FY":
                continue
            start, end = entry.get("start"), entry.get("end")
            if not start or not end:
                continue
            span = (date.fromisoformat(end) - date.fromisoformat(start)).days
            if not 330 <= span <= 400:  # a full year, not a quarter or a stub
                continue
            year = _fiscal_year(end)
            filed = entry.get("filed", "")
            # Later filings restate earlier ones; keep the most recently filed.
            if year not in out or filed > out[year][0]:
                out[year] = (filed, float(entry["val"]))
        if out:
            break  # first tag that yields data wins the preference order
    return {year: value for year, (_, value) in out.items()}


def _instant_values(facts: dict[str, Any], names: Sequence[str]) -> dict[int, float]:
    """Year-end values for a balance-sheet concept."""
    us_gaap = facts.get("facts", {}).get("us-gaap", {})
    out: dict[int, tuple[str, float]] = {}
    for name in names:
        for entry in us_gaap.get(name, {}).get("units", {}).get("USD", []):
            if entry.get("form") not in ("10-K", "10-K/A") or entry.get("fp") != "FY":
                continue
            end = entry.get("end")
            if not end:
                continue
            year = _fiscal_year(end)
            filed = entry.get("filed", "")
            if year not in out or filed > out[year][0]:
                out[year] = (filed, float(entry["val"]))
        if out:
            break
    return {year: value for year, (_, value) in out.items()}


def _cover_shares(facts: dict[str, Any]) -> float | None:
    """Shares outstanding from the most recent filing cover page."""
    entries = (
        facts.get("facts", {}).get("dei", {})
        .get("EntityCommonStockSharesOutstanding", {})
        .get("units", {}).get("shares", [])
    )
    if not entries:
        return None
    latest = max(entries, key=lambda row: (row.get("end", ""), row.get("filed", "")))
    return float(latest["val"])


def shares_outstanding(facts: dict[str, Any]) -> float | None:
    """Cover-page shares, else the latest annual weighted diluted count.

    Multi-class filers (Watts Water, for one) report the cover-page count per
    class as dimensional facts, which the companyfacts feed omits; the diluted
    weighted average is the honest fallback for a per-share bridge.
    """
    cover = _cover_shares(facts)
    if cover:
        return cover
    diluted = _duration_values(facts, TAGS["diluted_shares"], unit="shares")
    if diluted:
        return diluted[max(diluted)]
    return None


def build_financials(facts: dict[str, Any], *, years: int = 6) -> list[dict[str, Any]]:
    """Annual income-statement and cash-flow rows, newest `years` fiscal years.

    Amounts are converted to millions to match the rest of the application.
    """
    series = {key: _duration_values(facts, names) for key, names in TAGS.items() if key != "eps"}
    if not series["dep_amort"]:
        # Some filers (Badger Meter, for one) never tag a combined line.
        depreciation = _duration_values(facts, ("Depreciation",))
        amortisation = _duration_values(facts, ("AmortizationOfIntangibleAssets",))
        series["dep_amort"] = {
            year: depreciation.get(year, 0.0) + amortisation.get(year, 0.0)
            for year in set(depreciation) | set(amortisation)
        }
    eps = _duration_values(facts, TAGS["eps"], unit="USD/shares")
    balance = {key: _instant_values(facts, names) for key, names in INSTANT_TAGS.items()}

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
            "is_estimate": 0,
            "revenue": round(revenue / 1e6, 1),
            "ebitda": round(ebitda / 1e6, 1) if ebitda is not None else None,
            "ebit": round(operating_income / 1e6, 1) if operating_income is not None else None,
            "net_income": round(series["net_income"].get(year, 0.0) / 1e6, 1) if year in series["net_income"] else None,
            "eps": round(eps[year], 2) if year in eps else None,
            "dep_amort": round(dep_amort / 1e6, 1) if dep_amort is not None else None,
            "capex": round(series["capex"][year] / 1e6, 1) if year in series["capex"] else None,
            "nwc_change": round(nwc_change, 1) if nwc_change is not None else None,
            "tax_rate": round(tax_rate, 4) if tax_rate is not None else None,
        })
    return rows


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
    """Gross debt less cash and short-term investments, in millions."""
    balance = {key: _instant_values(facts, names) for key, names in INSTANT_TAGS.items()}
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
) -> dict[str, Any]:
    """Load one real company: profile, financials, market data and filings."""
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
    conn.execute("DELETE FROM financials WHERE company_id = ?", (company_id,))
    for row in financial_rows:
        insert(conn, "financials", {"company_id": company_id, **row})

    latest_year = financial_rows[-1]["fiscal_year"] if financial_rows else None
    quote = fetch_quote(ticker) if with_quote else None
    shares = shares_outstanding(facts)
    if quote and shares:
        conn.execute("DELETE FROM market_data WHERE company_id = ?", (company_id,))
        insert(conn, "market_data", {
            "company_id": company_id,
            "as_of": quote.get("as_of") or date.today().isoformat(),
            "share_price": quote["share_price"],
            "shares_diluted": round(shares / 1e6, 2),       # millions, as elsewhere
            "net_debt": net_debt(facts, latest_year) if latest_year else None,
            "week52_low": quote.get("week52_low"),
            "week52_high": quote.get("week52_high"),
            "beta": None,
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
        "fiscal_years": [row["fiscal_year"] for row in financial_rows],
        "latest_revenue": financial_rows[-1]["revenue"] if financial_rows else None,
        "share_price": quote["share_price"] if quote else None,
        "documents_added": ingested["added"],
        "documents_skipped": ingested["skipped"],
    }


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

    rows = list(csv.DictReader(Path(path).open(encoding="utf-8")))
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
