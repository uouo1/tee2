"""Self-contained HTML deck export.

One file, no external assets, printable to PDF from a browser. Charts are the
same server-side SVG the web UI renders, and the palette tokens are inlined for
both colour schemes, so a deck mailed to a colleague looks right on their
machine whichever theme they use.
"""

from __future__ import annotations

import html
from pathlib import Path
from typing import Any, Sequence

from .. import charts

CURRENCY_SYMBOLS = {"USD": "$", "EUR": "€", "GBP": "£"}


def _esc(value: Any) -> str:
    return html.escape(str(value if value is not None else ""))


def _symbol(currency: str | None) -> str:
    return CURRENCY_SYMBOLS.get((currency or "USD").upper(), "")


def _money(value: Any, currency: str = "USD") -> str:
    if value is None:
        return "n/a"
    try:
        amount = float(value)
    except (TypeError, ValueError):
        return str(value)
    symbol = _symbol(currency)
    return f"{symbol}{amount / 1000:,.1f}bn" if abs(amount) >= 1000 else f"{symbol}{amount:,.0f}m"


def _pct(value: Any, digits: int = 1) -> str:
    if value is None:
        return "n/a"
    try:
        return f"{float(value) * 100:.{digits}f}%"
    except (TypeError, ValueError):
        return str(value)


def _mult(value: Any) -> str:
    if value is None:
        return "n/a"
    try:
        return f"{float(value):.1f}x"
    except (TypeError, ValueError):
        return str(value)


STYLE = """
*, *::before, *::after { box-sizing: border-box; }
body {
  margin: 0; background: var(--plane); color: var(--text-primary);
  font-family: system-ui, -apple-system, "Segoe UI", sans-serif; font-size: 15px; line-height: 1.5;
}
.deck { max-width: 1060px; margin: 0 auto; padding: 32px 16px 64px; }
.slide {
  background: var(--surface-1); border: 1px solid var(--border); border-radius: 10px;
  padding: 28px 30px 30px; margin-bottom: 22px; page-break-after: always; break-after: page;
}
.slide:last-child { page-break-after: auto; }
.slide-no { font-size: 11px; letter-spacing: 0.08em; text-transform: uppercase; color: var(--muted); }
h1 { font-size: 30px; margin: 10px 0 6px; line-height: 1.2; }
h2 { font-size: 21px; margin: 6px 0 4px; line-height: 1.25; }
.sub { color: var(--text-secondary); font-size: 13.5px; margin: 0 0 18px; }
.cover { min-height: 420px; display: flex; flex-direction: column; justify-content: center; }
.cover .meta { color: var(--text-secondary); font-size: 14px; margin-top: 24px; }
.badge {
  display: inline-block; font-size: 10.5px; letter-spacing: 0.1em; text-transform: uppercase;
  border: 1px solid var(--border); border-radius: 999px; padding: 3px 10px; color: var(--text-secondary);
}
ul.bullets { margin: 0; padding-left: 20px; }
ul.bullets li { margin-bottom: 11px; }
.cite { display: block; font-size: 11.5px; color: var(--muted); margin-top: 3px; }
.grid { display: grid; gap: 18px; }
.grid.two { grid-template-columns: 1fr 1fr; }
.grid.kpis { grid-template-columns: repeat(4, 1fr); gap: 12px; }
.kpi { border: 1px solid var(--border); border-radius: 8px; padding: 10px 12px; }
.kpi .label { font-size: 11px; color: var(--muted); text-transform: uppercase; letter-spacing: 0.05em; }
.kpi .value { font-size: 19px; margin-top: 3px; }
table { border-collapse: collapse; width: 100%; font-size: 12.5px; }
caption.viz-caption { caption-side: top; text-align: left; font-size: 11.5px; color: var(--muted); padding-bottom: 6px; }
th, td { padding: 6px 8px; border-bottom: 1px solid var(--grid); text-align: left; }
th { color: var(--text-secondary); font-weight: 600; font-size: 11.5px; }
td.num, th.num { text-align: right; font-variant-numeric: tabular-nums; }
tbody tr.is-highlight { background: color-mix(in srgb, var(--series-1) 12%, transparent); font-weight: 600; }
tfoot td { border-top: 1px solid var(--axis); border-bottom: none; color: var(--text-secondary); }
.heatmap td { text-align: center; font-variant-numeric: tabular-nums; border: 2px solid var(--surface-1); }
.heat-1 { background: var(--seq-1); color: #0b0b0b; } .heat-2 { background: var(--seq-2); color: #0b0b0b; }
.heat-3 { background: var(--seq-3); color: #0b0b0b; } .heat-4 { background: var(--seq-4); color: #fff; }
.heat-5 { background: var(--seq-5); color: #fff; } .heat-6 { background: var(--seq-6); color: #fff; }
.heat-7 { background: var(--seq-7); color: #fff; }
.heat-ref { outline: 2px solid var(--text-primary); outline-offset: -2px; }
.note { font-size: 12.5px; color: var(--text-secondary); margin-top: 14px; }
.quote { border-left: 3px solid var(--series-1); padding: 4px 0 4px 12px; margin: 0 0 14px; font-size: 13px; }
.quote .src { display: block; color: var(--muted); font-size: 11.5px; margin-top: 4px; }
.pill { font-size: 11px; color: var(--text-secondary); border: 1px solid var(--border); border-radius: 999px; padding: 2px 8px; margin-right: 6px; display: inline-block; }
.disclaimer { font-size: 12.5px; color: var(--text-secondary); }
@media print {
  body { background: #fff; }
  .deck { max-width: none; padding: 0; }
  .slide { border: none; border-radius: 0; margin: 0; padding: 24px; min-height: 96vh; }
}
@media (max-width: 760px) {
  .deck { padding: 16px; }
  .grid.two, .grid.kpis { grid-template-columns: 1fr; }
  h1 { font-size: 24px; }
}
"""


def _slide_shell(index: int, total: int, slide: dict[str, Any], body: str, *, cover: bool = False) -> str:
    subtitle = f'<p class="sub">{_esc(slide.get("subtitle"))}</p>' if slide.get("subtitle") else ""
    heading = "h1" if cover else "h2"
    counter = "" if cover else f'<div class="slide-no">{index} / {total}</div>'
    return (
        f'<section class="slide{" cover" if cover else ""}">{counter}'
        f'<{heading}>{_esc(slide.get("title"))}</{heading}>{subtitle}{body}</section>'
    )


def _bullets_html(bullets: Sequence[Any]) -> str:
    items = []
    for bullet in bullets:
        if isinstance(bullet, str):
            items.append(f"<li>{_esc(bullet)}</li>")
            continue
        source = bullet.get("source")
        cite = ""
        if source:
            cite = (
                f'<span class="cite">Source: {_esc(source.get("title"))} · '
                f'{_esc(source.get("doc_type"))} · {_esc(source.get("published_at"))} '
                f'[doc {_esc(source.get("document_id"))}]</span>'
            )
        items.append(f'<li>{_esc(bullet.get("text"))}{cite}</li>')
    return f'<ul class="bullets">{"".join(items)}</ul>'


def _render_cover(slide: dict[str, Any]) -> str:
    payload = slide.get("payload", {})
    parts = ['<div><span class="badge">Confidential — discussion materials</span></div>']
    if payload.get("client_name"):
        parts.append(f'<p class="meta">Prepared for {_esc(payload["client_name"])}</p>')
    meta = [payload.get("target"), payload.get("ticker"), payload.get("banker"), payload.get("date")]
    parts.append('<p class="meta">' + " · ".join(_esc(m) for m in meta if m) + "</p>")
    return "".join(parts)


def _render_executive_summary(slide: dict[str, Any]) -> str:
    payload = slide.get("payload", {})
    currency = payload.get("currency", "USD")
    reference = payload.get("reference_range") or {}
    symbol = _symbol(currency)
    tiles = ""
    if reference:
        tiles = (
            '<div class="grid kpis">'
            f'<div class="kpi"><div class="label">Reference range</div><div class="value">'
            f'{symbol}{reference.get("low", 0):,.2f} – {symbol}{reference.get("high", 0):,.2f}</div></div>'
            f'<div class="kpi"><div class="label">Current price</div><div class="value">'
            f'{symbol}{payload.get("share_price", 0):,.2f}</div></div>'
            "</div>"
        )
    return tiles + _bullets_html(payload.get("bullets", []))


def _render_company_overview(slide: dict[str, Any]) -> str:
    payload = slide.get("payload", {})
    tiles = "".join(
        f'<div class="kpi"><div class="label">{_esc(k["label"])}</div><div class="value">{_esc(k["value"])}</div></div>'
        for k in payload.get("kpis", [])
    )
    extracted = payload.get("extracted_kpis") or []
    extracted_html = ""
    if extracted:
        pills = "".join(
            f'<span class="pill">{_esc(k["label"])}: {_esc(k["value"])} '
            f'({_esc(k["observations"])} obs.)</span>' for k in extracted
        )
        extracted_html = (
            '<p class="note"><strong>Metrics extracted from the corpus</strong><br>' + pills + "</p>"
        )
    return (
        f'<p>{_esc(payload.get("description"))}</p>'
        f'<div class="grid kpis" style="margin-top:16px">{tiles}</div>{extracted_html}'
    )


def _render_market_overview(slide: dict[str, Any]) -> str:
    payload = slide.get("payload", {})
    timeline = payload.get("sentiment_timeline") or []
    volume = payload.get("volume_by_type") or {}
    themes = payload.get("themes") or []
    theme_table = charts.table_html(
        [
            {"key": "theme", "label": "Theme"},
            {"key": "mentions", "label": "Documents (recent)", "numeric": True},
            {"key": "prior_mentions", "label": "Prior period", "numeric": True},
            {"key": "lift", "label": "Lift", "numeric": True, "format": "{:.2f}x"},
        ],
        themes[:8],
        caption="Themes over-represented versus the preceding comparable period",
    )
    sentiment_chart = charts.diverging_bar_svg(
        [row["month"][-5:] for row in timeline],
        [float(row["sentiment"] or 0) for row in timeline],
        title="Mean document tone by month (−1 to +1)",
    ) if timeline else ""
    volume_chart = charts.stacked_bar_svg(
        [m[-5:] for m in volume.get("months", [])],
        volume.get("series", []),
        title="Documents published by type",
    ) if volume.get("months") else ""
    return (
        f'<p>{_esc(payload.get("narrative"))}</p>'
        f'<div class="grid two" style="margin-top:14px">{sentiment_chart}{volume_chart}</div>'
        f'<div style="margin-top:18px">{theme_table}</div>'
    )


def _render_financials(slide: dict[str, Any]) -> str:
    payload = slide.get("payload", {})
    rows = payload.get("rows", [])
    currency = payload.get("currency", "USD")
    estimate_from = next((i for i, r in enumerate(rows) if r.get("is_estimate")), None)
    revenue_chart = charts.column_chart_svg(
        [f"FY{r['fiscal_year']}" for r in rows],
        [float(r["revenue"] or 0) for r in rows],
        title=f"Revenue ({currency}m)",
        estimate_from=estimate_from,
        value_format="{:,.0f}",
    )
    margin_chart = charts.line_chart_svg(
        [f"FY{r['fiscal_year']}" for r in rows],
        [(float(r["ebitda_margin"]) * 100 if r.get("ebitda_margin") is not None else None) for r in rows],
        title="EBITDA margin (%)",
    )
    table = charts.table_html(
        [
            {"key": "fiscal_year", "label": "FY", "format": "FY{}"},
            {"key": "revenue", "label": f"Revenue ({currency}m)", "numeric": True, "format": "{:,.0f}"},
            {"key": "ebitda", "label": f"EBITDA ({currency}m)", "numeric": True, "format": "{:,.0f}"},
            {"key": "ebitda_margin", "label": "Margin", "numeric": True, "format": "{:.1%}"},
            {"key": "ebit", "label": "EBIT", "numeric": True, "format": "{:,.0f}"},
            {"key": "net_income", "label": "Net income", "numeric": True, "format": "{:,.0f}"},
            {"key": "eps", "label": "EPS", "numeric": True, "format": "{:,.2f}"},
            {"key": "capex", "label": "Capex", "numeric": True, "format": "{:,.0f}"},
        ],
        rows,
        caption="Forward years are estimates",
    )
    note = f'<p class="note">{_esc(payload.get("note"))}</p>' if payload.get("note") else ""
    return f'<div class="grid two">{revenue_chart}{margin_chart}</div>{note}<div style="margin-top:16px">{table}</div>'


def _render_valuation_summary(slide: dict[str, Any]) -> str:
    payload = slide.get("payload", {})
    currency = payload.get("currency", "USD")
    chart = charts.football_field_svg(
        payload.get("ranges", []),
        reference_price=payload.get("reference_price"),
        concluded=payload.get("concluded_range"),
        currency_symbol=_symbol(currency),
    )
    table = charts.table_html(
        [
            {"key": "method", "label": "Methodology"},
            {"key": "low", "label": "Low", "numeric": True, "format": "{:,.2f}"},
            {"key": "high", "label": "High", "numeric": True, "format": "{:,.2f}"},
            {"key": "mid", "label": "Midpoint", "numeric": True, "format": "{:,.2f}"},
            {"key": "basis", "label": "Basis"},
        ],
        payload.get("ranges", []),
        caption=f"Implied value per share ({currency})",
    )
    concluded = payload.get("concluded_range") or {}
    note = (
        f'<p class="note">Concluded reference range of {_symbol(currency)}{concluded.get("low", 0):,.2f}–'
        f'{_symbol(currency)}{concluded.get("high", 0):,.2f} per share is the median low and median high across '
        f'methodologies, against a current price of {_symbol(currency)}{payload.get("reference_price", 0):,.2f}.</p>'
    )
    return f"{chart}{note}<div style='margin-top:16px'>{table}</div>"


def _render_trading_comps(slide: dict[str, Any]) -> str:
    payload = slide.get("payload", {})
    currency = payload.get("currency", "USD")
    target = dict(payload.get("target") or {})
    rows = [dict(r) for r in payload.get("rows", [])]
    all_rows = ([target] if target else []) + rows
    labels = [r.get("ticker", "") for r in all_rows]
    values = [float(r.get("ev_ebitda") or 0) for r in all_rows]
    chart = charts.column_chart_svg(
        labels, values, title="EV / EBITDA by company (target highlighted)",
        value_format="{:,.1f}x", highlight_index=0 if target else None,
    )
    stats = payload.get("stats", {})
    columns = [
        {"key": "ticker", "label": "Ticker"},
        {"key": "name", "label": "Company"},
        {"key": "share_price", "label": "Price", "numeric": True, "format": "{:,.2f}"},
        {"key": "market_cap", "label": f"Mkt cap ({currency}m)", "numeric": True, "format": "{:,.0f}"},
        {"key": "enterprise_value", "label": f"EV ({currency}m)", "numeric": True, "format": "{:,.0f}"},
        {"key": "revenue", "label": "Revenue", "numeric": True, "format": "{:,.0f}"},
        {"key": "ebitda_margin", "label": "EBITDA margin", "numeric": True, "format": "{:.1%}"},
        {"key": "ev_revenue", "label": "EV/Rev", "numeric": True, "format": "{:,.1f}x"},
        {"key": "ev_ebitda", "label": "EV/EBITDA", "numeric": True, "format": "{:,.1f}x"},
        {"key": "pe", "label": "P/E", "numeric": True, "format": "{:,.1f}x"},
    ]
    table = charts.table_html(columns, all_rows, highlight_key="is_target", caption="Target shown in the first row")
    stat_rows = []
    for key, label in (("ev_revenue", "EV / Revenue"), ("ev_ebitda", "EV / EBITDA"), ("pe", "P / E")):
        bucket = stats.get(key, {})
        stat_rows.append(
            f"<tr><th scope='row'>{_esc(label)}</th>"
            f"<td class='num'>{_mult(bucket.get('min'))}</td><td class='num'>{_mult(bucket.get('p25'))}</td>"
            f"<td class='num'>{_mult(bucket.get('median'))}</td><td class='num'>{_mult(bucket.get('p75'))}</td>"
            f"<td class='num'>{_mult(bucket.get('max'))}</td></tr>"
        )
    stats_table = (
        "<table style='margin-top:14px'><caption class='viz-caption'>Peer distribution (excludes target)</caption>"
        "<thead><tr><th>Multiple</th><th class='num'>Min</th><th class='num'>25th</th>"
        "<th class='num'>Median</th><th class='num'>75th</th><th class='num'>Max</th></tr></thead>"
        f"<tbody>{''.join(stat_rows)}</tbody></table>"
    )
    return f"{chart}<div style='margin-top:14px'>{table}</div>{stats_table}"


def _render_precedents(slide: dict[str, Any]) -> str:
    payload = slide.get("payload", {})
    table = charts.table_html(
        [
            {"key": "announced_on", "label": "Announced"},
            {"key": "target", "label": "Target"},
            {"key": "acquirer", "label": "Acquirer"},
            {"key": "ev", "label": "EV (USDm)", "numeric": True, "format": "{:,.0f}"},
            {"key": "ev_revenue", "label": "EV/Rev", "numeric": True, "format": "{:,.1f}x"},
            {"key": "ev_ebitda", "label": "EV/EBITDA", "numeric": True, "format": "{:,.1f}x"},
            {"key": "premium_1day", "label": "1-day premium", "numeric": True, "format": "{:.0%}"},
            {"key": "consideration", "label": "Consideration"},
        ],
        payload.get("rows", []),
    )
    note = f'<p class="note">{_esc(payload.get("note"))}</p>' if payload.get("note") else ""
    return f"{table}{note}"


def _render_dcf(slide: dict[str, Any]) -> str:
    payload = slide.get("payload", {})
    currency = payload.get("currency", "USD")
    projections = payload.get("projections", [])
    assumptions = payload.get("assumptions", {})
    chart = charts.column_chart_svg(
        [str(p["year"]) for p in projections],
        [float(p["fcf"] or 0) for p in projections],
        title=f"Unlevered free cash flow ({currency}m)",
        value_format="{:,.0f}",
    )
    table = charts.table_html(
        [
            {"key": "year", "label": "Year"},
            {"key": "revenue", "label": "Revenue", "numeric": True, "format": "{:,.0f}"},
            {"key": "growth", "label": "Growth", "numeric": True, "format": "{:.1%}"},
            {"key": "ebitda", "label": "EBITDA", "numeric": True, "format": "{:,.0f}"},
            {"key": "ebitda_margin", "label": "Margin", "numeric": True, "format": "{:.1%}"},
            {"key": "ebit", "label": "EBIT", "numeric": True, "format": "{:,.0f}"},
            {"key": "taxes", "label": "Taxes", "numeric": True, "format": "{:,.0f}"},
            {"key": "capex", "label": "Capex", "numeric": True, "format": "{:,.0f}"},
            {"key": "fcf", "label": "UFCF", "numeric": True, "format": "{:,.0f}"},
            {"key": "discount_factor", "label": "DF", "numeric": True, "format": "{:.3f}"},
            {"key": "pv_fcf", "label": "PV", "numeric": True, "format": "{:,.0f}"},
        ],
        projections,
        caption=f"{currency}m",
    )
    bridge = (
        '<div class="grid kpis" style="margin-top:14px">'
        f'<div class="kpi"><div class="label">PV of forecast FCF</div><div class="value">{_money(payload.get("pv_explicit"), currency)}</div></div>'
        f'<div class="kpi"><div class="label">PV of terminal value</div><div class="value">{_money(payload.get("pv_terminal"), currency)}</div></div>'
        f'<div class="kpi"><div class="label">Equity value</div><div class="value">{_money(payload.get("equity_value"), currency)}</div></div>'
        f'<div class="kpi"><div class="label">Value per share</div><div class="value">{_symbol(currency)}{payload.get("value_per_share", 0):,.2f}</div></div>'
        "</div>"
    )
    assumption_pills = "".join(
        f'<span class="pill">{_esc(label)}: {_esc(value)}</span>' for label, value in (
            ("WACC", _pct(assumptions.get("wacc"), 2)),
            ("Terminal growth", _pct(assumptions.get("terminal_growth"), 2)),
            ("Base revenue", _money(assumptions.get("base_revenue"), currency)),
            ("Revenue growth (yr 1)", _pct(assumptions.get("revenue_growth"))),
            ("EBITDA margin", _pct(assumptions.get("ebitda_margin"))),
            ("Capex % revenue", _pct(assumptions.get("capex_pct_revenue"))),
            ("Tax rate", _pct(assumptions.get("tax_rate"))),
            ("Net debt", _money(assumptions.get("net_debt"), currency)),
        )
    )
    note = f'<p class="note">{_esc(payload.get("note"))}</p>' if payload.get("note") else ""
    return f"{chart}{bridge}{note}<p class='note'>{assumption_pills}</p><div style='margin-top:12px'>{table}</div>"


def _render_sensitivity(slide: dict[str, Any]) -> str:
    payload = slide.get("payload", {})
    grid = payload.get("grid", [])
    heatmap = charts.heatmap_html(
        grid,
        row_labels=[f"{float(g) * 100:.2f}%" for g in payload.get("terminal_axis", [])],
        column_labels=[f"{float(w) * 100:.2f}%" for w in payload.get("wacc_axis", [])],
        row_title="Terminal growth",
        column_title="WACC",
        reference=payload.get("reference_price"),
    )
    note = (
        f'<p class="note">Value per share ({payload.get("currency", "USD")}). The outlined cells sit within 2% of the '
        f'current share price of {_symbol(payload.get("currency"))}{payload.get("reference_price", 0):,.2f}.</p>'
    )
    return heatmap + note


def _render_buyers(slide: dict[str, Any]) -> str:
    payload = slide.get("payload", {})
    table = charts.table_html(
        [
            {"key": "name", "label": "Counterparty"},
            {"key": "type", "label": "Type"},
            {"key": "enterprise_value", "label": "EV (USDm)", "numeric": True, "format": "{:,.0f}"},
            {"key": "relative_size", "label": "EV vs target", "numeric": True, "format": "{:,.2f}x"},
            {"key": "rationale", "label": "Rationale"},
        ],
        payload.get("candidates", []),
    )
    return table


def _render_process(slide: dict[str, Any]) -> str:
    return _bullets_html(slide.get("payload", {}).get("bullets", []))


def _render_evidence(slide: dict[str, Any]) -> str:
    items = slide.get("payload", {}).get("items", [])
    if not items:
        return '<p class="note">No evidence pinned yet. Pin passages from the research module to build this appendix.</p>'
    blocks = []
    for item in items:
        source = " · ".join(
            _esc(part) for part in (item.get("ticker"), item.get("title"), item.get("doc_type"), item.get("published_at")) if part
        )
        note = f'<br>Note: {_esc(item["note"])}' if item.get("note") else ""
        blocks.append(
            f'<blockquote class="quote">“{_esc(item.get("quote"))}”'
            f'<span class="src">{source} [doc {_esc(item.get("document_id"))}]{note}</span></blockquote>'
        )
    return "".join(blocks)


def _render_disclaimer(slide: dict[str, Any]) -> str:
    return f'<p class="disclaimer">{_esc(slide.get("payload", {}).get("body"))}</p>'


RENDERERS = {
    "cover": _render_cover,
    "disclaimer": _render_disclaimer,
    "executive_summary": _render_executive_summary,
    "company_overview": _render_company_overview,
    "market_overview": _render_market_overview,
    "financial_performance": _render_financials,
    "valuation_summary": _render_valuation_summary,
    "trading_comps": _render_trading_comps,
    "precedent_transactions": _render_precedents,
    "dcf": _render_dcf,
    "dcf_sensitivity": _render_sensitivity,
    "buyers": _render_buyers,
    "process": _render_process,
    "evidence_appendix": _render_evidence,
}


def render_slide_html(slide: dict[str, Any], index: int, total: int) -> str:
    """Render one slide payload; unknown kinds degrade to bullets or raw text."""
    renderer = RENDERERS.get(slide.get("kind", ""))
    if renderer is None:
        payload = slide.get("payload", {})
        body = _bullets_html(payload.get("bullets", [])) if payload.get("bullets") else f'<p>{_esc(payload.get("body", ""))}</p>'
    else:
        body = renderer(slide)
    return _slide_shell(index, total, slide, body, cover=slide.get("kind") == "cover")


def render_deck_body(book: dict[str, Any]) -> str:
    """Just the slide markup, for embedding in the application shell.

    The web UI injects this instead of re-implementing fourteen slide layouts in
    JavaScript, which keeps the on-screen deck and the exported deck identical by
    construction.
    """
    slides = book.get("slides", [])
    total = len(slides)
    return "\n".join(render_slide_html(slide, index + 1, total) for index, slide in enumerate(slides))


def render_deck_html(book: dict[str, Any]) -> str:
    """Render a complete, self-contained HTML deck for a pitch book."""
    rendered = render_deck_body(book)
    light = charts.css_tokens("light", selector=":root")
    dark = charts.css_tokens("dark", selector=":root")
    title = _esc(book.get("title", "Pitch book"))
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title}</title>
<style>
{light}
@media (prefers-color-scheme: dark) {{
  :root:where(:not([data-theme="light"])) {{
{dark.split("{", 1)[1].rsplit("}", 1)[0]}
  }}
}}
:root[data-theme="dark"] {{
{dark.split("{", 1)[1].rsplit("}", 1)[0]}
}}
{STYLE}
</style>
</head>
<body>
<main class="deck viz">
{rendered}
</main>
</body>
</html>
"""


def write_html(book: dict[str, Any], path: Path) -> Path:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(render_deck_html(book), encoding="utf-8")
    return path
