"""Valuation tests.

The DCF and football-field figures are the hand-checked ones the Rails port
pins (test/services/valuation_test.rb): the Python build must agree with the
audited Ruby services to the cent. Where a test pinned a figure the audit
showed to be wrong, the comment names the finding (docs/AUDIT.md "Valuation",
docs/RAILS_PORT.md items 11-14).
"""

import sqlite3
import unittest
from datetime import date

from argos import valuation
from argos.valuation import DCFAssumptions
from tests.support import seeded_connection

COMPS = ["HLDX", "VLTR", "CRGD", "PYLN", "TWSW", "MFCL"]

# The loader's schema (period_type / period_end / estimate_source on
# financials; the dated EV bridge on market data). Built here rather than
# through argos.db so these tests pin what valuation reads, independent of the
# migration code; OLD_SCHEMA is a database created before those columns existed.
FUTURE_SCHEMA = """
CREATE TABLE companies (
    id INTEGER PRIMARY KEY, ticker TEXT NOT NULL UNIQUE, name TEXT NOT NULL, sector TEXT,
    industry TEXT, country TEXT, hq TEXT, employees INTEGER, currency TEXT DEFAULT 'USD',
    description TEXT, is_private INTEGER DEFAULT 0
);
CREATE TABLE financials (
    id INTEGER PRIMARY KEY, company_id INTEGER NOT NULL, fiscal_year INTEGER NOT NULL,
    period_type TEXT DEFAULT 'FY', period_end TEXT, is_estimate INTEGER DEFAULT 0, estimate_source TEXT,
    revenue REAL, ebitda REAL, ebit REAL, net_income REAL, eps REAL, dep_amort REAL, capex REAL,
    nwc_change REAL, tax_rate REAL,
    UNIQUE (company_id, fiscal_year, period_type)
);
CREATE TABLE market_data (
    company_id INTEGER PRIMARY KEY, as_of TEXT, share_price REAL, shares_diluted REAL, shares_basic REAL,
    net_debt REAL, net_debt_as_of TEXT, balance_sheet_form TEXT, debt_note TEXT,
    minority_interest REAL, preferred_equity REAL, week52_low REAL, week52_high REAL, beta REAL
);
CREATE TABLE transactions (
    id INTEGER PRIMARY KEY, announced_on TEXT NOT NULL, target TEXT NOT NULL, acquirer TEXT NOT NULL,
    sector TEXT, ev REAL, ev_revenue REAL, ev_ebitda REAL, premium_1day REAL, consideration TEXT, note TEXT
);
"""


OLD_SCHEMA = """
CREATE TABLE companies (id INTEGER PRIMARY KEY, ticker TEXT NOT NULL UNIQUE, name TEXT NOT NULL, sector TEXT,
    industry TEXT, country TEXT, hq TEXT, employees INTEGER, currency TEXT DEFAULT 'USD', description TEXT);
CREATE TABLE financials (id INTEGER PRIMARY KEY, company_id INTEGER NOT NULL, fiscal_year INTEGER NOT NULL,
    is_estimate INTEGER DEFAULT 0, revenue REAL, ebitda REAL, ebit REAL, net_income REAL, eps REAL,
    dep_amort REAL, capex REAL, nwc_change REAL, tax_rate REAL, UNIQUE (company_id, fiscal_year));
CREATE TABLE market_data (company_id INTEGER PRIMARY KEY, as_of TEXT, share_price REAL, shares_diluted REAL,
    net_debt REAL, week52_low REAL, week52_high REAL, beta REAL);
CREATE TABLE transactions (id INTEGER PRIMARY KEY, announced_on TEXT NOT NULL, target TEXT NOT NULL,
    acquirer TEXT NOT NULL, sector TEXT, ev REAL, ev_revenue REAL, ev_ebitda REAL, premium_1day REAL,
    consideration TEXT, note TEXT);
"""


def future_db() -> sqlite3.Connection:
    conn = sqlite3.connect(":memory:")
    conn.row_factory = sqlite3.Row
    conn.executescript(FUTURE_SCHEMA)
    return conn


def add_company(conn: sqlite3.Connection, ticker: str, financials: list[dict], market: dict | None,
                sector: str = "Test") -> None:
    cur = conn.execute("INSERT INTO companies (ticker, name, sector) VALUES (?, ?, ?)", (ticker, f"{ticker} Inc", sector))
    company_id = cur.lastrowid
    for row in financials:
        row = {"company_id": company_id, **row}
        conn.execute(
            f"INSERT INTO financials ({', '.join(row)}) VALUES ({', '.join('?' for _ in row)})", list(row.values())
        )
    if market is not None:
        market = {"company_id": company_id, **market}
        conn.execute(
            f"INSERT INTO market_data ({', '.join(market)}) VALUES ({', '.join('?' for _ in market)})",
            list(market.values()),
        )


def fy(year: int, revenue: float, ebitda: float | None = None, *, estimate: bool = False,
       period_end: str | None = None, **rest) -> dict:
    return {
        "fiscal_year": year, "period_type": "FY", "is_estimate": 1 if estimate else 0,
        "period_end": period_end if period_end is not None else f"{year}-12-31",
        "revenue": revenue, "ebitda": revenue * 0.2 if ebitda is None else ebitda, **rest,
    }


def estimate(year: int, revenue: float, ebitda: float | None, eps: float | None = None, *,
             period_end: str | None = None, source: str | None = None) -> dict:
    return {
        "fiscal_year": year, "period_type": "FY", "is_estimate": 1, "estimate_source": source,
        "period_end": period_end if period_end is not None else f"{year}-12-31",
        "revenue": revenue, "ebitda": ebitda, "eps": eps,
    }


MARKET = {"as_of": "2026-10-09", "share_price": 50.0, "shares_diluted": 100.0, "net_debt": 0.0}


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
    """The demo seed carries no LTM rows, period ends, minority interest or
    preferred equity. Everything must still value, on fiscal years."""

    @classmethod
    def setUpClass(cls):
        cls.conn = seeded_connection()

    def test_enterprise_value_bridge(self):
        metrics = valuation.company_metrics(self.conn, "NVG")
        self.assertAlmostEqual(
            metrics["market_cap"], metrics["share_price"] * metrics["shares_diluted"], places=1
        )
        self.assertAlmostEqual(
            metrics["enterprise_value"], metrics["market_cap"] + metrics["net_debt"] + metrics["other_claims"], places=1
        )

    def test_multiples_use_the_latest_actual_year(self):
        metrics = valuation.company_metrics(self.conn, "NVG")
        latest = metrics["latest_actual"]
        self.assertFalse(latest["is_estimate"])
        self.assertAlmostEqual(latest["ev_ebitda"], metrics["enterprise_value"] / latest["ebitda"], places=1)

    def test_old_schema_reads_as_fiscal_years_with_no_other_claims(self):
        metrics = valuation.company_metrics(self.conn, "NVG")
        self.assertIsNone(metrics["ltm"])
        self.assertEqual(metrics["basis_label"], "FY2026")
        self.assertEqual(metrics["valuation_basis"], metrics["latest_actual"])
        self.assertEqual(metrics["latest_actual"]["period_type"], "FY")
        self.assertEqual(metrics["other_claims"], 0.0)
        self.assertIsNone(metrics["minority_interest"])
        self.assertIsNone(metrics["net_debt_as_of"])
        self.assertEqual(metrics["ev_bridge"]["enterprise_value"], 8436.2)
        self.assertEqual(metrics["ev_bridge"]["price_date"], "2026-10-09")

    def test_forward_years_are_estimates(self):
        metrics = valuation.company_metrics(self.conn, "NVG")
        self.assertTrue(metrics["forward"])
        self.assertTrue(all(row["is_estimate"] for row in metrics["forward"]))

    def test_unknown_ticker(self):
        self.assertIsNone(valuation.company_metrics(self.conn, "NOPE"))

    def test_ticker_is_case_insensitive(self):
        self.assertIsNotNone(valuation.company_metrics(self.conn, "nvg"))


class OldSchemaTests(unittest.TestCase):
    """A database created before the loader added the period and bridge
    columns: rows read as fiscal years, other claims as zero."""

    def test_company_metrics_and_the_field_run_without_the_new_columns(self):
        conn = sqlite3.connect(":memory:")
        conn.row_factory = sqlite3.Row
        conn.executescript(OLD_SCHEMA)
        conn.execute("INSERT INTO companies (id, ticker, name) VALUES (1, 'OLD', 'Old Co')")
        for year, revenue, is_estimate in ((2024, 900.0, 0), (2025, 1000.0, 0), (2026, 1100.0, 1), (2027, 1200.0, 1)):
            conn.execute(
                "INSERT INTO financials (company_id, fiscal_year, is_estimate, revenue, ebitda, eps) VALUES (1, ?, ?, ?, ?, 2.0)",
                (year, is_estimate, revenue, revenue * 0.2),
            )
        conn.execute("INSERT INTO market_data VALUES (1, '2026-10-09', 40.0, 50.0, 100.0, 30.0, 45.0, 1.1)")
        metrics = valuation.company_metrics(conn, "OLD")
        self.assertEqual(metrics["basis_label"], "FY2025")
        self.assertEqual(metrics["enterprise_value"], 2100.0)
        self.assertEqual(metrics["other_claims"], 0.0)
        self.assertIsNone(metrics["net_debt_as_of"])
        self.assertEqual(metrics["ntm"]["fiscal_years"], [2026, 2027])
        field = valuation.football_field(conn, "OLD", [])
        self.assertEqual([r["method"] for r in field["ranges"]], ["DCF", "52-week trading range"])


class LtmAndBridgeTests(unittest.TestCase):
    """RAILS_PORT items 11-12: LTM basis and the full, dated EV bridge."""

    def setUp(self):
        self.conn = future_db()
        add_company(self.conn, "LTMCO", [
            fy(2024, 900.0, 180.0),
            fy(2025, 1000.0, 200.0, eps=2.5, tax_rate=0.21),
            {"fiscal_year": 2026, "period_type": "LTM", "period_end": "2026-06-30", "is_estimate": 0,
             "revenue": 1100.0, "ebitda": 264.0, "eps": 3.0, "dep_amort": 55.0, "capex": 44.0},
        ], {**MARKET, "net_debt": 300.0, "minority_interest": 40.0, "preferred_equity": 60.0,
            "net_debt_as_of": "2026-06-30", "balance_sheet_form": "10-Q", "shares_basic": 98.0})

    def test_ltm_row_is_the_valuation_basis_and_is_labelled(self):
        metrics = valuation.company_metrics(self.conn, "LTMCO")
        self.assertEqual(metrics["basis_label"], "LTM Jun-26")
        self.assertEqual(metrics["latest_actual"]["fiscal_year"], 2025)
        self.assertEqual(metrics["ltm"]["revenue"], 1100.0)
        self.assertEqual(metrics["valuation_basis"]["period_type"], "LTM")
        # EV 5,000 + 300 + 40 + 60 = 5,400; on LTM EBITDA 264 that is 20.45x, on FY2025's 200 it would be 27.0x.
        self.assertEqual(metrics["valuation_basis"]["ev_ebitda"], 20.45)
        self.assertEqual(metrics["latest_actual"]["ev_ebitda"], 27.0)

    def test_enterprise_value_adds_minority_interest_and_preferred_equity(self):
        metrics = valuation.company_metrics(self.conn, "LTMCO")
        self.assertEqual(metrics["enterprise_value"], 5400.0)
        self.assertEqual(metrics["other_claims"], 100.0)
        self.assertEqual(metrics["shares_basic"], 98.0)
        bridge = metrics["ev_bridge"]
        self.assertEqual(bridge["balance_sheet_date"], "2026-06-30")
        self.assertEqual(bridge["balance_sheet_form"], "10-Q")
        self.assertEqual((bridge["minority_interest"], bridge["preferred_equity"]), (40.0, 60.0))

    def test_comps_rows_carry_their_basis(self):
        table = valuation.comps_table(self.conn, ["LTMCO"])
        row = table["rows"][0]
        self.assertEqual(row["basis"], "LTM Jun-26")
        self.assertEqual(row["period_type"], "LTM")
        self.assertEqual(row["revenue"], 1100.0)
        self.assertEqual(row["price_date"], "2026-10-09")
        self.assertEqual(row["net_debt_as_of"], "2026-06-30")
        self.assertEqual(row["other_claims"], 100.0)
        self.assertEqual(table["bases"], {"LTM Jun-26": 1})

    def test_default_assumptions_take_intensities_from_ltm_and_the_stub_from_the_price_date(self):
        a = valuation.default_assumptions(valuation.company_metrics(self.conn, "LTMCO"))
        self.assertEqual(a.base_revenue, 1000.0)  # the projection still starts from the last fiscal year
        self.assertEqual(a.ebitda_margin, 0.24)  # 264 / 1,100
        self.assertEqual(a.da_pct_revenue, 0.05)
        self.assertEqual(a.start_year, 2026)
        # 83 days (9 Oct -> 31 Dec 2026) of FY2026 remain: 83 / 365.25 = 0.2272.
        self.assertEqual(a.stub_fraction, 0.2272)
        self.assertEqual(a.valuation_date, "2026-10-09")
        self.assertEqual(a.other_claims, 100.0)
        self.assertEqual(a.tax_rate, 0.21)


class UnknownNetDebtTests(unittest.TestCase):
    """Audit: unknown net debt was bridged at zero. It must stay unknown."""

    def setUp(self):
        self.conn = future_db()
        add_company(self.conn, "NODEBT", [fy(2025, 1000.0, 200.0, eps=2.0)],
                    {"share_price": 40.0, "shares_diluted": 50.0, "net_debt": None})

    def test_ev_and_ev_multiples_stay_unknown(self):
        metrics = valuation.company_metrics(self.conn, "NODEBT")
        self.assertIsNone(metrics["net_debt"])
        self.assertIsNone(metrics["enterprise_value"])
        self.assertIsNone(metrics["latest_actual"]["ev_ebitda"])
        self.assertIsNone(metrics["latest_actual"]["ev_revenue"])
        self.assertAlmostEqual(metrics["latest_actual"]["pe"], 20.0)
        self.assertAlmostEqual(metrics["market_cap"], 2000.0)

    def test_a_peer_without_net_debt_is_out_of_ev_statistics(self):
        stats = valuation.comps_table(self.conn, ["NODEBT"])["stats"]
        self.assertEqual(stats["ev_ebitda"]["count"], 0)
        self.assertEqual(stats["pe"]["count"], 1)

    def test_no_dcf_bar_and_no_concluded_range(self):
        field = valuation.football_field(self.conn, "NODEBT", [])
        self.assertEqual(field["ranges"], [])
        self.assertIn("Net debt unknown", field["dcf_note"])
        self.assertIsNone(field["dcf"]["value_per_share"])
        self.assertEqual(field["concluded_range"], {"low": None, "high": None, "methods": []})


class NtmTests(unittest.TestCase):
    """Calendarised next-twelve-months estimates (RAILS_PORT item 12, NTM)."""

    def metrics(self, financials, market=None):
        conn = future_db()
        add_company(conn, "NTMCO", financials, MARKET if market is None else market)
        return valuation.company_metrics(conn, "NTMCO")

    def test_december_filer_blends_fy0_and_fy1_by_the_time_remaining(self):
        ntm = self.metrics([
            fy(2025, 900.0, 180.0),
            estimate(2026, 1000.0, 200.0, 2.0, source="consensus"),
            estimate(2027, 1200.0, 300.0, 2.5),
        ])["ntm"]
        # 9 Oct 2026: 22 + 30 + 31 = 83 of FY2026's 365 days remain, w = 0.227397.
        w = 83 / 365
        self.assertEqual(ntm["weight_current_year"], 0.2274)
        self.assertEqual(ntm["fiscal_years"], [2026, 2027])
        self.assertEqual(ntm["revenue"], 1154.5)    # 1,200 - 200w = 1,154.52
        self.assertEqual(ntm["ebitda"], 277.3)      # 300 - 100w = 277.26
        self.assertEqual(ntm["eps"], 2.39)          # 2.5 - 0.5w = 2.386
        self.assertFalse(ntm["ebitda_derived"])
        self.assertEqual(ntm["ev_ebitda"], round(5000 / (300 - 100 * w), 2))  # 18.03
        self.assertEqual(ntm["ev_ebitda"], 18.03)
        self.assertEqual(ntm["ev_revenue"], 4.33)
        self.assertEqual(ntm["pe"], round(50 / (2.5 - 0.5 * w), 2))
        self.assertEqual(ntm["source"], "consensus")
        self.assertEqual(ntm["as_of"], "2026-10-09")

    def test_june_year_end_uses_its_own_period_end(self):
        ntm = self.metrics([
            fy(2026, 900.0, period_end="2026-06-30"),
            estimate(2027, 1000.0, 200.0, period_end="2027-06-30"),
            estimate(2028, 1100.0, 230.0, period_end="2028-06-30"),
        ])["ntm"]
        # 22 + 30 + 31 + 31 + 28 + 31 + 30 + 31 + 30 = 264 of 365 days of FY2027 remain.
        self.assertEqual(ntm["weight_current_year"], 0.7233)
        self.assertEqual(ntm["revenue"], 1027.7)    # 1,100 - 100 x 0.72329 = 1,027.67
        self.assertEqual(ntm["fiscal_years"], [2027, 2028])

    def test_missing_ebitda_estimate_is_derived_from_the_reported_margin_and_flagged(self):
        ntm = self.metrics([
            fy(2025, 900.0, 180.0),
            estimate(2026, 1000.0, None, 2.0),
            estimate(2027, 1200.0, None, 2.5),
        ])["ntm"]
        self.assertTrue(ntm["ebitda_derived"])
        self.assertEqual(ntm["ebitda"], 230.9)      # 1,154.52 x (180 / 900)

    def test_without_fy1_fy0_stands_alone(self):
        ntm = self.metrics([fy(2025, 900.0), estimate(2026, 1000.0, 200.0)])["ntm"]
        self.assertEqual(ntm["revenue"], 1000.0)
        self.assertEqual(ntm["weight_current_year"], 1.0)
        self.assertEqual(ntm["fiscal_years"], [2026, None])

    def test_no_estimates_or_only_stale_ones_give_no_ntm(self):
        self.assertIsNone(self.metrics([fy(2025, 900.0)])["ntm"])
        self.assertIsNone(self.metrics([fy(2024, 900.0), estimate(2025, 1000.0, 200.0)])["ntm"])

    def test_seed_without_period_end_reads_31_december(self):
        # The demo seed marks FY2026 as actual at a 9 Oct 2026 price date, so the
        # first estimate year (FY2027) has not started: it carries all the weight.
        metrics = valuation.company_metrics(seeded_connection(), "NVG")
        ntm = metrics["ntm"]
        self.assertEqual(ntm["fiscal_years"], [2027, 2028])
        self.assertEqual(ntm["weight_current_year"], 1.0)
        fy2027 = next(f for f in metrics["financials"] if f["fiscal_year"] == 2027)
        self.assertEqual(ntm["revenue"], round(fy2027["revenue"], 1))

    def test_comps_rows_and_statistics_carry_ntm_multiples(self):
        table = valuation.comps_table(seeded_connection(), COMPS)
        self.assertTrue(all(row["ev_ebitda_ntm"] is not None for row in table["rows"]))
        self.assertEqual(table["stats"]["ev_ebitda_ntm"]["count"], 6)
        self.assertIn("pe_ntm", table["stats"])
        self.assertIn("ev_revenue_ntm", table["stats"])


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

    def test_old_schema_rows_are_on_fiscal_years(self):
        table = valuation.comps_table(self.conn, ["HLDX", "VLTR"])
        self.assertEqual(table["bases"], {"FY2026": 2})

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

    def test_other_claims_are_deducted_with_net_debt(self):
        implied = valuation.implied_from_multiple(
            10, 10, metric_value=100, kind="ev", net_debt=100, shares=100, other_claims=100
        )
        self.assertEqual(implied["low"], 8.0)  # (1,000 - 100 - 100) / 100

    def test_equity_multiple_applies_directly(self):
        implied = valuation.implied_from_multiple(15, 20, metric_value=2.0, kind="equity", net_debt=999, shares=1)
        self.assertAlmostEqual(implied["low"], 30.0)

    def test_inverted_inputs_are_normalised(self):
        implied = valuation.implied_from_multiple(12, 10, metric_value=100, kind="ev", net_debt=0, shares=10)
        self.assertLess(implied["low"], implied["high"])

    def test_missing_inputs_return_none(self):
        self.assertIsNone(valuation.implied_from_multiple(None, 12, metric_value=100, kind="ev", net_debt=0, shares=10))
        self.assertIsNone(valuation.implied_from_multiple(10, 12, metric_value=0, kind="ev", net_debt=0, shares=10))
        self.assertIsNone(valuation.implied_from_multiple(10, 12, metric_value=100, kind="ev", net_debt=0, shares=None))

    def test_unknown_net_debt_cannot_bridge_an_ev_multiple(self):
        self.assertIsNone(valuation.implied_from_multiple(10, 12, metric_value=100, kind="ev", net_debt=None, shares=10))
        self.assertIsNotNone(
            valuation.implied_from_multiple(10, 12, metric_value=2.0, kind="equity", net_debt=None, shares=10)
        )


class DcfAssumptionTests(unittest.TestCase):
    def test_defaults(self):
        a = DCFAssumptions()
        self.assertEqual(a.other_claims, 0.0)
        self.assertTrue(a.terminal_capex_floor)
        self.assertEqual(a.stub_fraction, 1.0)
        self.assertIsNone(a.valuation_date)
        self.assertFalse(hasattr(a, "growth_fade"))  # audit: replaced by the linear growth path
        self.assertEqual(len(a.to_dict()), 20)

    def test_coerce_reads_form_and_json_booleans(self):
        def cast(value):
            return DCFAssumptions.coerce({"mid_year_convention": value})["mid_year_convention"]
        for truthy in (True, "1", "true", "on"):
            self.assertIs(cast(truthy), True)
        for falsy in (False, "0", "false", "FALSE", "off", 0):
            self.assertIs(cast(falsy), False)
        self.assertIs(DCFAssumptions.coerce({"terminal_capex_floor": "false"})["terminal_capex_floor"], False)

    def test_coerce_parses_the_valuation_date(self):
        self.assertEqual(DCFAssumptions.coerce({"valuation_date": "2026-10-12"})["valuation_date"], "2026-10-12")
        self.assertEqual(DCFAssumptions.coerce({"valuation_date": date(2026, 10, 12)})["valuation_date"], "2026-10-12")
        with self.assertRaises(ValueError):
            DCFAssumptions.coerce({"valuation_date": "12 October"})

    def test_coerce_drops_unknown_blank_and_retired_keys(self):
        clean = DCFAssumptions.coerce({
            "wacc": "0.08", "years": "6", "start_year": 2028.0, "unknown": 1, "exit_multiple": "",
            "terminal_growth": None, "growth_fade": 0.15, "other_claims": "25",
        })
        self.assertEqual(clean, {"wacc": 0.08, "years": 6, "start_year": 2028, "other_claims": 25.0})

    def test_coerce_rejects_values_that_are_not_numbers(self):
        with self.assertRaises(ValueError):
            DCFAssumptions.coerce({"wacc": "ten percent"})
        with self.assertRaises(ValueError):
            DCFAssumptions.coerce({"years": "6.5"})


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
        self.assertEqual([row["year"] for row in result["projections"]], [2027, 2028, 2029, 2030, 2031])
        self.assertEqual(list(result["projections"][0]), [
            "year", "revenue", "growth", "ebitda", "ebitda_margin", "ebit", "taxes", "dep_amort", "capex",
            "nwc_change", "fcf_full_year", "period_fraction", "fcf", "discount_period", "discount_factor", "pv_fcf",
        ])

    def test_result_matches_the_hand_checked_figures(self):
        # Year 1 by hand: revenue 1,100; EBITDA at 25.4% = 279.4; D&A 55; EBIT 224.4; tax 56.1;
        # capex 44; working capital 1% of the 100 revenue INCREASE = 1.0 (the pre-audit code
        # charged 1% of the revenue LEVEL, 11.0: audit "dNWC on revenue level"); FCF 178.3
        # discounted half a year at 10% = 170.0. These replace the pre-audit figures.
        result = valuation.run_dcf(self.base())
        self.assertEqual(result["pv_explicit"], 820.4)
        self.assertEqual(result["terminal_value"], 2806.9)
        self.assertEqual(result["pv_terminal"], 1828.0)
        self.assertEqual(result["terminal_method"], "Gordon growth at 2.0%")
        self.assertEqual(result["terminal_discount_period"], 4.5)
        self.assertEqual(result["terminal_share_of_ev"], 0.6902)
        self.assertEqual(result["enterprise_value"], 2648.3)
        self.assertEqual(result["net_debt"], 200.0)
        self.assertEqual(result["other_claims"], 0.0)
        self.assertEqual(result["equity_value"], 2448.3)
        self.assertEqual(result["value_per_share"], 24.48)
        self.assertEqual(result["implied_ev_ebitda"], 9.48)
        self.assertEqual(result["implied_exit_multiple"], 7.78)
        self.assertEqual(result["implied_terminal_growth"], 0.02)  # a Gordon value implies its own growth
        self.assertIsNone(result["bridge_note"])
        self.assertEqual(result["assumptions"], self.base().to_dict())
        self.assertEqual(result["projections"][0], {
            "year": 2027, "revenue": 1100.0, "growth": 0.1, "ebitda": 279.4, "ebitda_margin": 0.254,
            "ebit": 224.4, "taxes": 56.1, "dep_amort": 55.0, "capex": 44.0, "nwc_change": 1.0,
            "fcf_full_year": 178.3, "period_fraction": 1.0, "fcf": 178.3, "discount_period": 0.5,
            "discount_factor": 0.9535, "pv_fcf": 170.0,
        })
        terminal = result["terminal_year"]
        self.assertEqual(terminal["year"], 2032)
        self.assertTrue(terminal["capex_floored_at_da"])  # 4% capex < 5% D&A: audit "terminal capex below D&A"
        self.assertEqual(terminal["capex"], terminal["dep_amort"])
        self.assertAlmostEqual(
            terminal["ebit"] - terminal["taxes"] + terminal["dep_amort"] - terminal["capex"] - terminal["nwc_change"],
            terminal["fcf"], delta=0.06,
        )

    def test_working_capital_is_zero_at_zero_growth(self):
        flat = valuation.run_dcf(self.base(revenue_growth=0.0, terminal_growth=0.0))
        self.assertEqual([row["nwc_change"] for row in flat["projections"]], [0.0] * 5)
        self.assertEqual(flat["terminal_year"]["nwc_change"], 0.0)
        shrinking = valuation.run_dcf(self.base(revenue_growth=-0.05, terminal_growth=0.0))
        self.assertLess(shrinking["projections"][0]["nwc_change"], 0)  # a decline releases working capital

    def test_exit_multiple_terminal_value_is_discounted_from_year_n(self):
        # Audit: the exit-multiple value was discounted at N - 1/2 under the mid-year convention.
        result = valuation.run_dcf(self.base(exit_multiple=12.0, mid_year_convention=True))
        self.assertEqual(result["terminal_discount_period"], 5.0)
        self.assertAlmostEqual(result["pv_terminal"], result["terminal_value"] / 1.1 ** 5, delta=0.5)
        self.assertAlmostEqual(result["implied_terminal_growth"], 0.0481, delta=1e-4)
        self.assertEqual(valuation.run_dcf(self.base(mid_year_convention=True))["terminal_discount_period"], 4.5)

    def test_stub_halves_year_one_and_shifts_every_discount(self):
        result = valuation.run_dcf(self.base(stub_fraction=0.5))
        first, second = result["projections"][:2]
        self.assertEqual(first["period_fraction"], 0.5)
        self.assertAlmostEqual(first["fcf"], first["fcf_full_year"] / 2, delta=0.06)
        self.assertEqual(first["discount_period"], 0.25)
        self.assertEqual(second["discount_period"], 1.0)
        self.assertEqual(result["terminal_discount_period"], 4.0)
        whole = valuation.run_dcf(self.base())
        self.assertAlmostEqual(result["pv_terminal"], whole["pv_terminal"] * 1.1 ** 0.5, delta=0.5)
        self.assertEqual(result["stub_fraction"], 0.5)
        year_end = valuation.run_dcf(self.base(stub_fraction=0.5, mid_year_convention=False))["projections"]
        self.assertEqual([row["discount_period"] for row in year_end[:2]], [0.5, 1.5])

    def test_stub_outside_zero_one_is_rejected(self):
        for stub in (0.0, -0.1, 1.5):
            with self.assertRaises(ValueError):
                valuation.run_dcf(self.base(stub_fraction=stub))

    def test_unknown_net_debt_gives_enterprise_value_only(self):
        result = valuation.run_dcf(self.base(net_debt=None))
        self.assertEqual(result["enterprise_value"], 2648.3)
        self.assertIsNone(result["net_debt"])
        self.assertIsNone(result["equity_value"])
        self.assertIsNone(result["value_per_share"])
        self.assertIn("Net debt unknown", result["bridge_note"])

    def test_other_claims_are_deducted_with_net_debt(self):
        result = valuation.run_dcf(self.base(other_claims=100.0))
        self.assertEqual(result["equity_value"], 2348.3)
        self.assertEqual(result["value_per_share"], 23.48)

    def test_terminal_capex_floor_can_be_switched_off(self):
        result = valuation.run_dcf(self.base(terminal_capex_floor=False))
        self.assertFalse(result["terminal_year"]["capex_floored_at_da"])
        self.assertLess(result["terminal_year"]["capex"], result["terminal_year"]["dep_amort"])
        self.assertGreater(result["value_per_share"], valuation.run_dcf(self.base())["value_per_share"])

    def test_first_year_revenue_applies_growth(self):
        result = valuation.run_dcf(self.base())
        self.assertAlmostEqual(result["projections"][0]["revenue"], 1100.0, places=1)

    def test_growth_fades_towards_terminal(self):
        growths = [row["growth"] for row in valuation.run_dcf(self.base())["projections"]]
        self.assertEqual(growths, sorted(growths, reverse=True))
        self.assertGreaterEqual(growths[-1], 0.02)

    def test_growth_interpolates_linearly_whatever_its_sign(self):
        # Audit: the old fade (max(terminal, g x (1 - fade))) flipped a negative year 1 to +2.5% in year 2.
        self.assertEqual([row["growth"] for row in valuation.run_dcf(self.base())["projections"]],
                         [0.1, 0.08, 0.06, 0.04, 0.02])
        negative = valuation.run_dcf(self.base(revenue_growth=-0.03, terminal_growth=0.025))["projections"]
        self.assertEqual([row["growth"] for row in negative], [-0.03, -0.0163, -0.0025, 0.0113, 0.025])
        self.assertEqual([row["growth"] for row in valuation.run_dcf(self.base(years=1))["projections"]], [0.1])

    def test_higher_wacc_lowers_value(self):
        cheap = valuation.run_dcf(self.base(wacc=0.08))["value_per_share"]
        dear = valuation.run_dcf(self.base(wacc=0.12))["value_per_share"]
        self.assertGreater(cheap, dear)

    def test_exit_multiple_overrides_gordon_growth(self):
        result = valuation.run_dcf(self.base(exit_multiple=12.0))
        self.assertEqual(result["terminal_method"], "12.0x exit EBITDA multiple")
        self.assertAlmostEqual(
            result["terminal_value"], 12.0 * result["projections"][-1]["ebitda"], places=0
        )

    def test_mid_year_convention_raises_value(self):
        mid = valuation.run_dcf(self.base(mid_year_convention=True))["value_per_share"]
        year_end = valuation.run_dcf(self.base(mid_year_convention=False))["value_per_share"]
        self.assertGreater(mid, year_end)
        self.assertEqual(year_end, 23.25)

    def test_terminal_growth_above_wacc_is_rejected(self):
        with self.assertRaises(ValueError):
            valuation.run_dcf(self.base(terminal_growth=0.11, wacc=0.10))

    def test_non_positive_wacc_is_rejected(self):
        with self.assertRaises(ValueError):
            valuation.run_dcf(self.base(wacc=0.0))

    def test_zero_base_revenue_is_rejected(self):
        with self.assertRaises(ValueError):
            valuation.run_dcf(self.base(base_revenue=0.0))

    def test_zero_years_is_rejected(self):
        with self.assertRaises(ValueError):
            valuation.run_dcf(self.base(years=0))

    def test_zero_shares_gives_no_per_share_value(self):
        result = valuation.run_dcf(self.base(shares_diluted=0.0))
        self.assertIsNone(result["value_per_share"])
        self.assertGreater(result["equity_value"], 0)

    def test_run_dcf_accepts_a_partial_dict(self):
        from_dict = valuation.run_dcf({**self.base().to_dict(), "wacc": "0.1"})
        self.assertEqual(from_dict["value_per_share"], 24.48)

    def test_partial_overrides_keep_other_assumptions(self):
        base = self.base()
        tweaked = base.with_overrides({"wacc": 0.13, "nonsense": 1, "exit_multiple": ""})
        self.assertAlmostEqual(tweaked.wacc, 0.13)
        self.assertAlmostEqual(tweaked.base_revenue, base.base_revenue)
        self.assertIsNone(tweaked.exit_multiple)
        self.assertEqual(base.wacc, 0.10)

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

    def test_sensitivity_matches_the_hand_checked_grid(self):
        sensitivity = valuation.dcf_sensitivity(self.base())
        self.assertEqual(sensitivity["wacc_axis"], [0.085, 0.0925, 0.1, 0.1075, 0.115])
        self.assertEqual(sensitivity["terminal_axis"], [0.01, 0.015, 0.02, 0.025, 0.03])
        self.assertEqual((sensitivity["min"], sensitivity["max"]), (18.54, 35.8))
        self.assertEqual(sensitivity["grid"][2][2], 24.48)


class WaccTests(unittest.TestCase):
    """Audit: the WACC was a constant 9.5% plus a beta nudge. Now a CAPM build."""

    def metrics(self, beta=1.0, **extra):
        return {"financials": [{"fiscal_year": 2025, "is_estimate": 0, "revenue": 100.0}], "beta": beta,
                "net_debt": 100.0, "shares_diluted": 10.0, **extra}

    def test_all_equity_when_there_is_no_market_cap(self):
        build = valuation.wacc_build(self.metrics(beta=1.0))
        self.assertEqual(build["weight_debt"], 0.0)
        self.assertEqual(build["wacc"], 0.0925)  # 4.25% + 1.0 x 5%
        self.assertTrue(any("all-equity" in note for note in build["notes"]))
        self.assertAlmostEqual(valuation.wacc_build(self.metrics(beta=1.5))["wacc"], 0.1175)

    def test_missing_beta_is_assumed_at_one_and_says_so(self):
        build = valuation.wacc_build(self.metrics(beta=None))
        self.assertTrue(build["beta_assumed"])
        self.assertEqual(build["wacc"], 0.0925)
        self.assertTrue(any("Beta not loaded" in note for note in build["notes"]))

    def test_levered_build_weights_after_tax_debt(self):
        build = valuation.wacc_build(self.metrics(beta=1.0, market_cap=900.0))
        self.assertEqual(build["weight_debt"], 0.1)
        self.assertEqual(build["pre_tax_cost_of_debt"], 0.06)       # 4.25% + 175bps
        self.assertEqual(build["tax_rate"], 0.23)
        self.assertAlmostEqual(build["wacc"], 0.9 * 0.0925 + 0.1 * 0.06 * 0.77, delta=1e-4)
        self.assertTrue(any("proxy for gross debt" in note for note in build["notes"]))
        self.assertTrue(any("house defaults" in note for note in build["notes"]))


class DefaultAssumptionTests(unittest.TestCase):
    def metrics_with(self, financials, beta=1.0, net_debt=100.0, shares=10.0, **extra):
        return {"financials": financials, "beta": beta, "net_debt": net_debt, "shares_diluted": shares, **extra}

    @staticmethod
    def year(fiscal_year, revenue, nwc_change=None, tax_rate=None, is_estimate=False, **rest):
        return {"fiscal_year": fiscal_year, "is_estimate": is_estimate, "revenue": revenue, "ebitda": revenue * 0.2,
                "dep_amort": revenue * 0.05, "capex": revenue * 0.04, "nwc_change": nwc_change,
                "tax_rate": tax_rate, **rest}

    def test_working_capital_intensity_is_a_three_year_average(self):
        history = [
            self.year(2022, 100.0, nwc_change=50.0),
            self.year(2023, 100.0, nwc_change=1.0),
            self.year(2024, 100.0, nwc_change=2.0),
            self.year(2025, 100.0, nwc_change=3.0),
            self.year(2026, 100.0, nwc_change=99.0, is_estimate=True),
        ]
        self.assertAlmostEqual(valuation.default_assumptions(self.metrics_with(history)).nwc_pct_revenue, 0.02)

    def test_tax_rate_is_clamped_to_a_normalised_band(self):
        def tax(rate):
            return valuation.default_assumptions(self.metrics_with([self.year(2025, 100.0, tax_rate=rate)])).tax_rate
        self.assertAlmostEqual(tax(0.6), 0.35)
        self.assertAlmostEqual(tax(0.02), 0.15)
        self.assertAlmostEqual(tax(None), 0.23)

    def test_wacc_comes_from_the_build(self):
        # Audit: was 9.5% + 2pts per unit of beta (9.5% / 10.5% here); now rf + beta x ERP, all-equity.
        self.assertAlmostEqual(valuation.default_assumptions(self.metrics_with([self.year(2025, 100.0)])).wacc, 0.0925)
        self.assertAlmostEqual(
            valuation.default_assumptions(self.metrics_with([self.year(2025, 100.0)], beta=1.5)).wacc, 0.1175
        )

    def test_unknown_capital_structure_stays_unknown(self):
        a = valuation.default_assumptions(self.metrics_with([self.year(2025, 100.0)], net_debt=42.0, shares=7.0))
        self.assertEqual((a.net_debt, a.shares_diluted, a.start_year), (42.0, 7.0, 2026))
        # Audit: unknown shares became one share and unknown net debt became zero.
        self.assertIsNone(valuation.default_assumptions(self.metrics_with([self.year(2025, 100.0)], shares=0.0)).shares_diluted)
        self.assertIsNone(valuation.default_assumptions(self.metrics_with([self.year(2025, 100.0)], net_debt=None)).net_debt)

    def test_stub_runs_from_the_price_date_to_the_first_projected_year_end(self):
        history = [self.year(2025, 100.0, period_end="2025-12-31")]
        a = valuation.default_assumptions(self.metrics_with(history, as_of="2026-10-12"))
        self.assertEqual(a.start_year, 2026)
        self.assertAlmostEqual(a.stub_fraction, 80 / 365.25, delta=1e-3)  # 80 days of FY2026 remain
        self.assertEqual(a.valuation_date, "2026-10-12")
        whole = valuation.default_assumptions(self.metrics_with(history, as_of="2026-01-01"))
        self.assertAlmostEqual(whole.stub_fraction, 364 / 365.25, delta=1e-3)
        capped = valuation.default_assumptions(self.metrics_with(history, as_of="2025-06-01"))
        self.assertEqual(capped.stub_fraction, 1.0)

    def test_no_history_yields_generic_defaults_that_do_not_run(self):
        a = valuation.default_assumptions(self.metrics_with([]))
        self.assertEqual((a.base_revenue, a.ebitda_margin, a.start_year), (0.0, 0.2, 2027))
        with self.assertRaises(ValueError):
            valuation.run_dcf(a)


class FootballFieldTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.conn = seeded_connection()
        cls.field = valuation.football_field(cls.conn, "NVG", COMPS)
        cls.by_method = {row["method"]: row for row in cls.field["ranges"]}

    def test_every_methodology_is_present(self):
        self.assertEqual([row["method"] for row in self.field["ranges"]], [
            "Trading comps — NTM EV/EBITDA", "Trading comps — EV/EBITDA", "Trading comps — EV/Revenue",
            "Precedent transactions — EV/EBITDA", "DCF", "52-week trading range",
        ])

    def test_ranges_are_ordered_and_documented(self):
        for row in self.field["ranges"]:
            self.assertLessEqual(row["low"], row["high"])
            # The mid is rounded half-to-even from the rounded ends (34.235 -> 34.23).
            self.assertAlmostEqual(row["mid"], (row["low"] + row["high"]) / 2, delta=0.006)
            self.assertIn("in_conclusion", row)
            self.assertIn("reference", row)
            self.assertIn("note", row)

    def test_ranges_match_the_rails_reference(self):
        comps = self.by_method["Trading comps — EV/EBITDA"]
        self.assertEqual((comps["low"], comps["high"]), (30.2, 45.11))
        self.assertEqual(comps["basis"], "12.25x–17.88x on FY2026 EBITDA of 482")
        revenue = self.by_method["Trading comps — EV/Revenue"]
        self.assertEqual((revenue["low"], revenue["high"]), (24.13, 38.19))
        self.assertEqual(revenue["basis"], "2.61x–4.0x on FY2026 revenue of 1840")
        precedent = self.by_method["Precedent transactions — EV/EBITDA"]
        self.assertEqual((precedent["low"], precedent["high"]), (42.59, 56.34))
        dcf = self.by_method["DCF"]
        self.assertEqual((dcf["low"], dcf["high"]), (27.27, 41.2))
        self.assertEqual(dcf["basis"], "WACC 10.02% ±100bps, terminal growth 2.50% ±50bps")
        self.assertEqual(self.field["dcf"]["value_per_share"], 32.85)
        self.assertEqual((self.field["sensitivity"]["min"], self.field["sensitivity"]["max"]), (24.51, 49.45))

    def test_ntm_bar_applies_the_peer_ntm_quartiles_to_the_target_ntm_ebitda(self):
        bar = self.by_method["Trading comps — NTM EV/EBITDA"]
        self.assertTrue(bar["in_conclusion"])
        ntm_stats = self.field["comps"]["stats"]["ev_ebitda_ntm"]
        target_ntm = valuation.company_metrics(self.conn, "NVG")["ntm"]["ebitda"]
        expected = valuation.implied_from_multiple(
            ntm_stats["p25"], ntm_stats["p75"], metric_value=target_ntm, kind="ev", net_debt=410.0, shares=182.0
        )
        self.assertEqual((bar["low"], bar["high"]), (expected["low"], expected["high"]))
        self.assertIn("NTM EBITDA", bar["basis"])
        self.assertIn("FY2027/FY2028", bar["basis"])

    def test_52_week_range_is_reference_only(self):
        week = self.by_method["52-week trading range"]
        self.assertFalse(week["in_conclusion"])
        self.assertTrue(week["reference"])
        self.assertNotIn("52-week trading range", self.field["concluded_range"]["methods"])

    def test_revenue_multiple_on_a_margin_outlier_is_excluded(self):
        # NVG's 26.2% margin is above the peers' 18.7%-23.4% interquartile range.
        revenue = self.by_method["Trading comps — EV/Revenue"]
        self.assertFalse(revenue["in_conclusion"])
        self.assertIn("outside the peer interquartile range", revenue["note"])
        self.assertEqual(self.field["concluded_range"]["methods"], [
            "Trading comps — NTM EV/EBITDA", "Trading comps — EV/EBITDA",
            "Precedent transactions — EV/EBITDA", "DCF",
        ])

    def test_margin_outlier_rule(self):
        rows = [{"ebitda_margin": m} for m in (0.18, 0.20, 0.22, 0.24)]
        self.assertIsNone(valuation.margin_outlier(0.21, rows))
        self.assertIsNotNone(valuation.margin_outlier(0.30, rows))
        self.assertIsNone(valuation.margin_outlier(0.30, rows[:2]))  # too few peers to call an outlier

    def test_concluded_range_is_the_median_of_the_valuation_methods(self):
        # Audit: the pre-audit conclusion took the median over every bar, the
        # 52-week range and the margin-outlier revenue multiple included.
        counted = [row for row in self.field["ranges"] if row["in_conclusion"]]
        concluded = self.field["concluded_range"]
        self.assertEqual(concluded["low"], round(valuation.percentile([r["low"] for r in counted], 0.5), 2))
        self.assertEqual(concluded["high"], round(valuation.percentile([r["high"] for r in counted], 0.5), 2))
        self.assertGreaterEqual(concluded["low"], min(r["low"] for r in counted))
        self.assertLessEqual(concluded["high"], max(r["high"] for r in counted))
        self.assertLess(concluded["low"], concluded["high"])

    def test_wacc_build_is_shown_with_the_field(self):
        build = self.field["wacc"]
        self.assertEqual(build["beta"], 1.21)
        self.assertFalse(build["beta_assumed"])
        self.assertAlmostEqual(build["weight_debt"], 410.0 / (8026.2 + 410.0), delta=1e-4)
        self.assertEqual(build["wacc"], 0.1002)
        self.assertEqual(self.field["dcf"]["assumptions"]["wacc"], 0.1002)

    def test_target_block(self):
        self.assertEqual(self.field["target"], {
            "ticker": "NVG", "name": "NovaGrid Systems", "share_price": 44.1, "shares_diluted": 182.0,
            "net_debt": 410.0, "other_claims": 0.0, "currency": "USD", "market_cap": 8026.2,
            "enterprise_value": 8436.2, "basis_label": "FY2026", "price_date": "2026-10-09",
            "balance_sheet_date": None,
        })
        self.assertIsNone(self.field["dcf_note"])

    def test_assumption_overrides_change_the_dcf(self):
        tighter = valuation.football_field(self.conn, "NVG", ["HLDX", "VLTR"], assumptions={"wacc": 0.14})
        base_dcf = self.by_method["DCF"]
        tight_dcf = next(row for row in tighter["ranges"] if row["method"] == "DCF")
        self.assertLess(tight_dcf["mid"], base_dcf["mid"])
        self.assertEqual((tight_dcf["low"], tight_dcf["high"]), (18.43, 24.19))

    def test_unknown_target(self):
        with self.assertRaises(ValueError):
            valuation.football_field(self.conn, "NOPE", ["HLDX"])

    def test_default_assumptions_follow_company_history(self):
        metrics = valuation.company_metrics(self.conn, "NVG")
        assumptions = valuation.default_assumptions(metrics)
        self.assertAlmostEqual(assumptions.base_revenue, metrics["latest_actual"]["revenue"], places=1)
        self.assertAlmostEqual(assumptions.net_debt, metrics["net_debt"], places=1)
        self.assertEqual(assumptions.wacc, 0.1002)
        self.assertEqual(assumptions.stub_fraction, 1.0)  # FY2027 has not started on 9 October 2026
        self.assertEqual(assumptions.valuation_date, "2026-10-09")
        self.assertEqual(assumptions.revenue_growth, 0.168)
        self.assertEqual(assumptions.shares_diluted, 182.0)


class NtmBarPresenceTests(unittest.TestCase):
    """The NTM bar needs a target NTM figure and at least three peers with one."""

    PEERS = {"PA": (1000.0, 14.0), "PB": (1200.0, 16.0), "PC": (800.0, 18.0), "PD": (900.0, 20.0)}

    def build(self, peers, *, target_estimates=True):
        conn = future_db()
        target_rows = [fy(2025, 1000.0, 200.0)]
        if target_estimates:
            target_rows += [estimate(2026, 1100.0, 230.0), estimate(2027, 1210.0, 260.0)]
        add_company(conn, "TGT", target_rows, {**MARKET, "net_debt": 100.0})
        for ticker in peers:
            revenue, multiple = self.PEERS[ticker]
            ntm_ebitda = revenue * 0.25
            # Priced at roughly `multiple` x forward EBITDA; only presence is under test here.
            add_company(conn, ticker, [
                fy(2025, revenue, revenue * 0.2),
                estimate(2026, revenue * 1.1, ntm_ebitda), estimate(2027, revenue * 1.2, ntm_ebitda * 1.1),
            ], {**MARKET, "share_price": multiple * ntm_ebitda / 100.0, "net_debt": 0.0})
        return valuation.football_field(conn, "TGT", list(peers))

    def methods(self, field):
        return [row["method"] for row in field["ranges"]]

    def test_three_peers_and_a_target_ntm_draw_the_bar_in_the_conclusion(self):
        field = self.build(["PA", "PB", "PC"])
        self.assertIn("Trading comps — NTM EV/EBITDA", self.methods(field))
        self.assertIn("Trading comps — NTM EV/EBITDA", field["concluded_range"]["methods"])

    def test_two_peers_are_not_enough(self):
        field = self.build(["PA", "PB"])
        self.assertNotIn("Trading comps — NTM EV/EBITDA", self.methods(field))
        self.assertIn("Trading comps — EV/EBITDA", self.methods(field))

    def test_no_target_estimates_no_bar(self):
        field = self.build(["PA", "PB", "PC", "PD"], target_estimates=False)
        self.assertNotIn("Trading comps — NTM EV/EBITDA", self.methods(field))


if __name__ == "__main__":
    unittest.main()
