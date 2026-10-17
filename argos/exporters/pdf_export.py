"""PDF export via reportlab.

A print deliverable: one page per slide, landscape, with the football field
drawn as a vector flowable and every table rendered as a real table. Requires
``reportlab``; :func:`argos.exporters.available_formats` reports availability.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any, Sequence

from reportlab.graphics.shapes import Drawing, Line, Rect, String
from reportlab.lib import colors
from reportlab.lib.enums import TA_LEFT
from reportlab.lib.pagesizes import landscape, A4
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.lib.units import mm
from reportlab.platypus import (
    KeepTogether, PageBreak, Paragraph, SimpleDocTemplate, Spacer, Table, TableStyle,
)

from .. import charts as chart_tokens

LIGHT = chart_tokens.PALETTE["light"]
SERIES_1 = colors.HexColor(LIGHT["series_1"])
INK = colors.HexColor(LIGHT["text"])
INK_SECONDARY = colors.HexColor(LIGHT["text_secondary"])
MUTED = colors.HexColor(LIGHT["muted"])
GRID = colors.HexColor(LIGHT["grid"])
AXIS = colors.HexColor(LIGHT["axis"])
SEQ = [colors.HexColor(step) for step in LIGHT["seq"]]

PAGE = landscape(A4)
CONTENT_WIDTH = PAGE[0] - 30 * mm
CURRENCY_SYMBOLS = {"USD": "$", "EUR": "€", "GBP": "£"}


def _styles() -> dict[str, ParagraphStyle]:
    base = getSampleStyleSheet()
    return {
        "title": ParagraphStyle("ArgosTitle", parent=base["Title"], fontSize=26, leading=30,
                                alignment=TA_LEFT, textColor=INK, spaceAfter=4),
        "heading": ParagraphStyle("ArgosHeading", parent=base["Heading1"], fontSize=17, leading=21,
                                  textColor=INK, spaceAfter=2),
        "sub": ParagraphStyle("ArgosSub", parent=base["Normal"], fontSize=9.5, leading=13,
                              textColor=INK_SECONDARY, spaceAfter=10),
        "body": ParagraphStyle("ArgosBody", parent=base["Normal"], fontSize=10, leading=14, textColor=INK),
        "bullet": ParagraphStyle("ArgosBullet", parent=base["Normal"], fontSize=10, leading=14,
                                 textColor=INK, leftIndent=10, bulletIndent=0, spaceAfter=5),
        "cite": ParagraphStyle("ArgosCite", parent=base["Normal"], fontSize=7.5, leading=10,
                               textColor=MUTED, leftIndent=10, spaceAfter=7),
        "note": ParagraphStyle("ArgosNote", parent=base["Normal"], fontSize=8.5, leading=12,
                               textColor=INK_SECONDARY, spaceBefore=6),
        "cell": ParagraphStyle("ArgosCell", parent=base["Normal"], fontSize=7.5, leading=9.5, textColor=INK),
    }


def _symbol(currency: str | None) -> str:
    return CURRENCY_SYMBOLS.get((currency or "USD").upper(), "")


def _fmt(value: Any, pattern: str | None) -> str:
    if value is None:
        return "n/a"
    if not pattern:
        return str(value)
    try:
        return pattern.format(float(value))
    except (TypeError, ValueError):
        return str(value)


def _table_flowable(columns: Sequence[dict[str, Any]], rows: Sequence[dict[str, Any]], *,
                    highlight_key: str | None = None, col_widths: Sequence[float] | None = None) -> Table:
    styles = _styles()
    header = [Paragraph(f"<b>{c['label']}</b>", styles["cell"]) for c in columns]
    body = [header]
    highlight_rows: list[int] = []
    for index, row in enumerate(rows, start=1):
        if highlight_key and row.get(highlight_key):
            highlight_rows.append(index)
        body.append([
            Paragraph(_fmt(row.get(c["key"]), c.get("format")) if c.get("format") else str(row.get(c["key"], "") or ""),
                      styles["cell"])
            for c in columns
        ])
    table = Table(body, colWidths=col_widths or [CONTENT_WIDTH / len(columns)] * len(columns), repeatRows=1)
    style = [
        ("LINEBELOW", (0, 0), (-1, 0), 0.6, AXIS),
        ("LINEBELOW", (0, 1), (-1, -2), 0.25, GRID),
        ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
        ("TOPPADDING", (0, 0), (-1, -1), 3),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 3),
    ]
    for index, column in enumerate(columns):
        if column.get("numeric"):
            style.append(("ALIGN", (index, 0), (index, -1), "RIGHT"))
    for row_index in highlight_rows:
        style.append(("BACKGROUND", (0, row_index), (-1, row_index), colors.HexColor("#eaf1fc")))
    table.setStyle(TableStyle(style))
    return table


def _football_field_drawing(ranges: Sequence[dict[str, Any]], reference_price: float | None,
                            currency: str, width: float = CONTENT_WIDTH, row_height: float = 20) -> Drawing:
    height = row_height * len(ranges) + 34
    drawing = Drawing(width, height)
    label_width = 150
    plot_left = label_width
    plot_width = width - label_width - 40
    lows = [float(r["low"]) for r in ranges] + ([float(reference_price)] if reference_price else [])
    highs = [float(r["high"]) for r in ranges] + ([float(reference_price)] if reference_price else [])
    axis_min, axis_max = min(lows) * 0.92, max(highs) * 1.06
    symbol = _symbol(currency)

    def x_of(value: float) -> float:
        return plot_left + (value - axis_min) / (axis_max - axis_min) * plot_width

    for step in range(5):
        value = axis_min + (axis_max - axis_min) * step / 4
        x = x_of(value)
        drawing.add(Line(x, 22, x, height - 6, strokeColor=GRID, strokeWidth=0.4))
        drawing.add(String(x, 10, f"{symbol}{value:,.0f}", fontSize=6.5, fillColor=MUTED, textAnchor="middle"))
    for index, row in enumerate(reversed(list(ranges))):
        y = 26 + index * row_height
        x1, x2 = x_of(float(row["low"])), x_of(float(row["high"]))
        drawing.add(Rect(x1, y, max(1.5, x2 - x1 - 1.5), row_height - 8, fillColor=SERIES_1,
                         strokeColor=None, fillOpacity=0.88))
        drawing.add(String(label_width - 6, y + 3, str(row["method"])[:44], fontSize=7.5,
                           fillColor=INK, textAnchor="end"))
        drawing.add(String(x1 - 4, y + 3, f"{symbol}{float(row['low']):,.0f}", fontSize=6.5,
                           fillColor=INK_SECONDARY, textAnchor="end"))
        drawing.add(String(x2 + 3, y + 3, f"{symbol}{float(row['high']):,.0f}", fontSize=6.5,
                           fillColor=INK_SECONDARY))
    if reference_price:
        x = x_of(float(reference_price))
        drawing.add(Line(x, 22, x, height - 2, strokeColor=INK, strokeWidth=1.2))
        drawing.add(String(x, height - 1, f"Current {symbol}{float(reference_price):,.2f}", fontSize=7,
                           fillColor=INK, textAnchor="middle"))
    return drawing


def _column_drawing(labels: Sequence[str], values: Sequence[float], *, title: str = "",
                    width: float = CONTENT_WIDTH / 2 - 6, height: float = 120,
                    value_format: str = "{:,.0f}") -> Drawing:
    drawing = Drawing(width, height)
    if title:
        drawing.add(String(0, height - 8, title, fontSize=8, fillColor=INK_SECONDARY))
    plot_bottom, plot_top = 20, height - 22
    plot_height = plot_top - plot_bottom
    top_value = max([float(v or 0) for v in values] + [1]) * 1.15
    slot = (width - 10) / max(1, len(values))
    bar_w = max(4.0, slot - 6)
    drawing.add(Line(0, plot_bottom, width, plot_bottom, strokeColor=AXIS, strokeWidth=0.5))
    for index, value in enumerate(values):
        bar_h = max(0.8, float(value or 0) / top_value * plot_height)
        x = 5 + index * slot + (slot - bar_w) / 2
        drawing.add(Rect(x, plot_bottom, bar_w, bar_h, fillColor=SERIES_1, strokeColor=None, fillOpacity=0.88))
        drawing.add(String(x + bar_w / 2, plot_bottom - 9, str(labels[index]), fontSize=6.5,
                           fillColor=MUTED, textAnchor="middle"))
        if index in (0, len(values) - 1):
            drawing.add(String(x + bar_w / 2, plot_bottom + bar_h + 3, value_format.format(float(value or 0)),
                               fontSize=6.5, fillColor=INK_SECONDARY, textAnchor="middle"))
    return drawing


def _heatmap_table(payload: dict[str, Any]) -> Table:
    styles = _styles()
    grid = payload.get("grid", [])
    wacc_axis = payload.get("wacc_axis", [])
    terminal_axis = payload.get("terminal_axis", [])
    flat = [float(v) for row in grid for v in row if v is not None]
    low, high = (min(flat), max(flat)) if flat else (0.0, 1.0)
    span = (high - low) or 1.0
    header = [Paragraph("<b>Terminal growth \\ WACC</b>", styles["cell"])] + [
        Paragraph(f"<b>{float(w) * 100:.2f}%</b>", styles["cell"]) for w in wacc_axis
    ]
    body = [header]
    style = [
        ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
        ("ALIGN", (1, 0), (-1, -1), "CENTER"),
        ("LINEBELOW", (0, 0), (-1, 0), 0.6, AXIS),
        ("GRID", (1, 1), (-1, -1), 1.2, colors.white),
        ("TOPPADDING", (0, 0), (-1, -1), 4),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 4),
    ]
    for row_index, (growth, row) in enumerate(zip(terminal_axis, grid), start=1):
        cells = [Paragraph(f"<b>{float(growth) * 100:.2f}%</b>", styles["cell"])]
        for col_index, value in enumerate(row, start=1):
            cells.append(Paragraph("n/a" if value is None else f"{float(value):,.2f}", styles["cell"]))
            if value is None:
                continue
            step = min(6, max(0, int((float(value) - low) / span * 6)))
            style.append(("BACKGROUND", (col_index, row_index), (col_index, row_index), SEQ[step]))
            if step >= 3:
                style.append(("TEXTCOLOR", (col_index, row_index), (col_index, row_index), colors.white))
        body.append(cells)
    table = Table(body, colWidths=[CONTENT_WIDTH * 0.2] + [CONTENT_WIDTH * 0.8 / max(1, len(wacc_axis))] * len(wacc_axis))
    table.setStyle(TableStyle(style))
    return table


def _bullet_flowables(bullets: Sequence[Any], styles: dict[str, ParagraphStyle]) -> list[Any]:
    flowables: list[Any] = []
    for bullet in bullets:
        text = bullet if isinstance(bullet, str) else bullet.get("text", "")
        flowables.append(Paragraph(text, styles["bullet"], bulletText="•"))
        source = None if isinstance(bullet, str) else bullet.get("source")
        if source:
            flowables.append(Paragraph(
                f"Source: {source.get('title', '')} · {source.get('doc_type', '')} · "
                f"{source.get('published_at', '')} [doc {source.get('document_id')}]",
                styles["cite"],
            ))
    return flowables


def _slide_flowables(slide: dict[str, Any], styles: dict[str, ParagraphStyle]) -> list[Any]:
    kind = slide.get("kind", "")
    payload = slide.get("payload", {})
    currency = payload.get("currency", "USD")
    flow: list[Any] = []

    if kind == "cover":
        flow.append(Spacer(1, 48 * mm))
        flow.append(Paragraph("CONFIDENTIAL — DISCUSSION MATERIALS", styles["sub"]))
        flow.append(Paragraph(slide.get("title", ""), styles["title"]))
        if slide.get("subtitle"):
            flow.append(Paragraph(slide["subtitle"], styles["sub"]))
        meta = " · ".join(str(part) for part in (
            f"Prepared for {payload.get('client_name')}" if payload.get("client_name") else None,
            payload.get("target"), payload.get("ticker"), payload.get("banker"), payload.get("date"),
        ) if part)
        flow.append(Paragraph(meta, styles["sub"]))
        return flow

    flow.append(Paragraph(slide.get("title", ""), styles["heading"]))
    if slide.get("subtitle"):
        flow.append(Paragraph(slide["subtitle"], styles["sub"]))

    if kind in ("disclaimer",):
        flow.append(Paragraph(payload.get("body", ""), styles["body"]))
    elif kind in ("executive_summary", "process"):
        reference = payload.get("reference_range") or {}
        if reference:
            symbol = _symbol(currency)
            flow.append(Paragraph(
                f"<b>Reference range {symbol}{reference.get('low', 0):,.2f} – "
                f"{symbol}{reference.get('high', 0):,.2f} per share · current "
                f"{symbol}{payload.get('share_price', 0):,.2f}</b>", styles["body"]))
            flow.append(Spacer(1, 6))
        flow.extend(_bullet_flowables(payload.get("bullets", []), styles))
    elif kind == "company_overview":
        flow.append(Paragraph(payload.get("description", ""), styles["body"]))
        flow.append(Spacer(1, 8))
        flow.append(_table_flowable(
            [{"key": "label", "label": "Metric"}, {"key": "value", "label": "Value", "numeric": True}],
            payload.get("kpis", []),
            col_widths=[CONTENT_WIDTH * 0.35, CONTENT_WIDTH * 0.25],
        ))
        if payload.get("extracted_kpis"):
            flow.append(Paragraph(
                "Metrics extracted from the corpus: " + ", ".join(
                    f"{k['label']} {k['value']} ({k['observations']} obs.)" for k in payload["extracted_kpis"]
                ), styles["note"]))
    elif kind == "market_overview":
        flow.append(Paragraph(payload.get("narrative", ""), styles["body"]))
        flow.append(Spacer(1, 8))
        timeline = payload.get("sentiment_timeline") or []
        if timeline:
            flow.append(_column_drawing(
                [row["month"][-5:] for row in timeline],
                [float(row["sentiment"] or 0) + 1 for row in timeline],
                title="Mean document tone by month (rebased +1)", width=CONTENT_WIDTH, height=110,
                value_format="{:,.2f}",
            ))
        flow.append(_table_flowable(
            [
                {"key": "theme", "label": "Emerging theme"},
                {"key": "mentions", "label": "Recent", "numeric": True, "format": "{:,.0f}"},
                {"key": "prior_mentions", "label": "Prior", "numeric": True, "format": "{:,.0f}"},
                {"key": "lift", "label": "Lift", "numeric": True, "format": "{:,.2f}x"},
            ],
            (payload.get("themes") or [])[:8],
        ))
    elif kind == "financial_performance":
        rows = payload.get("rows", [])
        flow.append(_column_drawing(
            [f"FY{r['fiscal_year']}" for r in rows], [r["revenue"] for r in rows],
            title=f"Revenue ({currency}m)", width=CONTENT_WIDTH, height=120,
        ))
        flow.append(Spacer(1, 6))
        flow.append(_table_flowable(
            [
                {"key": "fiscal_year", "label": "FY", "format": "{:,.0f}"},
                {"key": "revenue", "label": "Revenue", "numeric": True, "format": "{:,.0f}"},
                {"key": "ebitda", "label": "EBITDA", "numeric": True, "format": "{:,.0f}"},
                {"key": "ebitda_margin", "label": "Margin", "numeric": True, "format": "{:.1%}"},
                {"key": "ebit", "label": "EBIT", "numeric": True, "format": "{:,.0f}"},
                {"key": "net_income", "label": "Net income", "numeric": True, "format": "{:,.0f}"},
                {"key": "eps", "label": "EPS", "numeric": True, "format": "{:,.2f}"},
                {"key": "capex", "label": "Capex", "numeric": True, "format": "{:,.0f}"},
            ],
            rows,
        ))
        if payload.get("note"):
            flow.append(Paragraph(payload["note"], styles["note"]))
    elif kind == "valuation_summary":
        flow.append(_football_field_drawing(
            payload.get("ranges", []), payload.get("reference_price"), currency,
        ))
        flow.append(Spacer(1, 8))
        flow.append(_table_flowable(
            [
                {"key": "method", "label": "Methodology"},
                {"key": "low", "label": "Low", "numeric": True, "format": "{:,.2f}"},
                {"key": "high", "label": "High", "numeric": True, "format": "{:,.2f}"},
                {"key": "mid", "label": "Midpoint", "numeric": True, "format": "{:,.2f}"},
                {"key": "basis", "label": "Basis"},
            ],
            payload.get("ranges", []),
            col_widths=[CONTENT_WIDTH * 0.26, CONTENT_WIDTH * 0.1, CONTENT_WIDTH * 0.1,
                        CONTENT_WIDTH * 0.12, CONTENT_WIDTH * 0.42],
        ))
    elif kind == "trading_comps":
        target = dict(payload.get("target") or {})
        rows = ([target] if target else []) + [dict(r) for r in payload.get("rows", [])]
        flow.append(_table_flowable(
            [
                {"key": "ticker", "label": "Ticker"},
                {"key": "name", "label": "Company"},
                {"key": "share_price", "label": "Price", "numeric": True, "format": "{:,.2f}"},
                {"key": "market_cap", "label": "Mkt cap", "numeric": True, "format": "{:,.0f}"},
                {"key": "enterprise_value", "label": "EV", "numeric": True, "format": "{:,.0f}"},
                {"key": "revenue", "label": "Revenue", "numeric": True, "format": "{:,.0f}"},
                {"key": "ebitda_margin", "label": "Margin", "numeric": True, "format": "{:.1%}"},
                {"key": "ev_revenue", "label": "EV/Rev", "numeric": True, "format": "{:,.1f}x"},
                {"key": "ev_ebitda", "label": "EV/EBITDA", "numeric": True, "format": "{:,.1f}x"},
                {"key": "pe", "label": "P/E", "numeric": True, "format": "{:,.1f}x"},
            ],
            rows, highlight_key="is_target",
        ))
        stats = payload.get("stats", {})
        stat_rows = [
            {"multiple": label, **{key: stats.get(metric, {}).get(key) for key in ("min", "p25", "median", "p75", "max")}}
            for metric, label in (("ev_revenue", "EV / Revenue"), ("ev_ebitda", "EV / EBITDA"), ("pe", "P / E"))
        ]
        flow.append(Spacer(1, 8))
        flow.append(_table_flowable(
            [
                {"key": "multiple", "label": "Peer distribution"},
                {"key": "min", "label": "Min", "numeric": True, "format": "{:,.1f}x"},
                {"key": "p25", "label": "25th", "numeric": True, "format": "{:,.1f}x"},
                {"key": "median", "label": "Median", "numeric": True, "format": "{:,.1f}x"},
                {"key": "p75", "label": "75th", "numeric": True, "format": "{:,.1f}x"},
                {"key": "max", "label": "Max", "numeric": True, "format": "{:,.1f}x"},
            ],
            stat_rows,
        ))
    elif kind == "precedent_transactions":
        flow.append(_table_flowable(
            [
                {"key": "announced_on", "label": "Announced"},
                {"key": "target", "label": "Target"},
                {"key": "acquirer", "label": "Acquirer"},
                {"key": "ev", "label": "EV", "numeric": True, "format": "{:,.0f}"},
                {"key": "ev_revenue", "label": "EV/Rev", "numeric": True, "format": "{:,.1f}x"},
                {"key": "ev_ebitda", "label": "EV/EBITDA", "numeric": True, "format": "{:,.1f}x"},
                {"key": "premium_1day", "label": "Premium", "numeric": True, "format": "{:.0%}"},
                {"key": "consideration", "label": "Consideration"},
            ],
            payload.get("rows", []),
        ))
        if payload.get("note"):
            flow.append(Paragraph(payload["note"], styles["note"]))
    elif kind == "dcf":
        projections = payload.get("projections", [])
        flow.append(_column_drawing(
            [str(p["year"]) for p in projections], [p["fcf"] for p in projections],
            title=f"Unlevered free cash flow ({currency}m)", width=CONTENT_WIDTH, height=110,
        ))
        flow.append(Spacer(1, 6))
        flow.append(_table_flowable(
            [
                {"key": "year", "label": "Year", "format": "{:,.0f}"},
                {"key": "revenue", "label": "Revenue", "numeric": True, "format": "{:,.0f}"},
                {"key": "growth", "label": "Growth", "numeric": True, "format": "{:.1%}"},
                {"key": "ebitda", "label": "EBITDA", "numeric": True, "format": "{:,.0f}"},
                {"key": "ebit", "label": "EBIT", "numeric": True, "format": "{:,.0f}"},
                {"key": "taxes", "label": "Taxes", "numeric": True, "format": "{:,.0f}"},
                {"key": "capex", "label": "Capex", "numeric": True, "format": "{:,.0f}"},
                {"key": "fcf", "label": "UFCF", "numeric": True, "format": "{:,.0f}"},
                {"key": "pv_fcf", "label": "PV", "numeric": True, "format": "{:,.0f}"},
            ],
            projections,
        ))
        if payload.get("note"):
            flow.append(Paragraph(payload["note"], styles["note"]))
    elif kind == "dcf_sensitivity":
        flow.append(_heatmap_table(payload))
        price = payload.get("reference_price")  # None when no price was loaded
        flow.append(Paragraph(
            f"Value per share ({currency}); current share price "
            + (f"{_symbol(currency)}{float(price):,.2f}." if price is not None else "not loaded."), styles["note"]))
    elif kind == "buyers":
        flow.append(_table_flowable(
            [
                {"key": "name", "label": "Counterparty"},
                {"key": "type", "label": "Type"},
                {"key": "enterprise_value", "label": "EV", "numeric": True, "format": "{:,.0f}"},
                {"key": "relative_size", "label": "EV vs target", "numeric": True, "format": "{:,.2f}x"},
                {"key": "rationale", "label": "Rationale"},
            ],
            payload.get("candidates", []),
            col_widths=[CONTENT_WIDTH * 0.2, CONTENT_WIDTH * 0.1, CONTENT_WIDTH * 0.1,
                        CONTENT_WIDTH * 0.12, CONTENT_WIDTH * 0.48],
        ))
    elif kind == "evidence_appendix":
        items = payload.get("items", [])
        if not items:
            flow.append(Paragraph("No evidence pinned yet.", styles["body"]))
        for item in items:
            source = " · ".join(str(part) for part in (
                item.get("ticker"), item.get("title"), item.get("doc_type"), item.get("published_at")
            ) if part)
            flow.append(KeepTogether([
                Paragraph(f"“{item.get('quote', '')}”", styles["body"]),
                Paragraph(f"{source} [doc {item.get('document_id')}]", styles["cite"]),
            ]))
    else:
        flow.extend(_bullet_flowables(payload.get("bullets", []), styles))
    return flow


def write_pdf(book: dict[str, Any], path: Path) -> Path:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    styles = _styles()
    doc = SimpleDocTemplate(
        str(path), pagesize=PAGE,
        leftMargin=15 * mm, rightMargin=15 * mm, topMargin=12 * mm, bottomMargin=12 * mm,
        title=book.get("title", "Pitch book"), author=book.get("banker") or "Argos",
    )
    story: list[Any] = []
    slides = book.get("slides", [])
    for index, slide in enumerate(slides):
        story.extend(_slide_flowables(slide, styles))
        if index < len(slides) - 1:
            story.append(PageBreak())
    doc.build(story)
    return path
