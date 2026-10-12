import unittest

from argos import valuation
from argos.valuation import DCFAssumptions
from tests.support import seeded_connection


class StatisticsTests(unittest.TestCase):
    def test_percentile_interpolates(self):
        values = [1, 2, 3, 4]
        self.assertEqual(valuation.percentile(values, 0), 1)
        self.assertEqual(valuation.percentile(values, 1), 4)
        self.assertAlmostEqual(valuation.percentile(values, 0.5), 2.5)

    def test_percentile_handles_empty_and_single(self):
        self.assertIsNone(valuation.percentile([], 0.5))
        self.assertEqual(valuation.percentile([7], 0.9), 7.0)

    def test_describe_ignores_missing_values(self):
        stats = valuation.describe([1, None, 3])
        self.assertEqual(stats["count"], 2)
        self.assertEqual(stats["min"], 1)
        self.assertEqual(stats["max"], 3)


class CompanyMetricTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.conn = seeded_connection()

    def test_enterprise_value_bridge(self):
        metrics = valuation.company_metrics(self.conn, "NVG")
        self.assertAlmostEqual(
            metrics["market_cap"], metrics["share_price"] * metrics["shares_diluted"], places=1
        )
        self.assertAlmostEqual(
            metrics["enterprise_value"], metrics["market_cap"] + metrics["net_debt"], places=1
        )

    def test_multiples_use_the_latest_actual_year(self):
        metrics = valuation.company_metrics(self.conn, "NVG")
        latest = metrics["latest_actual"]
        self.assertFalse(latest["is_estimate"])
        self.assertAlmostEqual(latest["ev_ebitda"], metrics["enterprise_value"] / latest["ebitda"], places=1)

    def test_forward_years_are_estimates(self):
        metrics = valuation.company_metrics(self.conn, "NVG")
        self.assertTrue(metrics["forward"])
        self.assertTrue(all(row["is_estimate"] for row in metrics["forward"]))

    def test_unknown_ticker(self):
        self.assertIsNone(valuation.company_metrics(self.conn, "NOPE"))

    def test_ticker_is_case_insensitive(self):
        self.assertIsNotNone(valuation.company_metrics(self.conn, "nvg"))


class CompsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.conn = seeded_connection()

    def test_table_excludes_the_target_and_sorts_by_size(self):
        table = valuation.comps_table(self.conn, ["NVG", "HLDX", "VLTR"], exclude="NVG")
        self.assertNotIn("NVG", [row["ticker"] for row in table["rows"]])
        sizes = [row["enterprise_value"] for row in table["rows"]]
        self.assertEqual(sizes, sorted(sizes, reverse=True))

    def test_statistics_bracket_the_observations(self):
        table = valuation.comps_table(self.conn, ["HLDX", "VLTR", "CRGD", "PYLN"])
        stats = table["stats"]["ev_ebitda"]
        observed = [row["ev_ebitda"] for row in table["rows"]]
        self.assertLessEqual(stats["min"], min(observed))
        self.assertGreaterEqual(stats["max"], max(observed))
        self.assertLessEqual(stats["p25"], stats["median"])
        self.assertLessEqual(stats["median"], stats["p75"])

    def test_precedents_include_premium_statistics(self):
        precedents = valuation.precedent_transactions(self.conn)
        self.assertTrue(precedents["rows"])
        self.assertIn("premium_1day", precedents["stats"])
        self.assertGreater(precedents["stats"]["ev_ebitda"]["count"], 0)


class ImpliedValueTests(unittest.TestCase):
    def test_enterprise_multiple_bridges_through_net_debt(self):
        implied = valuation.implied_from_multiple(
            10, 12, metric_value=100, kind="ev", net_debt=200, shares=50
        )
        self.assertAlmostEqual(implied["low"], (10 * 100 - 200) / 50)
        self.assertAlmostEqual(implied["high"], (12 * 100 - 200) / 50)
        self.assertAlmostEqual(implied["mid"], (implied["low"] + implied["high"]) / 2)

    def test_equity_multiple_applies_directly(self):
        implied = valuation.implied_from_multiple(15, 20, metric_value=2.0, kind="equity", net_debt=999, shares=1)
        self.assertAlmostEqual(implied["low"], 30.0)

    def test_inverted_inputs_are_normalised(self):
        implied = valuation.implied_from_multiple(12, 10, metric_value=100, kind="ev", net_debt=0, shares=10)
        self.assertLess(implied["low"], implied["high"])

    def test_missing_inputs_return_none(self):
        self.assertIsNone(valuation.implied_from_multiple(None, 12, metric_value=100, kind="ev", net_debt=0, shares=10))
        self.assertIsNone(valuation.implied_from_multiple(10, 12, metric_value=0, kind="ev", net_debt=0, shares=10))


class DcfTests(unittest.TestCase):
    def base(self, **overrides) -> DCFAssumptions:
        defaults = dict(
            base_revenue=1000.0, revenue_growth=0.10, ebitda_margin=0.25, da_pct_revenue=0.05,
            capex_pct_revenue=0.04, nwc_pct_revenue=0.01, tax_rate=0.25, wacc=0.10,
            terminal_growth=0.02, years=5, net_debt=200.0, shares_diluted=100.0,
        )
        defaults.update(overrides)
        return DCFAssumptions(**defaults)

    def test_projection_shape_and_bridge(self):
        result = valuation.run_dcf(self.base())
        self.assertEqual(len(result["projections"]), 5)
        self.assertAlmostEqual(
            result["enterprise_value"], result["pv_explicit"] + result["pv_terminal"], places=0
        )
        self.assertAlmostEqual(result["equity_value"], result["enterprise_value"] - 200.0, places=0)
        self.assertAlmostEqual(result["value_per_share"], result["equity_value"] / 100.0, places=1)

    def test_first_year_revenue_applies_growth(self):
        result = valuation.run_dcf(self.base())
        self.assertAlmostEqual(result["projections"][0]["revenue"], 1100.0, places=1)

    def test_growth_fades_towards_terminal(self):
        growths = [row["growth"] for row in valuation.run_dcf(self.base())["projections"]]
        self.assertEqual(growths, sorted(growths, reverse=True))
        self.assertGreaterEqual(growths[-1], 0.02)

    def test_higher_wacc_lowers_value(self):
        cheap = valuation.run_dcf(self.base(wacc=0.08))["value_per_share"]
        dear = valuation.run_dcf(self.base(wacc=0.12))["value_per_share"]
        self.assertGreater(cheap, dear)

    def test_exit_multiple_overrides_gordon_growth(self):
        result = valuation.run_dcf(self.base(exit_multiple=12.0))
        self.assertIn("exit EBITDA", result["terminal_method"])
        self.assertAlmostEqual(
            result["terminal_value"], 12.0 * result["projections"][-1]["ebitda"], places=0
        )

    def test_mid_year_convention_raises_value(self):
        mid = valuation.run_dcf(self.base(mid_year_convention=True))["value_per_share"]
        year_end = valuation.run_dcf(self.base(mid_year_convention=False))["value_per_share"]
        self.assertGreater(mid, year_end)

    def test_terminal_growth_above_wacc_is_rejected(self):
        with self.assertRaises(ValueError):
            valuation.run_dcf(self.base(terminal_growth=0.11, wacc=0.10))

    def test_non_positive_wacc_is_rejected(self):
        with self.assertRaises(ValueError):
            valuation.run_dcf(self.base(wacc=0.0))

    def test_zero_base_revenue_is_rejected(self):
        with self.assertRaises(ValueError):
            valuation.run_dcf(self.base(base_revenue=0.0))

    def test_partial_overrides_keep_other_assumptions(self):
        base = self.base()
        tweaked = base.with_overrides({"wacc": 0.13, "nonsense": 1, "exit_multiple": ""})
        self.assertAlmostEqual(tweaked.wacc, 0.13)
        self.assertAlmostEqual(tweaked.base_revenue, base.base_revenue)
        self.assertIsNone(tweaked.exit_multiple)

    def test_assumptions_round_trip_from_dict(self):
        assumptions = DCFAssumptions.from_dict({"wacc": "0.08", "years": "6", "unknown": 1, "exit_multiple": ""})
        self.assertAlmostEqual(assumptions.wacc, 0.08)
        self.assertEqual(assumptions.years, 6)
        self.assertIsNone(assumptions.exit_multiple)

    def test_sensitivity_grid_shape_and_monotonicity(self):
        sensitivity = valuation.dcf_sensitivity(self.base())
        self.assertEqual(len(sensitivity["grid"]), len(sensitivity["terminal_axis"]))
        self.assertEqual(len(sensitivity["grid"][0]), len(sensitivity["wacc_axis"]))
        # Along a row, a rising WACC must reduce value.
        row = [value for value in sensitivity["grid"][0] if value is not None]
        self.assertEqual(row, sorted(row, reverse=True))


class FootballFieldTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.conn = seeded_connection()
        cls.field = valuation.football_field(
            cls.conn, "NVG", ["HLDX", "VLTR", "CRGD", "PYLN", "TWSW", "MFCL"]
        )

    def test_every_methodology_is_present(self):
        methods = {row["method"] for row in self.field["ranges"]}
        for expected in ("DCF", "52-week trading range"):
            self.assertIn(expected, methods)
        self.assertTrue(any("Trading comps" in method for method in methods))
        self.assertTrue(any("Precedent" in method for method in methods))

    def test_ranges_are_ordered_and_documented(self):
        for row in self.field["ranges"]:
            self.assertLessEqual(row["low"], row["high"])
            self.assertAlmostEqual(row["mid"], (row["low"] + row["high"]) / 2, places=2)

    def test_concluded_range_sits_inside_the_methodologies(self):
        concluded = self.field["concluded_range"]
        lows = [row["low"] for row in self.field["ranges"]]
        highs = [row["high"] for row in self.field["ranges"]]
        self.assertGreaterEqual(concluded["low"], min(lows))
        self.assertLessEqual(concluded["high"], max(highs))
        self.assertLess(concluded["low"], concluded["high"])

    def test_assumption_overrides_change_the_dcf(self):
        tighter = valuation.football_field(self.conn, "NVG", ["HLDX", "VLTR"], assumptions={"wacc": 0.14})
        base_dcf = next(row for row in self.field["ranges"] if row["method"] == "DCF")
        tight_dcf = next(row for row in tighter["ranges"] if row["method"] == "DCF")
        self.assertLess(tight_dcf["mid"], base_dcf["mid"])

    def test_unknown_target(self):
        with self.assertRaises(ValueError):
            valuation.football_field(self.conn, "NOPE", ["HLDX"])

    def test_default_assumptions_follow_company_history(self):
        metrics = valuation.company_metrics(self.conn, "NVG")
        assumptions = valuation.default_assumptions(metrics)
        self.assertAlmostEqual(assumptions.base_revenue, metrics["latest_actual"]["revenue"], places=1)
        self.assertAlmostEqual(assumptions.net_debt, metrics["net_debt"], places=1)
        self.assertGreater(assumptions.wacc, 0)


if __name__ == "__main__":
    unittest.main()
