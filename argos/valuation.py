"""Valuation mechanics: trading comps, precedent transactions, DCF, football field.

The numbers here are the ones a pitch book actually argues with, so each helper
returns its inputs alongside its outputs — a multiple without the metric it was
applied to is unauditable, and an unauditable number does not belong in a deck.

Conventions: all currency amounts are in millions of the company's reporting
currency; per-share figures are absolute; rates are decimals (0.095 = 9.5%).
"""

from __future__ import annotations

import sqlite3
from dataclasses import dataclass, field
from typing import Any, Iterable, Sequence

from .config import CONFIG
from .db import query, query_one

MULTIPLES = ("ev_revenue", "ev_ebitda", "pe")
MULTIPLE_LABELS = {"ev_revenue": "EV / Revenue", "ev_ebitda": "EV / EBITDA", "pe": "P / E"}


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


# ------------------------------------------------------------------ company


def company_metrics(conn: sqlite3.Connection, ticker: str, *, forward_years: int = 2) -> dict[str, Any] | None:
    """Capital structure and trading multiples for one company.

    Multiples are computed off the most recent *actual* fiscal year and off each
    forward estimate year, because comps are only comparable when the vintage of
    the denominator matches.
    """
    company = query_one(conn, """
        SELECT c.*, m.share_price, m.shares_diluted, m.net_debt, m.week52_low, m.week52_high, m.beta, m.as_of
        FROM companies c LEFT JOIN market_data m ON m.company_id = c.id
        WHERE c.ticker = ?
    """, (ticker.upper(),))
    if not company:
        return None

    financials = query(conn, "SELECT * FROM financials WHERE company_id = ? ORDER BY fiscal_year", (company["id"],))
    actuals = [f for f in financials if not f["is_estimate"]]
    latest = actuals[-1] if actuals else (financials[-1] if financials else None)
    if latest is None:
        return None

    price = float(company["share_price"] or 0.0)
    shares = float(company["shares_diluted"] or 0.0)
    net_debt = float(company["net_debt"] or 0.0)
    market_cap = price * shares
    enterprise_value = market_cap + net_debt

    def multiples_for(row: dict[str, Any]) -> dict[str, Any]:
        revenue = float(row["revenue"] or 0.0)
        ebitda = float(row["ebitda"] or 0.0)
        eps = float(row["eps"] or 0.0)
        return {
            "fiscal_year": row["fiscal_year"],
            "is_estimate": bool(row["is_estimate"]),
            "revenue": revenue,
            "ebitda": ebitda,
            "ebitda_margin": round(ebitda / revenue, 4) if revenue else None,
            "eps": eps,
            "ev_revenue": round(enterprise_value / revenue, 2) if revenue else None,
            "ev_ebitda": round(enterprise_value / ebitda, 2) if ebitda else None,
            "pe": round(price / eps, 2) if eps else None,
        }

    forwards = [multiples_for(f) for f in financials if f["is_estimate"]][:forward_years]
    return {
        "company_id": company["id"],
        "ticker": company["ticker"],
        "name": company["name"],
        "sector": company["sector"],
        "industry": company["industry"],
        "country": company["country"],
        "hq": company["hq"],
        "employees": company["employees"],
        "currency": company["currency"] or "USD",
        "description": company["description"],
        "as_of": company["as_of"],
        "share_price": price,
        "shares_diluted": shares,
        "net_debt": net_debt,
        "market_cap": round(market_cap, 1),
        "enterprise_value": round(enterprise_value, 1),
        "week52_low": company["week52_low"],
        "week52_high": company["week52_high"],
        "beta": company["beta"],
        "latest_actual": multiples_for(latest),
        "forward": forwards,
        "financials": financials,
    }


# -------------------------------------------------------------- trading comps


def comps_table(conn: sqlite3.Connection, tickers: Sequence[str], *, exclude: str | None = None) -> dict[str, Any]:
    """Comparable companies table plus the distribution of each multiple."""
    rows: list[dict[str, Any]] = []
    for ticker in tickers:
        if exclude and ticker.upper() == exclude.upper():
            continue
        metrics = company_metrics(conn, ticker)
        if not metrics:
            continue
        latest = metrics["latest_actual"]
        rows.append({
            "ticker": metrics["ticker"],
            "name": metrics["name"],
            "country": metrics["country"],
            "share_price": metrics["share_price"],
            "market_cap": metrics["market_cap"],
            "enterprise_value": metrics["enterprise_value"],
            "net_debt": metrics["net_debt"],
            "revenue": round(latest["revenue"], 1),
            "ebitda": round(latest["ebitda"], 1),
            "ebitda_margin": latest["ebitda_margin"],
            "ev_revenue": latest["ev_revenue"],
            "ev_ebitda": latest["ev_ebitda"],
            "pe": latest["pe"],
            "fiscal_year": latest["fiscal_year"],
        })
    rows.sort(key=lambda r: -(r["enterprise_value"] or 0))
    stats = {m: _round_stats(describe(r[m] for r in rows)) for m in MULTIPLES}
    return {"rows": rows, "stats": stats, "labels": MULTIPLE_LABELS}


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
    metric_value: float,
    kind: str,
    net_debt: float,
    shares: float,
) -> dict[str, Any] | None:
    """Translate a multiple range into an implied share-price range.

    ``kind`` is ``ev`` (bridge through net debt) or ``equity`` (already a
    per-share earnings multiple).
    """
    if not shares or multiple_low is None or multiple_high is None or not metric_value:
        return None
    low_m, high_m = sorted((float(multiple_low), float(multiple_high)))

    def per_share(multiple: float) -> float:
        if kind == "ev":
            return (multiple * metric_value - net_debt) / shares
        return multiple * metric_value

    low, high = sorted((per_share(low_m), per_share(high_m)))
    return {
        "low": round(low, 2),
        "high": round(high, 2),
        "mid": round((low + high) / 2, 2),
        "multiple_low": round(low_m, 2),
        "multiple_high": round(high_m, 2),
        "metric_value": round(metric_value, 1),
    }


# -------------------------------------------------------------------- DCF


@dataclass
class DCFAssumptions:
    """Inputs for the discounted cash flow. Rates are decimals."""

    # Defaults so a *partial* override dict (what the UI and API send) can be
    # coerced without having to restate the whole model; run_dcf validates.
    base_revenue: float = 0.0
    revenue_growth: float = 0.12
    growth_fade: float = 0.15           # fraction of growth given back each year
    ebitda_margin: float = 0.25
    margin_expansion: float = 0.004     # annual change in EBITDA margin
    da_pct_revenue: float = 0.05
    capex_pct_revenue: float = 0.04
    nwc_pct_revenue: float = 0.012      # change in net working capital
    tax_rate: float = CONFIG.default_tax_rate
    wacc: float = CONFIG.default_wacc
    terminal_growth: float = CONFIG.default_terminal_growth
    exit_multiple: float | None = None  # when set, terminal value = exit_multiple x terminal EBITDA
    years: int = CONFIG.projection_years
    net_debt: float = 0.0
    shares_diluted: float = 1.0
    mid_year_convention: bool = True
    start_year: int = 2027

    @classmethod
    def coerce(cls, payload: dict[str, Any]) -> dict[str, Any]:
        """Type-coerce a partial assumptions dict, dropping unknown/blank keys."""
        fields = set(cls.__dataclass_fields__)
        clean: dict[str, Any] = {}
        for key, value in (payload or {}).items():
            if key not in fields or value is None or value == "":
                continue
            if key in ("years", "start_year"):
                clean[key] = int(value)
            elif key == "mid_year_convention":
                clean[key] = bool(value)
            else:
                clean[key] = float(value)
        return clean

    @classmethod
    def from_dict(cls, payload: dict[str, Any]) -> "DCFAssumptions":
        return cls(**cls.coerce(payload))

    def with_overrides(self, payload: dict[str, Any]) -> "DCFAssumptions":
        """A copy with only the supplied assumptions replaced."""
        return DCFAssumptions(**{**self.to_dict(), **self.coerce(payload)})

    def to_dict(self) -> dict[str, Any]:
        return {f: getattr(self, f) for f in self.__dataclass_fields__}


def run_dcf(assumptions: DCFAssumptions) -> dict[str, Any]:
    """Project unlevered free cash flow, discount it, and bridge to per share."""
    a = assumptions
    if a.wacc <= 0:
        raise ValueError("wacc must be positive")
    if a.base_revenue <= 0:
        raise ValueError("base_revenue must be positive")
    if a.exit_multiple is None and a.terminal_growth >= a.wacc:
        raise ValueError("terminal growth must be below WACC when using a growth-based terminal value")

    projections: list[dict[str, Any]] = []
    revenue = float(a.base_revenue)
    growth = float(a.revenue_growth)
    margin = float(a.ebitda_margin)
    pv_total = 0.0

    for index in range(1, a.years + 1):
        revenue *= (1 + growth)
        margin += a.margin_expansion
        ebitda = revenue * margin
        dep_amort = revenue * a.da_pct_revenue
        ebit = ebitda - dep_amort
        taxes = max(0.0, ebit) * a.tax_rate
        capex = revenue * a.capex_pct_revenue
        nwc = revenue * a.nwc_pct_revenue
        fcf = ebit - taxes + dep_amort - capex - nwc
        period = index - 0.5 if a.mid_year_convention else index
        discount = 1 / ((1 + a.wacc) ** period)
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
            "nwc_change": round(nwc, 1),
            "fcf": round(fcf, 1),
            "discount_factor": round(discount, 4),
            "pv_fcf": round(pv, 1),
        })
        growth = max(a.terminal_growth, growth * (1 - a.growth_fade))

    terminal_fcf = projections[-1]["fcf"] * (1 + a.terminal_growth)
    if a.exit_multiple is not None:
        terminal_value = a.exit_multiple * projections[-1]["ebitda"]
        terminal_method = f"{a.exit_multiple:.1f}x exit EBITDA multiple"
    else:
        terminal_value = terminal_fcf / (a.wacc - a.terminal_growth)
        terminal_method = f"Gordon growth at {a.terminal_growth * 100:.1f}%"
    terminal_period = a.years - 0.5 if a.mid_year_convention else a.years
    pv_terminal = terminal_value / ((1 + a.wacc) ** terminal_period)

    enterprise_value = pv_total + pv_terminal
    equity_value = enterprise_value - a.net_debt
    per_share = equity_value / a.shares_diluted if a.shares_diluted else None

    return {
        "assumptions": a.to_dict(),
        "projections": projections,
        "pv_explicit": round(pv_total, 1),
        "terminal_value": round(terminal_value, 1),
        "pv_terminal": round(pv_terminal, 1),
        "terminal_method": terminal_method,
        "terminal_share_of_ev": round(pv_terminal / enterprise_value, 4) if enterprise_value else None,
        "enterprise_value": round(enterprise_value, 1),
        "net_debt": round(a.net_debt, 1),
        "equity_value": round(equity_value, 1),
        "value_per_share": round(per_share, 2) if per_share is not None else None,
        "implied_ev_ebitda": round(enterprise_value / projections[0]["ebitda"], 2) if projections[0]["ebitda"] else None,
    }


def dcf_sensitivity(
    assumptions: DCFAssumptions,
    *,
    wacc_steps: Sequence[float] | None = None,
    terminal_steps: Sequence[float] | None = None,
) -> dict[str, Any]:
    """Per-share value across a WACC x terminal-growth grid."""
    waccs = list(wacc_steps or [assumptions.wacc + d for d in (-0.015, -0.0075, 0.0, 0.0075, 0.015)])
    growths = list(terminal_steps or [assumptions.terminal_growth + d for d in (-0.01, -0.005, 0.0, 0.005, 0.01)])
    grid: list[list[float | None]] = []
    for growth in growths:
        row: list[float | None] = []
        for wacc in waccs:
            trial = assumptions.with_overrides({"wacc": wacc, "terminal_growth": growth})
            try:
                row.append(run_dcf(trial)["value_per_share"])
            except ValueError:
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
    method: str
    low: float
    high: float
    basis: str = ""
    detail: dict[str, Any] = field(default_factory=dict)

    def as_dict(self) -> dict[str, Any]:
        low, high = sorted((float(self.low), float(self.high)))
        return {
            "method": self.method,
            "low": round(low, 2),
            "high": round(high, 2),
            "mid": round((low + high) / 2, 2),
            "basis": self.basis,
            "detail": self.detail,
        }


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
    """
    target = company_metrics(conn, target_ticker)
    if not target:
        raise ValueError(f"unknown ticker: {target_ticker}")

    latest = target["latest_actual"]
    net_debt = target["net_debt"]
    shares = target["shares_diluted"]
    comps = comps_table(conn, comp_tickers, exclude=target_ticker)
    precedents = precedent_transactions(conn, sector=target["sector"])
    ranges: list[dict[str, Any]] = []

    comp_ebitda = comps["stats"]["ev_ebitda"]
    implied = implied_from_multiple(
        comp_ebitda["p25"], comp_ebitda["p75"],
        metric_value=latest["ebitda"], kind="ev", net_debt=net_debt, shares=shares,
    )
    if implied:
        ranges.append(ValuationRange(
            "Trading comps — EV/EBITDA", implied["low"], implied["high"],
            basis=f"{implied['multiple_low']}x–{implied['multiple_high']}x on FY{latest['fiscal_year']} EBITDA of {implied['metric_value']:.0f}",
            detail=implied,
        ).as_dict())

    comp_revenue = comps["stats"]["ev_revenue"]
    implied = implied_from_multiple(
        comp_revenue["p25"], comp_revenue["p75"],
        metric_value=latest["revenue"], kind="ev", net_debt=net_debt, shares=shares,
    )
    if implied:
        ranges.append(ValuationRange(
            "Trading comps — EV/Revenue", implied["low"], implied["high"],
            basis=f"{implied['multiple_low']}x–{implied['multiple_high']}x on FY{latest['fiscal_year']} revenue of {implied['metric_value']:.0f}",
            detail=implied,
        ).as_dict())

    precedent_ebitda = precedents["stats"]["ev_ebitda"]
    implied = implied_from_multiple(
        precedent_ebitda["p25"], precedent_ebitda["p75"],
        metric_value=latest["ebitda"], kind="ev", net_debt=net_debt, shares=shares,
    )
    if implied:
        ranges.append(ValuationRange(
            "Precedent transactions — EV/EBITDA", implied["low"], implied["high"],
            basis=f"{implied['multiple_low']}x–{implied['multiple_high']}x on FY{latest['fiscal_year']} EBITDA ({precedent_ebitda['count']} deals)",
            detail=implied,
        ).as_dict())

    dcf_assumptions = default_assumptions(target)
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
    if band["min"] is not None:
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
            basis="Last twelve months of trading",
        ).as_dict())

    lows = [r["low"] for r in ranges]
    highs = [r["high"] for r in ranges]
    return {
        "target": {
            "ticker": target["ticker"], "name": target["name"], "share_price": target["share_price"],
            "shares_diluted": shares, "net_debt": net_debt, "currency": target["currency"],
            "market_cap": target["market_cap"], "enterprise_value": target["enterprise_value"],
        },
        "ranges": ranges,
        "axis": {"min": round(min(lows) * 0.9, 2) if lows else 0, "max": round(max(highs) * 1.05, 2) if highs else 0},
        "reference_price": target["share_price"],
        "comps": comps,
        "precedents": precedents,
        "dcf": base,
        "sensitivity": sensitivity,
        # Median low to median high: the interquartile version let whichever
        # methodology had the widest band dictate the conclusion.
        "concluded_range": {
            "low": round(percentile(lows, 0.5) or 0, 2),
            "high": round(percentile(highs, 0.5) or 0, 2),
        },
    }


def default_assumptions(metrics: dict[str, Any]) -> DCFAssumptions:
    """Seed DCF assumptions from a company's own history.

    Growth comes from the last two actual years, margin from the latest actual,
    and capex/D&A intensity from the same period, so the base case is the
    company's own trajectory rather than a house view.
    """
    financials = metrics.get("financials") or []
    actuals = [f for f in financials if not f["is_estimate"]]
    latest = actuals[-1] if actuals else (financials[-1] if financials else {})
    revenue = float(latest.get("revenue") or 0.0)
    ebitda = float(latest.get("ebitda") or 0.0)

    growth = 0.10
    if len(actuals) >= 2 and actuals[-2]["revenue"]:
        growth = max(-0.1, min(0.45, revenue / float(actuals[-2]["revenue"]) - 1))

    return DCFAssumptions(
        base_revenue=revenue,
        revenue_growth=round(growth, 4),
        ebitda_margin=round(ebitda / revenue, 4) if revenue else 0.2,
        da_pct_revenue=round(float(latest.get("dep_amort") or 0) / revenue, 4) if revenue else 0.05,
        capex_pct_revenue=round(float(latest.get("capex") or 0) / revenue, 4) if revenue else 0.04,
        nwc_pct_revenue=round(float(latest.get("nwc_change") or 0) / revenue, 4) if revenue else 0.012,
        tax_rate=float(latest.get("tax_rate") or CONFIG.default_tax_rate),
        wacc=round(CONFIG.default_wacc + ((float(metrics.get("beta") or 1.0) - 1.0) * 0.02), 4),
        terminal_growth=CONFIG.default_terminal_growth,
        net_debt=float(metrics.get("net_debt") or 0.0),
        shares_diluted=float(metrics.get("shares_diluted") or 1.0),
        start_year=int(latest.get("fiscal_year") or 2026) + 1,
    )
