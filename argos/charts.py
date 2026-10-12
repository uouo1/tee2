"""Server-side SVG charts, shared by the web UI and the HTML deck export.

Colour roles are emitted as CSS custom properties (``var(--series-1)``) rather
than literal hex, so one SVG renders correctly in light and dark mode. The token
values themselves live in :data:`PALETTE` and are the validated reference
palette: categorical slots in fixed order (never cycled), one sequential hue for
magnitude, and a diverging blue/red pair with a neutral grey midpoint for
polarity.

Rules applied throughout: one axis per chart (never two y-scales), hairline
gridlines, 2px gaps between adjacent fills, selective direct labels rather than a
number on every mark, and a legend whenever two or more series share a plot.
"""

from __future__ import annotations

import html
import math
from typing import Any, Iterable, Sequence

PALETTE: dict[str, dict[str, str]] = {
    "light": {
        "surface": "#fcfcfb", "plane": "#f9f9f7",
        "text": "#0b0b0b", "text_secondary": "#52514e", "muted": "#898781",
        "grid": "#e1e0d9", "axis": "#c3c2b7", "border": "rgba(11,11,11,0.10)",
        "series_1": "#2a78d6", "series_2": "#eb6834", "series_3": "#1baf7a",
        "series_4": "#eda100", "series_5": "#e87ba4", "series_6": "#008300",
        "diverging_pos": "#2a78d6", "diverging_neg": "#e34948", "diverging_mid": "#f0efec",
        "seq": ("#cde2fb", "#9ec5f4", "#6da7ec", "#3987e5", "#256abf", "#184f95", "#0d366b"),
        "good": "#0ca30c", "warning": "#fab219", "critical": "#d03b3b",
    },
    "dark": {
        "surface": "#1a1a19", "plane": "#0d0d0d",
        "text": "#f0efec", "text_secondary": "#c3c2b7", "muted": "#898781",
        "grid": "#2c2c2a", "axis": "#383835", "border": "rgba(255,255,255,0.10)",
        "series_1": "#3987e5", "series_2": "#d95926", "series_3": "#199e70",
        "series_4": "#c98500", "series_5": "#d55181", "series_6": "#008300",
        "diverging_pos": "#3987e5", "diverging_neg": "#e66767", "diverging_mid": "#383835",
        "seq": ("#cde2fb", "#9ec5f4", "#6da7ec", "#3987e5", "#256abf", "#184f95", "#0d366b"),
        "good": "#0ca30c", "warning": "#fab219", "critical": "#d03b3b",
    },
}

SERIES_SLOTS = ("--series-1", "--series-2", "--series-3", "--series-4", "--series-5", "--series-6")
MAX_SERIES = len(SERIES_SLOTS)
BAR_RADIUS = 4       # rounded data-end only
GAP = 2              # surface gap between adjacent fills
FONT = 'system-ui, -apple-system, "Segoe UI", sans-serif'


def css_tokens(mode: str = "light", *, selector: str = ".viz") -> str:
    """Emit the palette as CSS custom properties for one mode."""
    tokens = PALETTE[mode]
    lines = [
        f"  --surface-1: {tokens['surface']};",
        f"  --plane: {tokens['plane']};",
        f"  --text-primary: {tokens['text']};",
        f"  --text-secondary: {tokens['text_secondary']};",
        f"  --muted: {tokens['muted']};",
        f"  --grid: {tokens['grid']};",
        f"  --axis: {tokens['axis']};",
        f"  --border: {tokens['border']};",
        f"  --diverging-pos: {tokens['diverging_pos']};",
        f"  --diverging-neg: {tokens['diverging_neg']};",
        f"  --diverging-mid: {tokens['diverging_mid']};",
        f"  --good: {tokens['good']};",
        f"  --warning: {tokens['warning']};",
        f"  --critical: {tokens['critical']};",
    ]
    for index in range(MAX_SERIES):
        lines.append(f"  --series-{index + 1}: {tokens[f'series_{index + 1}']};")
    for index, step in enumerate(tokens["seq"]):
        lines.append(f"  --seq-{index + 1}: {step};")
    body = "\n".join(lines)
    return f"{selector} {{\n{body}\n}}"


def _esc(value: Any) -> str:
    return html.escape(str(value), quote=True)


def _nice_ticks(low: float, high: float, count: int = 5) -> list[float]:
    """Round axis ticks spanning [low, high].

    The magnitude is derived from the raw step rather than assumed, so a chart
    whose values span three percentage points gets four gridlines and not
    twenty-seven.
    """
    if high <= low:
        return [low]
    raw = (high - low) / max(1, count - 1)
    if raw <= 0:
        return [low, high]
    magnitude = 10 ** math.floor(math.log10(raw))
    step = magnitude
    for factor in (1, 2, 2.5, 5, 10):
        step = magnitude * factor
        if step >= raw:
            break
    start = math.floor(low / step) * step
    ticks: list[float] = []
    value = start
    # Guard against a pathological step producing an unbounded axis.
    while value <= high + step * 0.5 and len(ticks) < 24:
        ticks.append(round(value, 6))
        value += step
    return ticks or [low, high]


def _svg_open(width: int, height: int, title: str, description: str = "") -> list[str]:
    parts = [
        f'<svg class="viz-svg" viewBox="0 0 {width} {height}" width="100%" height="{height}" '
        f'role="img" aria-label="{_esc(title)}" xmlns="http://www.w3.org/2000/svg" '
        f'style="font-family:{FONT}">',
        f"<title>{_esc(title)}</title>",
    ]
    if description:
        parts.append(f"<desc>{_esc(description)}</desc>")
    return parts


# ------------------------------------------------------------ football field


def football_field_svg(
    ranges: Sequence[dict[str, Any]],
    *,
    reference_price: float | None = None,
    concluded: dict[str, float] | None = None,
    currency_symbol: str = "$",
    width: int = 760,
    row_height: int = 44,
) -> str:
    """Floating range bars per methodology against one shared price axis.

    One measure (value per share) on one axis, so every methodology is one
    series in one colour; the current share price is a reference rule, not a
    second series.
    """
    if not ranges:
        return '<p class="viz-empty">No valuation ranges available.</p>'

    label_width = 232
    pad_right = 56
    top = 34
    height = top + row_height * len(ranges) + 54
    plot_left = label_width
    plot_width = width - label_width - pad_right

    lows = [float(r["low"]) for r in ranges]
    highs = [float(r["high"]) for r in ranges]
    if reference_price:
        lows.append(float(reference_price))
        highs.append(float(reference_price))
    axis_min = min(lows) * 0.92
    axis_max = max(highs) * 1.06
    ticks = _nice_ticks(axis_min, axis_max, 6)
    axis_min, axis_max = min(axis_min, ticks[0]), max(axis_max, ticks[-1])

    def x_of(value: float) -> float:
        return plot_left + (value - axis_min) / (axis_max - axis_min) * plot_width

    parts = _svg_open(width, height, "Valuation summary — implied value per share",
                      "Range of implied value per share by valuation methodology.")

    if concluded and concluded.get("low") and concluded.get("high"):
        x1, x2 = x_of(float(concluded["low"])), x_of(float(concluded["high"]))
        parts.append(
            f'<rect x="{x1:.1f}" y="{top - 8}" width="{max(1.0, x2 - x1):.1f}" '
            f'height="{row_height * len(ranges) + 10}" fill="var(--series-1)" opacity="0.07" />'
        )

    for tick in ticks:
        x = x_of(tick)
        parts.append(
            f'<line x1="{x:.1f}" y1="{top - 10}" x2="{x:.1f}" y2="{top + row_height * len(ranges)}" '
            f'stroke="var(--grid)" stroke-width="1" />'
        )
        parts.append(
            f'<text x="{x:.1f}" y="{top + row_height * len(ranges) + 18}" fill="var(--muted)" '
            f'font-size="11" text-anchor="middle" style="font-variant-numeric:tabular-nums">'
            f'{_esc(f"{currency_symbol}{tick:,.0f}")}</text>'
        )

    for index, row in enumerate(ranges):
        y = top + index * row_height
        bar_y = y + (row_height - 18) / 2
        x1, x2 = x_of(float(row["low"])), x_of(float(row["high"]))
        bar_width = max(3.0, x2 - x1 - GAP)
        parts.append(
            f'<text x="{label_width - 14}" y="{bar_y + 13}" text-anchor="end" font-size="12.5" '
            f'fill="var(--text-primary)">{_esc(row["method"])}</text>'
        )
        parts.append(
            f'<rect x="{x1:.1f}" y="{bar_y:.1f}" width="{bar_width:.1f}" height="18" rx="{BAR_RADIUS}" '
            f'fill="var(--series-1)" opacity="0.88"><title>{_esc(row["method"])}: '
            f'{currency_symbol}{float(row["low"]):,.2f} – {currency_symbol}{float(row["high"]):,.2f}'
            f'{" · " + _esc(row.get("basis", "")) if row.get("basis") else ""}</title></rect>'
        )
        # Direct labels at both ends: the relief rule for low-contrast fills, and
        # the reason this chart needs no tooltip to be readable.
        low_label = f"{currency_symbol}{float(row['low']):,.0f}"
        high_label = f"{currency_symbol}{float(row['high']):,.0f}"
        parts.append(
            f'<text x="{x1 - 8:.1f}" y="{bar_y + 13}" text-anchor="end" font-size="11" '
            f'fill="var(--text-secondary)" style="font-variant-numeric:tabular-nums">'
            f'{_esc(low_label)}</text>'
        )
        parts.append(
            f'<text x="{x1 + bar_width + 8:.1f}" y="{bar_y + 13}" font-size="11" '
            f'fill="var(--text-secondary)" style="font-variant-numeric:tabular-nums">'
            f'{_esc(high_label)}</text>'
        )

    if reference_price:
        x = x_of(float(reference_price))
        parts.append(
            f'<line x1="{x:.1f}" y1="{top - 16}" x2="{x:.1f}" y2="{top + row_height * len(ranges) + 2}" '
            f'stroke="var(--text-primary)" stroke-width="2" />'
        )
        parts.append(
            f'<text x="{x:.1f}" y="{top - 20}" font-size="11.5" text-anchor="middle" fill="var(--text-primary)">'
            f'Current {_esc(f"{currency_symbol}{float(reference_price):,.2f}")}</text>'
        )
    parts.append("</svg>")
    return "\n".join(parts)


# -------------------------------------------------------------- bar / column


def column_chart_svg(
    labels: Sequence[str],
    values: Sequence[float],
    *,
    title: str = "",
    value_format: str = "{:,.0f}",
    highlight_index: int | None = None,
    estimate_from: int | None = None,
    width: int = 620,
    height: int = 240,
    label_every: int = 1,
) -> str:
    """Single-series columns: one measure, one colour, selective labels.

    ``highlight_index`` applies emphasis (one bar in the series colour, the rest
    recessive) — the honest alternative to colouring every bar differently.
    ``estimate_from`` marks forecast periods with a lighter fill and a legend.
    """
    if not values:
        return '<p class="viz-empty">No data.</p>'
    pad_left, pad_right, pad_top = 54, 16, 26 if title else 14
    pad_bottom = 42
    plot_w = width - pad_left - pad_right
    plot_h = height - pad_top - pad_bottom
    top_value = max(values) * 1.12 or 1
    ticks = _nice_ticks(0, top_value, 5)
    top_value = max(top_value, ticks[-1])
    slot = plot_w / len(values)
    bar_w = max(6.0, slot - GAP * 3)

    parts = _svg_open(width, height, title or "Column chart")
    if title:
        parts.append(f'<text x="0" y="14" font-size="12.5" fill="var(--text-secondary)">{_esc(title)}</text>')
    for tick in ticks:
        y = pad_top + plot_h - (tick / top_value) * plot_h
        parts.append(f'<line x1="{pad_left}" y1="{y:.1f}" x2="{width - pad_right}" y2="{y:.1f}" stroke="var(--grid)" stroke-width="1" />')
        parts.append(
            f'<text x="{pad_left - 8}" y="{y + 4:.1f}" font-size="11" text-anchor="end" fill="var(--muted)" '
            f'style="font-variant-numeric:tabular-nums">{_esc(value_format.format(tick))}</text>'
        )
    parts.append(
        f'<line x1="{pad_left}" y1="{pad_top + plot_h:.1f}" x2="{width - pad_right}" y2="{pad_top + plot_h:.1f}" '
        f'stroke="var(--axis)" stroke-width="1" />'
    )
    for index, value in enumerate(values):
        x = pad_left + index * slot + (slot - bar_w) / 2
        bar_h = max(1.0, (max(0.0, float(value)) / top_value) * plot_h)
        y = pad_top + plot_h - bar_h
        is_estimate = estimate_from is not None and index >= estimate_from
        opacity = "0.42" if (highlight_index is not None and index != highlight_index) else ("0.55" if is_estimate else "0.9")
        parts.append(
            f'<rect x="{x:.1f}" y="{y:.1f}" width="{bar_w:.1f}" height="{bar_h:.1f}" rx="{BAR_RADIUS}" '
            f'fill="var(--series-1)" opacity="{opacity}"><title>{_esc(labels[index])}: '
            f'{_esc(value_format.format(value))}{" (estimate)" if is_estimate else ""}</title></rect>'
        )
        show_label = (
            index == len(values) - 1
            or index == highlight_index
            or (highlight_index is None and label_every and index % label_every == 0)
        )
        if show_label:
            parts.append(
                f'<text x="{x + bar_w / 2:.1f}" y="{y - 6:.1f}" font-size="11" text-anchor="middle" '
                f'fill="var(--text-secondary)" style="font-variant-numeric:tabular-nums">'
                f'{_esc(value_format.format(value))}</text>'
            )
        parts.append(
            f'<text x="{x + bar_w / 2:.1f}" y="{pad_top + plot_h + 16:.1f}" font-size="11" text-anchor="middle" '
            f'fill="var(--muted)">{_esc(labels[index])}</text>'
        )
    if estimate_from is not None and estimate_from < len(values):
        parts.append(
            f'<g><rect x="{pad_left}" y="{height - 14}" width="10" height="10" rx="2" fill="var(--series-1)" opacity="0.9" />'
            f'<text x="{pad_left + 15}" y="{height - 5}" font-size="10.5" fill="var(--muted)">Actual</text>'
            f'<rect x="{pad_left + 68}" y="{height - 14}" width="10" height="10" rx="2" fill="var(--series-1)" opacity="0.55" />'
            f'<text x="{pad_left + 83}" y="{height - 5}" font-size="10.5" fill="var(--muted)">Estimate</text></g>'
        )
    parts.append("</svg>")
    return "\n".join(parts)


def line_chart_svg(
    labels: Sequence[str],
    values: Sequence[float | None],
    *,
    title: str = "",
    value_format: str = "{:.1f}%",
    width: int = 620,
    height: int = 200,
) -> str:
    """One measure over time: 2px line, >=8px endpoint marker, endpoint label."""
    points = [(i, v) for i, v in enumerate(values) if v is not None]
    if len(points) < 2:
        return '<p class="viz-empty">Not enough data for a trend.</p>'
    pad_left, pad_right, pad_top, pad_bottom = 54, 46, 26 if title else 12, 34
    plot_w = width - pad_left - pad_right
    plot_h = height - pad_top - pad_bottom
    numeric = [v for _, v in points]
    low, high = min(numeric), max(numeric)
    span = (high - low) or abs(high) or 1
    low, high = low - span * 0.18, high + span * 0.18
    ticks = _nice_ticks(low, high, 4)

    def x_of(index: int) -> float:
        return pad_left + (index / max(1, len(values) - 1)) * plot_w

    def y_of(value: float) -> float:
        return pad_top + plot_h - (value - low) / (high - low) * plot_h

    parts = _svg_open(width, height, title or "Trend")
    if title:
        parts.append(f'<text x="0" y="14" font-size="12.5" fill="var(--text-secondary)">{_esc(title)}</text>')
    for tick in ticks:
        y = y_of(tick)
        if not (pad_top - 2 <= y <= pad_top + plot_h + 2):
            continue
        parts.append(f'<line x1="{pad_left}" y1="{y:.1f}" x2="{width - pad_right}" y2="{y:.1f}" stroke="var(--grid)" stroke-width="1" />')
        parts.append(
            f'<text x="{pad_left - 8}" y="{y + 4:.1f}" font-size="11" text-anchor="end" fill="var(--muted)" '
            f'style="font-variant-numeric:tabular-nums">{_esc(value_format.format(tick))}</text>'
        )
    path = " ".join(
        f"{'M' if i == 0 else 'L'}{x_of(index):.1f},{y_of(value):.1f}"
        for i, (index, value) in enumerate(points)
    )
    parts.append(f'<path d="{path}" fill="none" stroke="var(--series-1)" stroke-width="2" stroke-linejoin="round" />')
    for index, value in points:
        parts.append(
            f'<circle cx="{x_of(index):.1f}" cy="{y_of(value):.1f}" r="4" fill="var(--series-1)" '
            f'stroke="var(--surface-1)" stroke-width="2"><title>{_esc(labels[index])}: '
            f'{_esc(value_format.format(value))}</title></circle>'
        )
    last_index, last_value = points[-1]
    parts.append(
        f'<text x="{x_of(last_index) + 9:.1f}" y="{y_of(last_value) + 4:.1f}" font-size="11.5" '
        f'fill="var(--text-primary)" style="font-variant-numeric:tabular-nums">{_esc(value_format.format(last_value))}</text>'
    )
    step = max(1, len(labels) // 7)
    for index in range(0, len(labels), step):
        parts.append(
            f'<text x="{x_of(index):.1f}" y="{height - 12}" font-size="10.5" text-anchor="middle" '
            f'fill="var(--muted)">{_esc(labels[index])}</text>'
        )
    parts.append("</svg>")
    return "\n".join(parts)


def diverging_bar_svg(
    labels: Sequence[str],
    values: Sequence[float],
    *,
    title: str = "",
    width: int = 620,
    height: int = 210,
    value_format: str = "{:+.2f}",
) -> str:
    """Polarity around zero: two hues that read as opposite, neutral midline."""
    if not values:
        return '<p class="viz-empty">No data.</p>'
    pad_left, pad_right, pad_top, pad_bottom = 46, 16, 26 if title else 12, 54
    plot_w = width - pad_left - pad_right
    plot_h = height - pad_top - pad_bottom
    extent = max(0.05, max(abs(float(v)) for v in values) * 1.2)
    zero_y = pad_top + plot_h / 2
    slot = plot_w / len(values)
    bar_w = max(4.0, slot - GAP * 2)

    parts = _svg_open(width, height, title or "Sentiment")
    if title:
        parts.append(f'<text x="0" y="14" font-size="12.5" fill="var(--text-secondary)">{_esc(title)}</text>')
    for level in (-extent / 2, 0, extent / 2):
        y = zero_y - (level / extent) * (plot_h / 2)
        stroke = "var(--axis)" if level == 0 else "var(--grid)"
        parts.append(f'<line x1="{pad_left}" y1="{y:.1f}" x2="{width - pad_right}" y2="{y:.1f}" stroke="{stroke}" stroke-width="1" />')
        parts.append(
            f'<text x="{pad_left - 8}" y="{y + 4:.1f}" font-size="10.5" text-anchor="end" fill="var(--muted)" '
            f'style="font-variant-numeric:tabular-nums">{_esc(f"{level:+.2f}")}</text>'
        )
    for index, raw in enumerate(values):
        value = float(raw)
        x = pad_left + index * slot + (slot - bar_w) / 2
        bar_h = max(1.0, abs(value) / extent * (plot_h / 2))
        y = zero_y - bar_h if value >= 0 else zero_y
        colour = "var(--diverging-pos)" if value >= 0 else "var(--diverging-neg)"
        parts.append(
            f'<rect x="{x:.1f}" y="{y:.1f}" width="{bar_w:.1f}" height="{bar_h:.1f}" rx="2" fill="{colour}" '
            f'opacity="0.88"><title>{_esc(labels[index])}: {_esc(value_format.format(value))}</title></rect>'
        )
    step = max(1, len(labels) // 8)
    for index in range(0, len(labels), step):
        parts.append(
            f'<text x="{pad_left + index * slot + slot / 2:.1f}" y="{pad_top + plot_h + 16:.1f}" font-size="10.5" '
            f'text-anchor="middle" fill="var(--muted)">{_esc(labels[index])}</text>'
        )
    legend_y = height - 8
    parts.append(
        f'<g><rect x="{pad_left}" y="{legend_y - 9}" width="9" height="9" rx="2" fill="var(--diverging-pos)" />'
        f'<text x="{pad_left + 14}" y="{legend_y}" font-size="10" fill="var(--muted)">Positive tone</text>'
        f'<rect x="{pad_left + 96}" y="{legend_y - 9}" width="9" height="9" rx="2" fill="var(--diverging-neg)" />'
        f'<text x="{pad_left + 110}" y="{legend_y}" font-size="10" fill="var(--muted)">Negative tone</text></g>'
    )
    parts.append("</svg>")
    return "\n".join(parts)


def stacked_bar_svg(
    labels: Sequence[str],
    series: Sequence[dict[str, Any]],
    *,
    title: str = "",
    width: int = 620,
    height: int = 230,
) -> str:
    """Document volume by type: categorical slots in fixed order, legend always."""
    if not series or not labels:
        return '<p class="viz-empty">No data.</p>'
    series = list(series)[:MAX_SERIES]
    pad_left, pad_right, pad_top, pad_bottom = 42, 14, 26 if title else 12, 52
    plot_w = width - pad_left - pad_right
    plot_h = height - pad_top - pad_bottom
    totals = [sum(float(s["values"][i] or 0) for s in series) for i in range(len(labels))]
    top_value = max(totals) * 1.1 or 1
    ticks = _nice_ticks(0, top_value, 4)
    top_value = max(top_value, ticks[-1])
    slot = plot_w / len(labels)
    bar_w = max(5.0, slot - GAP * 3)

    parts = _svg_open(width, height, title or "Volume by type")
    if title:
        parts.append(f'<text x="0" y="14" font-size="12.5" fill="var(--text-secondary)">{_esc(title)}</text>')
    for tick in ticks:
        y = pad_top + plot_h - (tick / top_value) * plot_h
        parts.append(f'<line x1="{pad_left}" y1="{y:.1f}" x2="{width - pad_right}" y2="{y:.1f}" stroke="var(--grid)" stroke-width="1" />')
        parts.append(
            f'<text x="{pad_left - 8}" y="{y + 4:.1f}" font-size="10.5" text-anchor="end" fill="var(--muted)" '
            f'style="font-variant-numeric:tabular-nums">{_esc(f"{tick:,.0f}")}</text>'
        )
    for index, label in enumerate(labels):
        x = pad_left + index * slot + (slot - bar_w) / 2
        cursor = pad_top + plot_h
        for slot_index, entry in enumerate(series):
            value = float(entry["values"][index] or 0)
            if value <= 0:
                continue
            segment_h = (value / top_value) * plot_h
            cursor -= segment_h
            parts.append(
                f'<rect x="{x:.1f}" y="{cursor:.1f}" width="{bar_w:.1f}" height="{max(1.0, segment_h - GAP):.1f}" '
                f'rx="2" fill="var({SERIES_SLOTS[slot_index]})" opacity="0.9">'
                f'<title>{_esc(label)} · {_esc(entry["name"])}: {value:,.0f}</title></rect>'
            )
    step = max(1, len(labels) // 8)
    for index in range(0, len(labels), step):
        parts.append(
            f'<text x="{pad_left + index * slot + slot / 2:.1f}" y="{pad_top + plot_h + 15:.1f}" font-size="10.5" '
            f'text-anchor="middle" fill="var(--muted)">{_esc(labels[index])}</text>'
        )
    legend_x = pad_left
    for slot_index, entry in enumerate(series):
        parts.append(
            f'<rect x="{legend_x}" y="{height - 20}" width="9" height="9" rx="2" fill="var({SERIES_SLOTS[slot_index]})" />'
            f'<text x="{legend_x + 14}" y="{height - 12}" font-size="10.5" fill="var(--muted)">{_esc(entry["name"])}</text>'
        )
        legend_x += 24 + 7 * len(str(entry["name"]))
    parts.append("</svg>")
    return "\n".join(parts)


def heatmap_html(
    grid: Sequence[Sequence[float | None]],
    *,
    row_labels: Sequence[str],
    column_labels: Sequence[str],
    row_title: str = "",
    column_title: str = "",
    value_format: str = "{:,.2f}",
    reference: float | None = None,
) -> str:
    """Sensitivity grid as an HTML table on one sequential blue ramp.

    A table rather than an SVG on purpose: the cells carry readable numbers, so
    colour is a secondary cue and the low-contrast steps keep their relief.
    """
    flat = [float(v) for row in grid for v in row if v is not None]
    if not flat:
        return '<p class="viz-empty">No sensitivity data.</p>'
    low, high = min(flat), max(flat)
    span = (high - low) or 1

    def step_for(value: float) -> int:
        # 7-step ramp, light (low) to dark (high).
        return min(7, max(1, int((value - low) / span * 6) + 1))

    head = "".join(f"<th scope='col'>{_esc(c)}</th>" for c in column_labels)
    rows_html = []
    for label, row in zip(row_labels, grid):
        cells = []
        for value in row:
            if value is None:
                cells.append('<td class="heat-na">n/a</td>')
                continue
            step = step_for(float(value))
            classes = f"heat heat-{step}" + (" heat-ref" if reference and abs(float(value) - reference) / reference < 0.02 else "")
            cells.append(f'<td class="{classes}">{_esc(value_format.format(value))}</td>')
        rows_html.append(f"<tr><th scope='row'>{_esc(label)}</th>{''.join(cells)}</tr>")
    return (
        f'<table class="heatmap"><caption class="viz-caption">{_esc(row_title)} (rows) × {_esc(column_title)} (columns)</caption>'
        f"<thead><tr><th scope='col'></th>{head}</tr></thead><tbody>{''.join(rows_html)}</tbody></table>"
    )


def table_html(
    columns: Sequence[dict[str, Any]],
    rows: Iterable[dict[str, Any]],
    *,
    caption: str = "",
    highlight_key: str | None = None,
) -> str:
    """Accessible data table — also the "table view" every chart falls back to."""
    head = "".join(
        f"<th scope='col' class='{'num' if c.get('numeric') else ''}'>{_esc(c['label'])}</th>" for c in columns
    )
    body: list[str] = []
    for row in rows:
        classes = "is-highlight" if highlight_key and row.get(highlight_key) else ""
        cells = []
        for column in columns:
            value = row.get(column["key"])
            fmt = column.get("format")
            if value is None:
                text = "n/a"
            elif fmt:
                try:
                    text = fmt.format(value)
                except (ValueError, TypeError):
                    text = str(value)
            else:
                text = str(value)
            cells.append(f"<td class='{'num' if column.get('numeric') else ''}'>{_esc(text)}</td>")
        body.append(f"<tr class='{classes}'>{''.join(cells)}</tr>")
    caption_html = f"<caption class='viz-caption'>{_esc(caption)}</caption>" if caption else ""
    return f"<table class='data-table'>{caption_html}<thead><tr>{head}</tr></thead><tbody>{''.join(body)}</tbody></table>"
