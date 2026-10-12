import re
import unittest

from argos import charts


class AxisTests(unittest.TestCase):
    def test_ticks_stay_readable_on_narrow_ranges(self):
        # The axis of a chart spanning three percentage points must not produce
        # dozens of gridlines (a real bug this guards against).
        ticks = charts._nice_ticks(20.3, 23.3, 4)
        self.assertLessEqual(len(ticks), 6)
        self.assertGreaterEqual(len(ticks), 3)
        self.assertEqual(ticks, sorted(ticks))
        self.assertLessEqual(ticks[0], 20.3)
        # Gridlines need not reach the very top of the data, but they must span
        # most of it rather than clustering at the bottom.
        self.assertGreater(ticks[-1] - ticks[0], (23.3 - 20.3) * 0.6)

    def test_ticks_on_small_counts(self):
        ticks = charts._nice_ticks(0, 2.2, 4)
        self.assertLessEqual(len(ticks), 5)

    def test_degenerate_range(self):
        self.assertEqual(charts._nice_ticks(5, 5), [5])

    def test_tick_count_is_bounded(self):
        self.assertLessEqual(len(charts._nice_ticks(0, 10 ** 9, 5)), 24)


class RenderTests(unittest.TestCase):
    RANGES = [
        {"method": "Trading comps", "low": 30.0, "high": 45.0, "mid": 37.5, "basis": "12x–18x"},
        {"method": "DCF", "low": 28.0, "high": 50.0, "mid": 39.0, "basis": "WACC 9.9%"},
    ]

    def test_football_field_structure(self):
        svg = charts.football_field_svg(self.RANGES, reference_price=44.1, concluded={"low": 30, "high": 46})
        self.assertTrue(svg.startswith("<svg"))
        self.assertIn("</svg>", svg)
        self.assertIn("role=\"img\"", svg)
        # One bar per methodology, each with a tooltip, plus the reference rule.
        self.assertEqual(svg.count("<title>") - 1, len(self.RANGES))
        self.assertIn("Current", svg)

    def test_charts_use_tokens_not_literal_hex(self):
        svg = charts.football_field_svg(self.RANGES, reference_price=44.1)
        self.assertIn("var(--series-1)", svg)
        self.assertNotIn("#2a78d6", svg)

    def test_empty_inputs_degrade_gracefully(self):
        self.assertIn("viz-empty", charts.football_field_svg([]))
        self.assertIn("viz-empty", charts.column_chart_svg([], []))
        self.assertIn("viz-empty", charts.line_chart_svg(["a"], [1]))
        self.assertIn("viz-empty", charts.stacked_bar_svg([], []))

    def test_labels_are_escaped(self):
        svg = charts.column_chart_svg(["<script>"], [1.0])
        self.assertNotIn("<script>", svg)
        self.assertIn("&lt;script&gt;", svg)

    def test_stacked_series_never_cycle_colours(self):
        series = [{"name": f"s{i}", "values": [1, 2]} for i in range(9)]
        svg = charts.stacked_bar_svg(["a", "b"], series)
        used = set(re.findall(r"var\(--series-(\d)\)", svg))
        self.assertLessEqual(len(used), charts.MAX_SERIES)

    def test_diverging_bars_use_both_poles(self):
        svg = charts.diverging_bar_svg(["a", "b"], [0.4, -0.3])
        self.assertIn("var(--diverging-pos)", svg)
        self.assertIn("var(--diverging-neg)", svg)

    def test_heatmap_marks_reference_and_handles_gaps(self):
        html = charts.heatmap_html(
            [[10.0, None], [12.0, 14.0]],
            row_labels=["a", "b"], column_labels=["x", "y"], reference=12.0,
        )
        self.assertIn("heat-na", html)
        self.assertIn("heat-ref", html)

    def test_table_renders_formats_and_highlight(self):
        html = charts.table_html(
            [{"key": "t", "label": "Ticker"}, {"key": "v", "label": "EV", "numeric": True, "format": "{:,.1f}x"}],
            [{"t": "NVG", "v": 17.5, "is_target": True}, {"t": "HLDX", "v": None}],
            highlight_key="is_target",
        )
        self.assertIn("17.5x", html)
        self.assertIn("is-highlight", html)
        self.assertIn("n/a", html)


class PaletteTests(unittest.TestCase):
    def test_both_modes_define_every_role(self):
        for mode in ("light", "dark"):
            css = charts.css_tokens(mode)
            for token in ("--surface-1", "--text-primary", "--grid", "--series-1", "--seq-7", "--diverging-neg"):
                self.assertIn(token, css, f"{mode} is missing {token}")

    def test_sequential_ramp_is_single_hue_and_ordered(self):
        ramp = charts.PALETTE["light"]["seq"]
        self.assertEqual(len(ramp), 7)
        # Light to dark: the summed channel value must decrease monotonically.
        brightness = [sum(int(step[i:i + 2], 16) for i in (1, 3, 5)) for step in ramp]
        self.assertEqual(brightness, sorted(brightness, reverse=True))

    def test_status_colours_are_not_series_colours(self):
        tokens = charts.PALETTE["dark"]
        series = {tokens[f"series_{i + 1}"] for i in range(charts.MAX_SERIES)}
        for status in ("good", "warning", "critical"):
            self.assertNotIn(tokens[status], series)


if __name__ == "__main__":
    unittest.main()
