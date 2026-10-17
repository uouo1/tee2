"""Valuation mechanics: trading comps, precedent transactions, DCF, football field.

The numbers here are the ones a pitch book actually argues with, so each helper
returns its inputs alongside its outputs — a multiple without the metric it was
applied to is unauditable, and an unauditable number does not belong in a deck.

Conventions: all currency amounts are in millions of the company's reporting
currency; per-share figures are absolute; rates are decimals (0.095 = 9.5%).
Dates travel as ISO strings (``"2026-10-09"``) so every result is JSON-safe.

The mechanics follow the audited Rails services (app/services/valuation.rb,
docs/AUDIT.md): multiples on the latest twelve months when a 10-Q allows it, an
EV bridge that deducts non-controlling interest and preferred equity and
refuses to bridge when net debt is unknown, a DCF whose working-capital charge
follows the CHANGE in revenue, whose growth path interpolates to the terminal
rate, whose exit-multiple terminal value is discounted from year N, with a stub
period from the valuation date and a built-up WACC, and a football field whose
conclusion excludes reference bars (the 52-week range) and a revenue multiple
applied to a margin outlier. On top of the Rails port this module calendarises
consensus estimates to a next-twelve-months (NTM) figure, because forward
multiples are how comps are actually quoted.
"""

from __future__ import annotations

import sqlite3
from dataclasses import dataclass, field, fields, replace
from datetime import date, datetime
from typing import Any, Iterable, Sequence

from .config import CONFIG
from .db import query, query_one

MULTIPLES = ("ev_revenue", "ev_ebitda", "pe")
MULTIPLE_LABELS = {"ev_revenue": "EV / Revenue", "ev_ebitda": "EV / EBITDA", "pe": "P / E"}
NTM_MULTIPLES = ("ev_revenue_ntm", "ev_ebitda_ntm", "pe_ntm")
NTM_LABELS = {"ev_revenue_ntm": "EV / NTM Revenue", "ev_ebitda_ntm": "EV / NTM EBITDA", "pe_ntm": "NTM P / E"}

# A forward multiple needs this many peers before it may set a football-field
# bar: two points have no interquartile range worth quoting.
MIN_NTM_PEERS = 3


# ---------------------------------------------------------------- statistics


def percentile(values: Sequence[float], pct: float) -> float | None:
    """Linear-interpolation percentile (``pct`` in [0, 1]); None on empty input."""
    clean = sorted(v for v in values if v is not None)
    if not clean:
        return None
    if len(clean) == 1:
        return float(clean[0])
    position = (len(clean) - 1) * max(0.0, min(1.0, pct))
    low = int(position)
    high = min(low + 1, len(clean) - 1)
    weight = position - low
    return float(clean[low] * (1 - weight) + clean[high] * weight)


def describe(values: Iterable[float]) -> dict[str, float | None]:
    clean = [float(v) for v in values if v is not None]
    if not clean:
        return {"count": 0, "min": None, "p25": None, "median": None, "p75": None, "max": None, "mean": None}
    return {
        "count": len(clean),
        "min": min(clean),
        "p25": percentile(clean, 0.25),
        "median": percentile(clean, 0.5),
        "p75": percentile(clean, 0.75),
        "max": max(clean),
        "mean": sum(clean) / len(clean),
    }


def _round_stats(stats: dict[str, Any], digits: int = 2) -> dict[str, Any]:
    return {k: (round(v, digits) if isinstance(v, float) else v) for k, v in stats.items()}


# -------------------------------------------------------------------- dates


def _to_date(value: Any) -> date | None:
    """An ISO string, date or datetime as a ``date``; None when absent or unparseable.

    Data rows are read leniently (an unparseable period end is treated as
    unknown rather than crashing a comps screen); user input goes through
    ``DCFAssumptions.coerce``, which is strict.
    """
    if value is None or value == "":
        return None
    if isinstance(value, datetime):
        return value.date()
    if isinstance(value, date):
        return value
    try:
        return date.fromisoformat(str(value)[:10])
    except ValueError:
        return None


def _add_years(day: date, years: int) -> date:
    """Same calendar day ``years`` later; 29 February falls back to the 28th (Ruby's ``>> 12``)."""
    try:
        return day.replace(year=day.year + years)
    except ValueError:
        return day.replace(year=day.year + years, day=28)


def _period_type(row: dict[str, Any]) -> str:
    """"FY" or "LTM"; databases built before the loader added the column are all FY."""
    return row.get("period_type") or "FY"


def basis_label(row: dict[str, Any] | None) -> str:
    """"LTM Jun-26" or "FY2025": the vintage every multiple is quoted on."""
    if row is None:
        return "n/a"
    if _period_type(row) != "LTM":
        return f"FY{row.get('fiscal_year')}"
    period_end = _to_date(row.get("period_end"))
    return f"LTM {period_end.strftime('%b-%y')}" if period_end else "LTM"


# ------------------------------------------------------------------ company


def _multiples_for(row: dict[str, Any], *, enterprise_value: float | None, price: float) -> dict[str, Any]:
    """One period's metrics with the multiples they imply.

    ``enterprise_value`` None (unknown net debt) leaves the EV multiples None:
    a multiple of an EV computed as if the company were debt-free is wrong,
    not approximate. Equity multiples (P/E) do not need the bridge.
    """
    revenue = float(row.get("revenue") or 0.0)
    ebitda = float(row.get("ebitda") or 0.0)
    eps = float(row.get("eps") or 0.0)
    return {
        "fiscal_year": row.get("fiscal_year"),
        "period_type": _period_type(row),
        "period_end": row.get("period_end"),
        "basis": basis_label(row),
        "is_estimate": bool(row.get("is_estimate")),
        "revenue": revenue,
        "ebitda": ebitda,
        "ebitda_margin": round(ebitda / revenue, 4) if revenue else None,
        "eps": eps,
        "ev_revenue": round(enterprise_value / revenue, 2) if revenue and enterprise_value is not None else None,
        "ev_ebitda": round(enterprise_value / ebitda, 2) if ebitda and enterprise_value is not None else None,
        "pe": round(price / eps, 2) if eps else None,
    }


def ntm_estimates(
    financials: Sequence[dict[str, Any]],
    as_of: Any,
    *,
    enterprise_value: float | None,
    price: float,
    basis: dict[str, Any] | None = None,
) -> dict[str, Any] | None:
    """Next-twelve-months figures, calendarised the way a comps page does it.

    A port of the Rails ``Valuation.ntm_metrics`` (the specification). FY0 is
    the fiscal year IN PROGRESS at ``as_of``: the first fiscal row, reported or
    estimated, whose period end (31 December of its year when the row has no
    date) falls after ``as_of``; FY1 is the fiscal year after it. Their weights
    are the share of FY0 still ahead, ``days left / 365.25``, and the rest.
    Only estimate rows used to qualify, so on the seed (FY2026 reported, a 9
    October price date) NTM was FY2027 alone — a year that had not started —
    instead of 22.7% FY2026 and 77.3% FY2027.

    Revenue and EPS come from the rows; EBITDA too when a row carries it,
    otherwise NTM revenue times the ``basis`` row's EBITDA margin (LTM, else
    the latest fiscal year), flagged ``ebitda_derived``, because no public
    source publishes consensus EBITDA. A figure FY1 lacks falls back to FY0's.
    None when no fiscal year ends after ``as_of``, or when FY0 is a reported
    year with nothing estimated after it (there is no forward view).
    LTM rows are ignored: they are not fiscal years.
    """
    rows = sorted(
        (f for f in financials if _period_type(f) == "FY"),
        key=lambda f: int(f.get("fiscal_year") or 0),
    )
    if not rows:
        return None
    as_of_date = _to_date(as_of) or date.today()

    def period_end(row: dict[str, Any]) -> date:
        return _to_date(row.get("period_end")) or date(int(row["fiscal_year"]), 12, 31)

    current = next((row for row in rows if period_end(row) > as_of_date), None)
    if current is None:
        return None
    following = next((row for row in rows if int(row["fiscal_year"]) == int(current["fiscal_year"]) + 1), None)
    if following is None and not current.get("is_estimate"):
        return None

    weight = max(0.0, min(1.0, (period_end(current) - as_of_date).days / 365.25))

    def blend(key: str) -> float | None:
        first = current.get(key)
        if first is None:
            return None
        second = following.get(key) if following is not None else None
        if second is None:
            return float(first)
        return weight * float(first) + (1 - weight) * float(second)

    revenue = blend("revenue")
    eps = blend("eps")
    ebitda = blend("ebitda")
    derived = False
    margin = (basis or {}).get("ebitda_margin")
    if ebitda is None and revenue is not None and margin is not None:
        ebitda = revenue * float(margin)
        derived = True
    source = (
        (following or {}).get("estimate_source") or current.get("estimate_source") or "estimate rows"
    )
    return {
        "revenue": round(revenue, 1) if revenue is not None else None,
        "ebitda": round(ebitda, 1) if ebitda is not None else None,
        "ebitda_derived": derived,
        "eps": round(eps, 2) if eps is not None else None,
        "ev_revenue": round(enterprise_value / revenue, 2) if revenue and enterprise_value is not None else None,
        "ev_ebitda": round(enterprise_value / ebitda, 2) if ebitda and enterprise_value is not None else None,
        "pe": round(price / eps, 2) if eps and price else None,
        "weight_current_year": round(weight, 4),
        "fiscal_years": [current["fiscal_year"]] + ([following["fiscal_year"]] if following is not None else []),
        "period_end": _add_years(as_of_date, 1).isoformat(),
        "as_of": as_of_date.isoformat(),
        "source": str(source),
        "label": "NTM",
    }


def company_metrics(conn: sqlite3.Connection, ticker: str, *, forward_years: int = 2) -> dict[str, Any] | None:
    """Capital structure and trading multiples for one company.

    ``latest_actual`` is the most recent reported fiscal year; ``ltm`` the
    trailing twelve months when the loader could build one from a 10-Q;
    ``valuation_basis`` is whichever of the two the comps and the football field
    use (LTM when it exists), labelled in ``basis_label`` so no page shows a
    multiple without its vintage. ``forward`` holds each estimate year and
    ``ntm`` the estimates calendarised to the next twelve months.

    Columns the loader added later (``period_type``, ``period_end``,
    ``estimate_source`` on financials; ``minority_interest``,
    ``preferred_equity``, ``net_debt_as_of``, ``balance_sheet_form``,
    ``debt_note``, ``shares_basic`` on market data) are read with ``.get`` so an
    older database still values: every row is then a fiscal year and the
    other claims are zero.
    """
    company = query_one(conn, "SELECT * FROM companies WHERE ticker = ?", (ticker.upper(),))
    if not company:
        return None
    market = query_one(conn, "SELECT * FROM market_data WHERE company_id = ?", (company["id"],)) or {}

    financials = query(conn, "SELECT * FROM financials WHERE company_id = ? ORDER BY fiscal_year", (company["id"],))
    # Fiscal year, then FY before LTM — the Rails order — whatever the schema.
    financials.sort(key=lambda f: (int(f.get("fiscal_year") or 0), _period_type(f)))
    fiscal = [f for f in financials if _period_type(f) != "LTM"]
    actuals = [f for f in fiscal if not f.get("is_estimate")]
    latest = actuals[-1] if actuals else (fiscal[-1] if fiscal else None)
    if latest is None:
        return None
    ltm_rows = [f for f in financials if _period_type(f) == "LTM"]
    ltm = max(ltm_rows, key=lambda f: str(f.get("period_end") or "")) if ltm_rows else None

    price = float(market.get("share_price") or 0.0)
    shares = float(market.get("shares_diluted") or 0.0)
    # Unknown net debt is unknown, not zero (audit): a peer with no balance-sheet
    # data fed the target's valuation range through an EV computed as if it
    # were debt-free. EV and the EV multiples stay None.
    net_debt = None if market.get("net_debt") is None else float(market["net_debt"])
    minority_interest = None if market.get("minority_interest") is None else float(market["minority_interest"])
    preferred_equity = None if market.get("preferred_equity") is None else float(market["preferred_equity"])
    other_claims = (minority_interest or 0.0) + (preferred_equity or 0.0)
    market_cap = price * shares
    enterprise_value = None if net_debt is None else market_cap + net_debt + other_claims
    shown_ev = None if enterprise_value is None else round(enterprise_value, 1)

    def multiples_for(row: dict[str, Any]) -> dict[str, Any]:
        return _multiples_for(row, enterprise_value=enterprise_value, price=price)

    basis_row = ltm or latest
    forwards = [multiples_for(f) for f in fiscal if f.get("is_estimate")][:forward_years]
    return {
        "company_id": company["id"],
        "ticker": company["ticker"],
        "name": company["name"],
        "sector": company.get("sector"),
        "industry": company.get("industry"),
        "country": company.get("country"),
        "hq": company.get("hq"),
        "employees": company.get("employees"),
        "currency": company.get("currency") or "USD",
        "description": company.get("description"),
        "as_of": market.get("as_of"),
        "share_price": price,
        "shares_diluted": shares,
        # The cover-page count, when the loader stored one, so a page can say
        # which share basis its per-share figures rest on.
        "shares_basic": None if market.get("shares_basic") is None else float(market["shares_basic"]),
        "net_debt": net_debt,
        "net_debt_as_of": market.get("net_debt_as_of"),
        "balance_sheet_form": market.get("balance_sheet_form"),
        "debt_note": market.get("debt_note"),
        "minority_interest": minority_interest,
        "preferred_equity": preferred_equity,
        "other_claims": round(other_claims, 1),
        "market_cap": round(market_cap, 1),
        "enterprise_value": shown_ev,
        "ev_bridge": {
            "price_date": market.get("as_of"),
            "share_price": price,
            "shares_diluted": shares,
            "market_cap": round(market_cap, 1),
            "net_debt": net_debt,
            "balance_sheet_date": market.get("net_debt_as_of"),
            "balance_sheet_form": market.get("balance_sheet_form"),
            "minority_interest": minority_interest,
            "preferred_equity": preferred_equity,
            "enterprise_value": shown_ev,
        },
        "week52_low": market.get("week52_low"),
        "week52_high": market.get("week52_high"),
        "beta": market.get("beta"),
        "latest_actual": multiples_for(latest),
        "ltm": multiples_for(ltm) if ltm else None,
        "valuation_basis": multiples_for(basis_row),
        "basis_label": basis_label(basis_row),
        "forward": forwards,
        "ntm": ntm_estimates(
            fiscal, market.get("as_of"),
            enterprise_value=enterprise_value, price=price, basis=multiples_for(basis_row),
        ),
        "financials": financials,
    }


# -------------------------------------------------------------- trading comps


def comps_table(conn: sqlite3.Connection, tickers: Sequence[str], *, exclude: str | None = None) -> dict[str, Any]:
    """Comparable companies table plus the distribution of each multiple.

    Each row says which period its multiples are on (``basis``); the
    statistics pool LTM and fiscal-year multiples when the set is mixed, and
    ``bases`` reports the mix so the page can say so. NTM multiples sit beside
    the trailing ones and get their own distributions.
    """
    rows: list[dict[str, Any]] = []
    for ticker in tickers:
        if exclude and ticker.upper() == exclude.upper():
            continue
        metrics = company_metrics(conn, ticker)
        if not metrics:
            continue
        basis = metrics["valuation_basis"]
        ntm = metrics["ntm"] or {}
        rows.append({
            "ticker": metrics["ticker"],
            "name": metrics["name"],
            "country": metrics["country"],
            "share_price": metrics["share_price"],
            "price_date": metrics["as_of"],
            "market_cap": metrics["market_cap"],
            "enterprise_value": metrics["enterprise_value"],
            "net_debt": metrics["net_debt"],
            "net_debt_as_of": metrics["net_debt_as_of"],
            "other_claims": metrics["other_claims"],
            "shares_diluted": metrics["shares_diluted"],
            "shares_basic": metrics["shares_basic"],
            "revenue": round(basis["revenue"], 1),
            "ebitda": round(basis["ebitda"], 1),
            "ebitda_margin": basis["ebitda_margin"],
            "ev_revenue": basis["ev_revenue"],
            "ev_ebitda": basis["ev_ebitda"],
            "pe": basis["pe"],
            "fiscal_year": basis["fiscal_year"],
            "basis": metrics["basis_label"],
            "period_type": basis["period_type"],
            "ev_revenue_ntm": ntm.get("ev_revenue"),
            "ev_ebitda_ntm": ntm.get("ev_ebitda"),
            "pe_ntm": ntm.get("pe"),
            "ntm_ebitda_derived": ntm.get("ebitda_derived"),
        })
    rows.sort(key=lambda r: -(r["enterprise_value"] or 0))
    stats = {m: _round_stats(describe(r[m] for r in rows)) for m in MULTIPLES + NTM_MULTIPLES}
    bases: dict[str, int] = {}
    for row in rows:
        bases[row["basis"]] = bases.get(row["basis"], 0) + 1
    return {"rows": rows, "stats": stats, "labels": {**MULTIPLE_LABELS, **NTM_LABELS}, "bases": bases}


def precedent_transactions(conn: sqlite3.Connection, *, sector: str | None = None) -> dict[str, Any]:
    """Precedent M&A transactions with multiple and premium distributions."""
    if sector:
        rows = query(conn, "SELECT * FROM transactions WHERE sector = ? ORDER BY announced_on DESC", (sector,))
    else:
        rows = query(conn, "SELECT * FROM transactions ORDER BY announced_on DESC")
    stats = {
        "ev_revenue": _round_stats(describe(r["ev_revenue"] for r in rows)),
        "ev_ebitda": _round_stats(describe(r["ev_ebitda"] for r in rows)),
        "premium_1day": _round_stats(describe(r["premium_1day"] for r in rows), 3),
    }
    return {"rows": rows, "stats": stats}


# ----------------------------------------------------------- implied values


def implied_from_multiple(
    multiple_low: float | None,
    multiple_high: float | None,
    *,
    metric_value: float | None,
    kind: str,
    net_debt: float | None,
    shares: float | None,
    other_claims: float = 0.0,
) -> dict[str, Any] | None:
    """Translate a multiple range into an implied share-price range.

    ``kind`` is ``ev`` (bridge through net debt and other claims — minority
    interest and preferred equity rank ahead of common equity too) or
    ``equity`` (already a per-share earnings multiple). An EV multiple cannot
    be bridged when net debt is unknown, so that returns None.
    """
    if not shares or multiple_low is None or multiple_high is None or not metric_value:
        return None
    if kind == "ev" and net_debt is None:
        return None
    low_m, high_m = sorted((float(multiple_low), float(multiple_high)))
    metric = float(metric_value)

    def per_share(multiple: float) -> float:
        if kind == "ev":
            return (multiple * metric - float(net_debt) - float(other_claims or 0.0)) / float(shares)
        return multiple * metric

    low, high = sorted((per_share(low_m), per_share(high_m)))
    return {
        "low": round(low, 2),
        "high": round(high, 2),
        "mid": round((low + high) / 2, 2),
        "multiple_low": round(low_m, 2),
        "multiple_high": round(high_m, 2),
        "metric_value": round(metric, 1),
    }


# -------------------------------------------------------------------- WACC


def normalised_tax_rate(metrics: dict[str, Any]) -> float:
    """The tax rate a DCF should carry: the latest filed effective rate, held to
    a normalised band because one year's rate is not a forecast."""
    actuals = [
        f for f in (metrics.get("financials") or [])
        if not f.get("is_estimate") and _period_type(f) != "LTM"
    ]
    filed = actuals[-1].get("tax_rate") if actuals else None
    if filed is None:
        return CONFIG.default_tax_rate
    return max(0.15, min(0.35, float(filed)))


def wacc_build(
    metrics: dict[str, Any],
    *,
    risk_free_rate: float = CONFIG.risk_free_rate,
    equity_risk_premium: float = CONFIG.equity_risk_premium,
    debt_spread: float = CONFIG.debt_spread,
    beta: float | None = None,
    tax_rate: float | None = None,
) -> dict[str, Any]:
    """Cost of capital built from its parts rather than a constant.

    The reference used 9.5% plus a beta nudge; the audit asked for the build a
    reader can check: CAPM cost of equity, risk-free plus a spread for debt,
    the market capital structure for the weights. Every input is echoed so the
    DCF slide can show the build. Net debt stands in for gross debt in the
    weights (gross debt is not stored).
    """
    beta_value = beta if beta is not None else metrics.get("beta")
    beta_assumed = not beta_value
    if beta_assumed:
        beta_value = CONFIG.default_beta
    cost_of_equity = risk_free_rate + float(beta_value) * equity_risk_premium
    pre_tax_cost_of_debt = risk_free_rate + debt_spread
    tax = tax_rate if tax_rate is not None else normalised_tax_rate(metrics)
    after_tax_cost_of_debt = pre_tax_cost_of_debt * (1 - tax)
    equity = max(float(metrics.get("market_cap") or 0.0), 0.0)
    debt = max(float(metrics.get("net_debt") or 0.0), 0.0)
    # Without a market capitalisation there is no capital structure to weight,
    # so the cost of capital is the cost of equity (all-equity), not all-debt.
    weight_debt = debt / (equity + debt) if equity > 0 else 0.0
    wacc = (1 - weight_debt) * cost_of_equity + weight_debt * after_tax_cost_of_debt

    notes: list[str] = []
    if beta_assumed:
        notes.append(
            f"Beta not loaded: market beta of {CONFIG.default_beta} assumed, so the cost of equity is the market's."
        )
    if weight_debt > 0:
        notes.append("Debt weight uses net debt as a proxy for gross debt.")
    if equity <= 0:
        notes.append("No market capitalisation: all-equity cost of capital.")
    notes.append(
        "Risk-free rate, equity risk premium and debt spread are house defaults, "
        "not observations as of the valuation date."
    )
    return {
        "risk_free_rate": risk_free_rate,
        "equity_risk_premium": equity_risk_premium,
        "beta": round(float(beta_value), 2),
        "beta_assumed": beta_assumed,
        "cost_of_equity": round(cost_of_equity, 4),
        "pre_tax_cost_of_debt": round(pre_tax_cost_of_debt, 4),
        "tax_rate": round(tax, 4),
        "after_tax_cost_of_debt": round(after_tax_cost_of_debt, 4),
        "weight_debt": round(weight_debt, 4),
        "weight_equity": round(1 - weight_debt, 4),
        "wacc": round(wacc, 4),
        "notes": notes,
    }


# -------------------------------------------------------------------- DCF

_FALSE_STRINGS = {"0", "f", "false", "off", "no", "n"}


def _to_bool(value: Any) -> bool:
    """Form params arrive as strings: "false" and "0" must mean false
    (``bool("false")`` is True, which silently switched conventions on)."""
    if isinstance(value, str):
        return value.strip().lower() not in _FALSE_STRINGS
    return bool(value)


def _to_iso_date(value: Any) -> str:
    """An ISO date string, validated (raises ValueError on anything else)."""
    if isinstance(value, datetime):
        return value.date().isoformat()
    if isinstance(value, date):
        return value.isoformat()
    return date.fromisoformat(str(value)).isoformat()


@dataclass(frozen=True)
class DCFAssumptions:
    """Inputs for the discounted cash flow. Rates are decimals.

    Frozen: a run is reproducible from its assumptions, and the assumptions are
    echoed back in every ``run_dcf`` result, which is what makes the DCF slide
    auditable. Defaults let a *partial* override dict (what the UI and API
    send) be coerced without restating the whole model; ``run_dcf`` validates.
    """

    base_revenue: float = 0.0
    revenue_growth: float = 0.12        # year-1 growth; later years interpolate linearly to terminal_growth
    ebitda_margin: float = 0.25
    margin_expansion: float = 0.004     # annual change in EBITDA margin over the explicit years
    da_pct_revenue: float = 0.05
    capex_pct_revenue: float = 0.04
    nwc_pct_revenue: float = 0.012      # working-capital investment per unit of revenue CHANGE
    tax_rate: float = CONFIG.default_tax_rate
    wacc: float = CONFIG.default_wacc
    terminal_growth: float = CONFIG.default_terminal_growth
    exit_multiple: float | None = None  # when set, terminal value = exit_multiple x final-year EBITDA
    years: int = CONFIG.projection_years
    net_debt: float | None = 0.0        # None = unknown: enterprise value only, no equity bridge
    other_claims: float = 0.0           # non-controlling interest + preferred equity, deducted with net debt
    shares_diluted: float | None = 1.0  # None/0 = unknown: no per-share value
    mid_year_convention: bool = True
    terminal_capex_floor: bool = True   # terminal-year capex at least equal to D&A
    stub_fraction: float = 1.0          # share of the first projected year still ahead at the valuation date
    start_year: int = 2027
    valuation_date: str | None = None   # ISO date the cash flows are discounted to

    _INTEGER_FIELDS = ("years", "start_year")
    _BOOLEAN_FIELDS = ("mid_year_convention", "terminal_capex_floor")
    _DATE_FIELDS = ("valuation_date",)

    @classmethod
    def coerce(cls, payload: dict[str, Any] | None) -> dict[str, Any]:
        """Type-coerce a partial assumptions dict, dropping unknown/blank keys.

        Values are cast to the field's type, so "0.08" from a form field and
        0.08 from JSON land identically; a value that is not a number raises
        ValueError rather than being silently dropped. Keys from an older
        model (``growth_fade``) are unknown now and ignored, so a pitch book
        saved before the audit still loads.
        """
        known = {f.name for f in fields(cls)}
        clean: dict[str, Any] = {}
        for key, value in (payload or {}).items():
            key = str(key)
            if key not in known or value is None or value == "":
                continue
            if key in cls._INTEGER_FIELDS:
                clean[key] = int(value)
            elif key in cls._BOOLEAN_FIELDS:
                clean[key] = _to_bool(value)
            elif key in cls._DATE_FIELDS:
                clean[key] = _to_iso_date(value)
            else:
                clean[key] = float(value)
        return clean

    @classmethod
    def from_dict(cls, payload: dict[str, Any] | None) -> "DCFAssumptions":
        return cls(**cls.coerce(payload))

    def with_overrides(self, payload: dict[str, Any] | None) -> "DCFAssumptions":
        """A copy with only the supplied assumptions replaced."""
        return replace(self, **self.coerce(payload))

    def to_dict(self) -> dict[str, Any]:
        return {f.name: getattr(self, f.name) for f in fields(self)}


def growth_path(a: DCFAssumptions) -> list[float]:
    """Year-by-year growth: linear from the first-year rate to the terminal rate.

    The reference faded growth by a fixed fraction and floored it at the
    terminal rate, so a negative first year jumped straight to terminal growth
    in year 2 (audit). Interpolation lands on the terminal rate in year N
    whatever the sign of the start.
    """
    first = float(a.revenue_growth)
    last = float(a.terminal_growth)
    if a.years == 1:
        return [first]
    return [first + (last - first) * i / (a.years - 1.0) for i in range(a.years)]


def discount_period(index: int, stub: float, mid_year: bool) -> float:
    """Years from the valuation date to the point year ``index``'s cash flow is
    discounted from: the end of the (stub) year, or its middle under the
    mid-year convention."""
    fraction = stub if index == 1 else 1.0
    elapsed = stub + (index - 1)
    return elapsed - fraction / 2.0 if mid_year else elapsed


def run_dcf(assumptions: DCFAssumptions | dict[str, Any]) -> dict[str, Any]:
    """Project unlevered free cash flow, discount it, and bridge to per share.

    Takes a DCFAssumptions (or a partial dict, coerced the way the API payload
    is). Invalid inputs raise ValueError.

    Mechanics (each one was an audit finding against the reference):

    * growth interpolates linearly from ``revenue_growth`` to ``terminal_growth``;
    * the working-capital charge is ``nwc_pct_revenue`` x the CHANGE in revenue,
      so flat revenue ties up nothing and a decline releases cash (the
      reference charged a share of the revenue LEVEL every year);
    * year 1 counts only its remaining ``stub_fraction`` and every cash flow is
      discounted from the valuation date (mid-period when the convention is on);
    * the terminal year is built explicitly: margin held, capex floored at D&A
      when ``terminal_capex_floor``, working capital on terminal growth;
    * a Gordon terminal value sits at N - 1/2 under the mid-year convention, an
      exit-multiple value (a point-in-time price at year end) always at N;
    * unknown net debt (None) gives an enterprise value and no equity bridge.
    """
    a = assumptions if isinstance(assumptions, DCFAssumptions) else DCFAssumptions.from_dict(assumptions)
    if a.wacc <= 0:
        raise ValueError("wacc must be positive")
    if a.base_revenue <= 0:
        raise ValueError("base_revenue must be positive")
    if a.years < 1:
        raise ValueError("years must be positive")
    if not 0.0 < float(a.stub_fraction) <= 1.0:
        raise ValueError("stub_fraction must be within (0, 1]")
    if a.exit_multiple is None and a.terminal_growth >= a.wacc:
        raise ValueError("terminal growth must be below WACC when using a growth-based terminal value")

    wacc = float(a.wacc)
    stub = float(a.stub_fraction)
    projections: list[dict[str, Any]] = []
    prior_revenue = float(a.base_revenue)
    margin = float(a.ebitda_margin)
    pv_total = 0.0

    for index, growth in enumerate(growth_path(a), start=1):
        revenue = prior_revenue * (1 + growth)
        margin += a.margin_expansion
        ebitda = revenue * margin
        dep_amort = revenue * a.da_pct_revenue
        ebit = ebitda - dep_amort
        taxes = max(0.0, ebit) * a.tax_rate
        capex = revenue * a.capex_pct_revenue
        nwc_change = a.nwc_pct_revenue * (revenue - prior_revenue)
        fcf_full_year = ebit - taxes + dep_amort - capex - nwc_change
        fraction = stub if index == 1 else 1.0
        fcf = fcf_full_year * fraction
        period = discount_period(index, stub, a.mid_year_convention)
        discount = 1 / ((1 + wacc) ** period)
        pv = fcf * discount
        pv_total += pv
        projections.append({
            "year": a.start_year + index - 1,
            "revenue": round(revenue, 1),
            "growth": round(growth, 4),
            "ebitda": round(ebitda, 1),
            "ebitda_margin": round(margin, 4),
            "ebit": round(ebit, 1),
            "taxes": round(taxes, 1),
            "dep_amort": round(dep_amort, 1),
            "capex": round(capex, 1),
            "nwc_change": round(nwc_change, 1),
            "fcf_full_year": round(fcf_full_year, 1),
            "period_fraction": round(fraction, 4),
            "fcf": round(fcf, 1),
            "discount_period": round(period, 4),
            "discount_factor": round(discount, 4),
            "pv_fcf": round(pv, 1),
        })
        prior_revenue = revenue

    # Terminal year (N+1), built explicitly so the bridge can be ticked and tied.
    final_revenue = prior_revenue
    terminal_growth = float(a.terminal_growth)
    t_revenue = final_revenue * (1 + terminal_growth)
    t_ebitda = t_revenue * margin
    t_dep_amort = t_revenue * a.da_pct_revenue
    t_ebit = t_ebitda - t_dep_amort
    t_taxes = max(0.0, t_ebit) * a.tax_rate
    t_capex = t_revenue * a.capex_pct_revenue
    # In perpetuity a business cannot shrink its asset base while growing.
    capex_floored = bool(a.terminal_capex_floor and t_capex < t_dep_amort)
    if capex_floored:
        t_capex = t_dep_amort
    t_nwc_change = a.nwc_pct_revenue * (t_revenue - final_revenue)
    terminal_fcf = t_ebit - t_taxes + t_dep_amort - t_capex - t_nwc_change
    final_ebitda = final_revenue * margin
    years_end = stub + a.years - 1  # end of the last explicit year, measured from the valuation date

    if a.exit_multiple is None:
        terminal_value = terminal_fcf / (wacc - terminal_growth)
        terminal_method = f"Gordon growth at {terminal_growth * 100:.1f}%"
        terminal_period = years_end - 0.5 if a.mid_year_convention else years_end
    else:
        terminal_value = a.exit_multiple * final_ebitda
        terminal_method = f"{a.exit_multiple:.1f}x exit EBITDA multiple"
        terminal_period = years_end  # a multiple is a price at year end, whatever the flow convention
    pv_terminal = terminal_value / ((1 + wacc) ** terminal_period)

    enterprise_value = pv_total + pv_terminal
    net_debt = None if a.net_debt is None else float(a.net_debt)
    other_claims = float(a.other_claims or 0.0)
    equity_value = None if net_debt is None else enterprise_value - net_debt - other_claims
    per_share = equity_value / float(a.shares_diluted) if equity_value is not None and a.shares_diluted else None
    first_ebitda = projections[0]["ebitda"]

    return {
        "assumptions": a.to_dict(),
        "valuation_date": a.valuation_date,
        "stub_fraction": round(stub, 4),
        "projections": projections,
        "terminal_year": {
            "year": a.start_year + a.years,
            "revenue": round(t_revenue, 1),
            "growth": round(terminal_growth, 4),
            "ebitda": round(t_ebitda, 1),
            "ebitda_margin": round(margin, 4),
            "ebit": round(t_ebit, 1),
            "taxes": round(t_taxes, 1),
            "dep_amort": round(t_dep_amort, 1),
            "capex": round(t_capex, 1),
            "capex_floored_at_da": capex_floored,
            "nwc_change": round(t_nwc_change, 1),
            "fcf": round(terminal_fcf, 1),
        },
        "pv_explicit": round(pv_total, 1),
        "terminal_value": round(terminal_value, 1),
        "pv_terminal": round(pv_terminal, 1),
        "terminal_method": terminal_method,
        "terminal_discount_period": round(terminal_period, 4),
        "terminal_share_of_ev": round(pv_terminal / enterprise_value, 4) if enterprise_value else None,
        # Cross-checks a banker asks for: the multiple a Gordon value implies,
        # the growth an exit multiple implies.
        "implied_exit_multiple": round(terminal_value / final_ebitda, 2) if final_ebitda else None,
        "implied_terminal_growth": round(wacc - terminal_fcf / terminal_value, 4) if terminal_value else None,
        "enterprise_value": round(enterprise_value, 1),
        "net_debt": None if net_debt is None else round(net_debt, 1),
        "other_claims": round(other_claims, 1),
        "equity_value": None if equity_value is None else round(equity_value, 1),
        "value_per_share": None if per_share is None else round(per_share, 2),
        "bridge_note": (
            "Net debt unknown: enterprise value only, no equity bridge or per-share value."
            if net_debt is None else None
        ),
        "implied_ev_ebitda": round(enterprise_value / first_ebitda, 2) if first_ebitda else None,
    }


def dcf_sensitivity(
    assumptions: DCFAssumptions | dict[str, Any],
    *,
    wacc_steps: Sequence[float] | None = None,
    terminal_steps: Sequence[float] | None = None,
) -> dict[str, Any]:
    """Per-share value across a WACC x terminal-growth grid."""
    a = assumptions if isinstance(assumptions, DCFAssumptions) else DCFAssumptions.from_dict(assumptions)
    waccs = list(wacc_steps or [a.wacc + d for d in (-0.015, -0.0075, 0.0, 0.0075, 0.015)])
    growths = list(terminal_steps or [a.terminal_growth + d for d in (-0.01, -0.005, 0.0, 0.005, 0.01)])
    grid: list[list[float | None]] = []
    for growth in growths:
        row: list[float | None] = []
        for wacc in waccs:
            trial = a.with_overrides({"wacc": wacc, "terminal_growth": growth})
            try:
                row.append(run_dcf(trial)["value_per_share"])
            except ValueError:
                # A corner where growth >= WACC has no finite value; the cell
                # stays blank rather than poisoning the min/max.
                row.append(None)
        grid.append(row)
    flat = [v for row in grid for v in row if v is not None]
    return {
        "wacc_axis": [round(w, 4) for w in waccs],
        "terminal_axis": [round(g, 4) for g in growths],
        "grid": grid,
        "min": min(flat) if flat else None,
        "max": max(flat) if flat else None,
    }


# ----------------------------------------------------------- football field


@dataclass
class ValuationRange:
    """One bar of the football field, plus whether it counts towards the
    concluded range and, when it does not, why."""

    method: str
    low: float
    high: float
    basis: str = ""
    detail: dict[str, Any] = field(default_factory=dict)
    in_conclusion: bool = True
    reference: bool = False
    note: str | None = None

    def as_dict(self) -> dict[str, Any]:
        low, high = sorted((float(self.low), float(self.high)))
        return {
            "method": self.method,
            "low": round(low, 2),
            "high": round(high, 2),
            "mid": round((low + high) / 2, 2),
            "basis": self.basis,
            "detail": self.detail,
            "in_conclusion": self.in_conclusion,
            "reference": self.reference,
            "note": self.note,
        }


def margin_outlier(target_margin: float | None, comp_rows: Sequence[dict[str, Any]]) -> str | None:
    """A note when the target's EBITDA margin falls outside the peers'
    interquartile range — a revenue multiple then prices the wrong business —
    and None otherwise (or when fewer than three peers report a margin)."""
    margins = [r["ebitda_margin"] for r in comp_rows if r.get("ebitda_margin") is not None]
    if target_margin is None or len(margins) < 3:
        return None
    p25 = percentile(margins, 0.25)
    p75 = percentile(margins, 0.75)
    if p25 <= float(target_margin) <= p75:
        return None
    return (
        f"Target EBITDA margin {float(target_margin) * 100:.1f}% is outside the peer interquartile range "
        f"{p25 * 100:.1f}%–{p75 * 100:.1f}%: the revenue multiple is shown but not used in the conclusion."
    )


def football_field(
    conn: sqlite3.Connection,
    target_ticker: str,
    comp_tickers: Sequence[str],
    *,
    assumptions: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Assemble every valuation methodology into one comparable set of ranges.

    Each range is expressed per share so the methodologies can be read against
    the current share price on a single axis — the whole point of the chart.
    A range carries ``in_conclusion``: the 52-week trading range is a reference
    bar, never a valuation method, and a revenue multiple is not applied to a
    target whose margin sits outside the peers' interquartile range. The
    concluded range is the median low to the median high of the bars that
    remain, and None when none does.
    """
    target = company_metrics(conn, target_ticker)
    if not target:
        raise ValueError(f"unknown ticker: {target_ticker}")

    basis = target["valuation_basis"]
    label = target["basis_label"]
    net_debt = target["net_debt"]
    other_claims = float(target["other_claims"] or 0.0)
    shares = target["shares_diluted"]
    target_ntm = target["ntm"]
    comps = comps_table(conn, comp_tickers, exclude=target_ticker)
    precedents = precedent_transactions(conn, sector=target["sector"])
    ranges: list[dict[str, Any]] = []
    bridge = {"kind": "ev", "net_debt": net_debt, "shares": shares, "other_claims": other_claims}

    # Forward multiples lead the comps (RAILS_PORT item 12): only with a target
    # NTM figure and enough peers quoting one for the interquartile range to
    # mean something.
    comp_ntm = comps["stats"]["ev_ebitda_ntm"]
    if target_ntm and target_ntm.get("ebitda") and comp_ntm["count"] >= MIN_NTM_PEERS:
        implied = implied_from_multiple(comp_ntm["p25"], comp_ntm["p75"], metric_value=target_ntm["ebitda"], **bridge)
        if implied:
            derivation = "consensus revenue at the current margin" if target_ntm["ebitda_derived"] else "estimate rows"
            ranges.append(ValuationRange(
                "Trading comps — NTM EV/EBITDA", implied["low"], implied["high"],
                basis=(  # Rails wording
                    f"{implied['multiple_low']}x–{implied['multiple_high']}x on NTM EBITDA of "
                    f"{implied['metric_value']:.0f} ({derivation}; {comp_ntm['count']} peers)"
                ),
                detail={**implied, "ebitda_derived": target_ntm["ebitda_derived"], "source": target_ntm["source"],
                        "weight_current_year": target_ntm["weight_current_year"],
                        "fiscal_years": target_ntm["fiscal_years"]},
                note=(
                    f"Target NTM EBITDA derived from NTM revenue at the {label} margin (no EBITDA estimate loaded)."
                    if target_ntm["ebitda_derived"] else None
                ),
            ).as_dict())

    comp_ebitda = comps["stats"]["ev_ebitda"]
    implied = implied_from_multiple(comp_ebitda["p25"], comp_ebitda["p75"], metric_value=basis["ebitda"], **bridge)
    if implied:
        ranges.append(ValuationRange(
            "Trading comps — EV/EBITDA", implied["low"], implied["high"],
            basis=f"{implied['multiple_low']}x–{implied['multiple_high']}x on {label} EBITDA of {implied['metric_value']:.0f}",
            detail=implied,
        ).as_dict())

    comp_revenue = comps["stats"]["ev_revenue"]
    implied = implied_from_multiple(comp_revenue["p25"], comp_revenue["p75"], metric_value=basis["revenue"], **bridge)
    if implied:
        outlier = margin_outlier(basis["ebitda_margin"], comps["rows"])
        ranges.append(ValuationRange(
            "Trading comps — EV/Revenue", implied["low"], implied["high"],
            basis=f"{implied['multiple_low']}x–{implied['multiple_high']}x on {label} revenue of {implied['metric_value']:.0f}",
            detail=implied,
            in_conclusion=outlier is None,
            note=outlier,
        ).as_dict())

    # With no precedent deals the quartiles are None and no bar is drawn: a
    # precedent range can only come from real transactions, never a placeholder.
    precedent_ebitda = precedents["stats"]["ev_ebitda"]
    implied = implied_from_multiple(
        precedent_ebitda["p25"], precedent_ebitda["p75"], metric_value=basis["ebitda"], **bridge
    )
    if implied:
        ranges.append(ValuationRange(
            "Precedent transactions — EV/EBITDA", implied["low"], implied["high"],
            basis=f"{implied['multiple_low']}x–{implied['multiple_high']}x on {label} EBITDA ({precedent_ebitda['count']} deals)",
            detail=implied,
        ).as_dict())

    wacc = wacc_build(target)
    dcf_assumptions = default_assumptions(target, wacc=wacc)
    if assumptions:
        dcf_assumptions = dcf_assumptions.with_overrides(assumptions)
    base = run_dcf(dcf_assumptions)
    # The displayed sensitivity table is deliberately wider than the band that
    # feeds the football field: the chart should show a defensible range, not the
    # extremes of a grid.
    sensitivity = dcf_sensitivity(dcf_assumptions)
    band = dcf_sensitivity(
        dcf_assumptions,
        wacc_steps=[dcf_assumptions.wacc + d for d in (-0.01, 0.0, 0.01)],
        terminal_steps=[dcf_assumptions.terminal_growth + d for d in (-0.005, 0.0, 0.005)],
    )
    dcf_note = None
    if band["min"] is None:
        dcf_note = base["bridge_note"] or "DCF per-share value unavailable (no share count)."
    else:
        ranges.append(ValuationRange(
            "DCF", band["min"], band["max"],
            basis=(
                f"WACC {dcf_assumptions.wacc * 100:.2f}% ±100bps, terminal growth "
                f"{dcf_assumptions.terminal_growth * 100:.2f}% ±50bps"
            ),
            detail={"base_case": base["value_per_share"]},
        ).as_dict())

    if target["week52_low"] and target["week52_high"]:
        ranges.append(ValuationRange(
            "52-week trading range", float(target["week52_low"]), float(target["week52_high"]),
            basis="Last twelve months of trading (reference only, not a valuation method)",
            in_conclusion=False, reference=True,
        ).as_dict())

    concluded = [r for r in ranges if r["in_conclusion"]]
    lows = [r["low"] for r in ranges]
    highs = [r["high"] for r in ranges]
    return {
        "target": {
            "ticker": target["ticker"], "name": target["name"], "share_price": target["share_price"],
            "shares_diluted": shares, "net_debt": net_debt, "other_claims": round(other_claims, 1),
            "currency": target["currency"], "market_cap": target["market_cap"],
            "enterprise_value": target["enterprise_value"], "basis_label": label,
            "price_date": target["as_of"], "balance_sheet_date": target["net_debt_as_of"],
        },
        "ranges": ranges,
        "axis": {"min": round(min(lows) * 0.9, 2) if lows else 0, "max": round(max(highs) * 1.05, 2) if highs else 0},
        "reference_price": target["share_price"],
        "comps": comps,
        "precedents": precedents,
        "wacc": wacc,
        "dcf": base,
        "dcf_note": dcf_note,
        "sensitivity": sensitivity,
        # Median low to median high of the bars that are valuation methods: the
        # interquartile version let whichever methodology had the widest band
        # dictate the conclusion, and averaging in the 52-week range let last
        # year's trading set this year's value (audit).
        "concluded_range": {
            "low": round(percentile([r["low"] for r in concluded], 0.5), 2) if concluded else None,
            "high": round(percentile([r["high"] for r in concluded], 0.5), 2) if concluded else None,
            "methods": [r["method"] for r in concluded],
        },
    }


def default_assumptions(metrics: dict[str, Any], wacc: dict[str, Any] | None = None) -> DCFAssumptions:
    """Seed DCF assumptions from a company's own history.

    Growth comes from the last two reported fiscal years; margin, D&A and capex
    intensity from the freshest period (LTM when there is one); working-capital
    intensity from a three-year average (a single year's swing is noise); the
    tax rate is held to a normalised band because one year's effective rate is
    not a forecast; and the WACC is built up (``wacc_build``, or the build
    passed in). The projection starts with the fiscal year after the latest
    reported one, of which only the part still ahead of the price date
    (``stub_fraction``) is counted. Net debt and the share count stay None when
    unknown: the DCF then reports an enterprise value and no per-share figure
    rather than bridging through zero or dividing by one share.
    """
    financials = metrics.get("financials") or []
    fiscal = [f for f in financials if _period_type(f) != "LTM"]
    actuals = [f for f in fiscal if not f.get("is_estimate")]
    latest = actuals[-1] if actuals else (fiscal[-1] if fiscal else {})
    ltm_rows = [f for f in financials if _period_type(f) == "LTM"]
    fresh = max(ltm_rows, key=lambda f: str(f.get("period_end") or "")) if ltm_rows else latest
    revenue = float(latest.get("revenue") or 0.0)
    fresh_revenue = float(fresh.get("revenue") or 0.0)
    ebitda = float(fresh.get("ebitda") or 0.0)

    growth = 0.10
    if len(actuals) >= 2 and actuals[-2].get("revenue"):
        growth = max(-0.1, min(0.45, revenue / float(actuals[-2]["revenue"]) - 1))

    nwc_ratios = [
        float(f["nwc_change"]) / float(f["revenue"])
        for f in actuals[-3:] if f.get("nwc_change") is not None and f.get("revenue")
    ]
    nwc_pct = sum(nwc_ratios) / len(nwc_ratios) if nwc_ratios else 0.012
    nwc_pct = max(-0.03, min(0.05, nwc_pct))

    start_year = int(latest.get("fiscal_year") or 2026) + 1
    valuation_date = _to_date(metrics.get("as_of")) or date.today()
    period_end = _to_date(latest.get("period_end"))
    first_year_end = _add_years(period_end, 1) if period_end else date(start_year, 12, 31)
    stub = max(0.02, min(1.0, (first_year_end - valuation_date).days / 365.25))

    build = wacc or wacc_build(metrics)
    shares = metrics.get("shares_diluted")
    return DCFAssumptions(
        base_revenue=revenue,
        revenue_growth=round(growth, 4),
        ebitda_margin=round(ebitda / fresh_revenue, 4) if fresh_revenue else 0.2,
        da_pct_revenue=round(float(fresh.get("dep_amort") or 0) / fresh_revenue, 4) if fresh_revenue else 0.05,
        capex_pct_revenue=round(float(fresh.get("capex") or 0) / fresh_revenue, 4) if fresh_revenue else 0.04,
        nwc_pct_revenue=round(nwc_pct, 4),
        tax_rate=build["tax_rate"],
        wacc=build["wacc"],
        terminal_growth=CONFIG.default_terminal_growth,
        net_debt=None if metrics.get("net_debt") is None else float(metrics["net_debt"]),
        other_claims=float(metrics.get("other_claims") or 0.0),
        shares_diluted=float(shares) if shares else None,
        stub_fraction=round(stub, 4),
        start_year=start_year,
        valuation_date=valuation_date.isoformat(),
    )
