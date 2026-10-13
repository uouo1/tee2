"""Offline tests for the real-data loaders.

Everything here runs against small hand-built fact structures and HTML
fragments — no network — so the suite stays runnable in CI while still pinning
down the XBRL selection rules that decide which numbers reach a pitch book.
"""

import unittest

from argos.sources import sec
from argos.sources.htmltext import html_to_text
from tests.support import empty_connection


def _fact(val, start, end, *, form="10-K", fp="FY", filed="2026-02-20"):
    return {"val": val, "start": start, "end": end, "form": form, "fp": fp, "filed": filed}


def _instant(val, end, *, form="10-K", fp="FY", filed="2026-02-20"):
    return {"val": val, "end": end, "form": form, "fp": fp, "filed": filed}


def facts_fixture():
    """Two fiscal years of a filer that tags revenue the modern way."""
    return {"facts": {
        "dei": {"EntityCommonStockSharesOutstanding": {"units": {"shares": [
            _instant(40_000_000, "2025-12-31", filed="2026-02-20"),
            _instant(43_790_000, "2026-06-30", filed="2026-08-01", form="10-Q", fp="Q2"),
        ]}}},
        "us-gaap": {
            "RevenueFromContractWithCustomerExcludingAssessedTax": {"units": {"USD": [
                _fact(2_000e6, "2024-01-01", "2024-12-31", filed="2025-02-20"),
                _fact(2_400e6, "2025-01-01", "2025-12-31"),
                # A quarter must never be mistaken for a year.
                _fact(600e6, "2025-10-01", "2025-12-31", form="10-K", fp="FY"),
                # A restatement filed later wins over the original.
                _fact(2_010e6, "2024-01-01", "2024-12-31", filed="2026-02-20"),
            ]}},
            "OperatingIncomeLoss": {"units": {"USD": [
                _fact(200e6, "2024-01-01", "2024-12-31", filed="2025-02-20"),
                _fact(300e6, "2025-01-01", "2025-12-31"),
            ]}},
            "DepreciationDepletionAndAmortization": {"units": {"USD": [
                _fact(50e6, "2024-01-01", "2024-12-31", filed="2025-02-20"),
                _fact(60e6, "2025-01-01", "2025-12-31"),
            ]}},
            "NetIncomeLoss": {"units": {"USD": [_fact(150e6, "2025-01-01", "2025-12-31")]}},
            "EarningsPerShareDiluted": {"units": {"USD/shares": [_fact(3.5, "2025-01-01", "2025-12-31")]}},
            "PaymentsToAcquirePropertyPlantAndEquipment": {"units": {"USD": [_fact(30e6, "2025-01-01", "2025-12-31")]}},
            "IncomeLossFromContinuingOperationsBeforeIncomeTaxesExtraordinaryItemsNoncontrollingInterest": {
                "units": {"USD": [_fact(250e6, "2025-01-01", "2025-12-31")]}},
            "IncomeTaxExpenseBenefit": {"units": {"USD": [_fact(50e6, "2025-01-01", "2025-12-31")]}},
            "CashAndCashEquivalentsAtCarryingValue": {"units": {"USD": [_instant(1_000e6, "2025-12-31")]}},
            "LongTermDebtCurrent": {"units": {"USD": [_instant(450e6, "2025-12-31")]}},
            "LongTermDebtNoncurrent": {"units": {"USD": [_instant(800e6, "2025-12-31")]}},
            "AssetsCurrent": {"units": {"USD": [
                _instant(1_500e6, "2024-12-31", filed="2025-02-20"), _instant(1_800e6, "2025-12-31"),
            ]}},
            "LiabilitiesCurrent": {"units": {"USD": [
                _instant(900e6, "2024-12-31", filed="2025-02-20"), _instant(1_000e6, "2025-12-31"),
            ]}},
        },
    }}


class FinancialsTests(unittest.TestCase):
    def test_full_year_rows_in_millions(self):
        rows = sec.build_financials(facts_fixture())
        by_year = {row["fiscal_year"]: row for row in rows}
        self.assertEqual(sorted(by_year), [2024, 2025])
        self.assertAlmostEqual(by_year[2025]["revenue"], 2400.0)
        self.assertAlmostEqual(by_year[2025]["ebitda"], 360.0)      # EBIT 300 + D&A 60
        self.assertAlmostEqual(by_year[2025]["ebit"], 300.0)
        self.assertAlmostEqual(by_year[2025]["eps"], 3.5)
        self.assertAlmostEqual(by_year[2025]["capex"], 30.0)
        self.assertAlmostEqual(by_year[2025]["tax_rate"], 0.2)

    def test_quarter_is_not_mistaken_for_a_year(self):
        rows = sec.build_financials(facts_fixture())
        self.assertNotIn(600.0, [row["revenue"] for row in rows])

    def test_later_filing_restates_earlier_year(self):
        rows = {row["fiscal_year"]: row for row in sec.build_financials(facts_fixture())}
        self.assertAlmostEqual(rows[2024]["revenue"], 2010.0)

    def test_working_capital_excludes_cash_and_debt(self):
        rows = {row["fiscal_year"]: row for row in sec.build_financials(facts_fixture())}
        # 2025: (1800 - 1000 cash) - (1000 - 450 debt) = 250; 2024: 1500 - 900 = 600
        self.assertAlmostEqual(rows[2025]["nwc_change"], -350.0)
        self.assertIsNone(rows[2024]["nwc_change"])

    def test_early_january_year_end_belongs_to_prior_fiscal_year(self):
        self.assertEqual(sec._fiscal_year("2026-01-02"), 2025)
        self.assertEqual(sec._fiscal_year("2025-12-31"), 2025)
        self.assertEqual(sec._fiscal_year("2026-01-31"), 2026)

    def test_separate_depreciation_and_amortisation_tags_are_summed(self):
        facts = facts_fixture()
        gaap = facts["facts"]["us-gaap"]
        del gaap["DepreciationDepletionAndAmortization"]
        gaap["Depreciation"] = {"units": {"USD": [_fact(40e6, "2025-01-01", "2025-12-31")]}}
        gaap["AmortizationOfIntangibleAssets"] = {"units": {"USD": [_fact(15e6, "2025-01-01", "2025-12-31")]}}
        rows = {row["fiscal_year"]: row for row in sec.build_financials(facts)}
        self.assertAlmostEqual(rows[2025]["dep_amort"], 55.0)
        self.assertAlmostEqual(rows[2025]["ebitda"], 355.0)

    def test_missing_concepts_become_none_not_zero(self):
        facts = facts_fixture()
        del facts["facts"]["us-gaap"]["DepreciationDepletionAndAmortization"]
        rows = {row["fiscal_year"]: row for row in sec.build_financials(facts)}
        self.assertIsNone(rows[2025]["ebitda"])
        self.assertIsNone(rows[2025]["dep_amort"])

    def test_tag_preference_falls_back(self):
        facts = facts_fixture()
        gaap = facts["facts"]["us-gaap"]
        gaap["Revenues"] = gaap.pop("RevenueFromContractWithCustomerExcludingAssessedTax")
        rows = sec.build_financials(facts)
        self.assertTrue(rows)

    def test_years_limit_keeps_newest(self):
        rows = sec.build_financials(facts_fixture(), years=1)
        self.assertEqual([row["fiscal_year"] for row in rows], [2025])


class BalanceSheetTests(unittest.TestCase):
    def test_net_debt_bridges_debt_and_cash(self):
        self.assertAlmostEqual(sec.net_debt(facts_fixture(), 2025), 250.0)  # 450 + 800 - 1000

    def test_net_debt_missing_year(self):
        self.assertIsNone(sec.net_debt(facts_fixture(), 2019))

    def test_cover_shares_uses_latest_period(self):
        self.assertAlmostEqual(sec._cover_shares(facts_fixture()), 43_790_000)

    def test_shares_fall_back_to_weighted_diluted_for_multi_class_filers(self):
        facts = facts_fixture()
        facts["facts"]["dei"] = {}
        facts["facts"]["us-gaap"]["WeightedAverageNumberOfDilutedSharesOutstanding"] = {
            "units": {"shares": [_fact(33_000_000, "2025-01-01", "2025-12-31")]}}
        self.assertAlmostEqual(sec.shares_outstanding(facts), 33_000_000)
        facts["facts"]["us-gaap"].pop("WeightedAverageNumberOfDilutedSharesOutstanding")
        self.assertIsNone(sec.shares_outstanding(facts))


class DocumentSelectionTests(unittest.TestCase):
    def test_recent_filings_are_rowised(self):
        submissions = {"filings": {"recent": {
            "form": ["10-K", "8-K"], "accessionNumber": ["0001-25-1", "0001-25-2"],
            "filingDate": ["2026-02-20", "2026-04-30"], "reportDate": ["2025-12-31", "2026-04-29"],
            "primaryDocument": ["a.htm", "b.htm"], "primaryDocDescription": ["10-K", "8-K"],
        }}}
        rows = sec._recent_filings(submissions)
        self.assertEqual([row["form"] for row in rows], ["10-K", "8-K"])
        self.assertEqual(rows[1]["accessionNumber"], "0001-25-2")

    def test_form_to_doc_type_mapping(self):
        self.assertEqual(sec.FORM_DOC_TYPES["10-K"], "filing")
        self.assertEqual(sec.FORM_DOC_TYPES["8-K"], "press-release")


class HtmlTextTests(unittest.TestCase):
    def test_strips_tags_scripts_and_hidden_xbrl(self):
        markup = """
        <html><head><title>x</title><style>p{}</style></head><body>
        <div style="display:none">HIDDEN FACT COPY</div>
        <ix:header>hidden header</ix:header>
        <p>Revenue increased 12% to $2.4 billion.</p>
        <script>alert(1)</script>
        <p>Gross margin was 34.5%.</p>
        </body></html>"""
        text = html_to_text(markup)
        self.assertIn("Revenue increased 12%", text)
        self.assertIn("Gross margin was 34.5%", text)
        self.assertNotIn("HIDDEN", text)
        self.assertNotIn("alert", text)
        self.assertNotIn("<p>", text)

    def test_wrapped_lines_are_rejoined_into_paragraphs(self):
        text = html_to_text("<div>Revenue grew because</div><div>demand was strong.</div><div>Next item.</div>")
        self.assertIn("Revenue grew because demand was strong.", text)
        self.assertIn("\n\nNext item.", text)

    def test_page_numbers_are_dropped(self):
        text = html_to_text("<p>Item 1A.</p><p>42</p><p>Risk factors follow.</p>")
        self.assertNotIn("\n42", text)

    def test_max_chars_cuts_on_a_paragraph_boundary(self):
        markup = "".join(f"<p>Paragraph number {i} with some words.</p>" for i in range(200))
        text = html_to_text(markup, max_chars=800)
        self.assertLessEqual(len(text), 800)
        self.assertTrue(text.endswith("."))

    def test_table_of_contents_rows_and_headers_are_dropped(self):
        markup = ("<p>Table of Contents</p><p>Item 1A. Risk Factors 12</p><p>PART II</p>"
                  "<p>Table of Contents and revised tariffs apply.</p><p>Signatures 48</p>")
        text = html_to_text(markup)
        self.assertNotIn("Table of Contents", text)
        self.assertNotIn("Risk Factors 12", text)
        self.assertNotIn("PART II", text)
        self.assertIn("and revised tariffs apply.", text)

    def test_zero_width_characters_are_removed(self):
        text = html_to_text("<p>June\u200b 28,\u200b 2026 revenue\ufeff grew</p>")
        self.assertNotIn("\u200b", text)
        self.assertIn("June 28, 2026 revenue grew", text)

    def test_bytes_input(self):
        self.assertIn("hello", html_to_text(b"<p>hello</p>"))


class TransactionsCsvTests(unittest.TestCase):
    def test_csv_round_trip(self):
        import tempfile
        from pathlib import Path

        conn = empty_connection()
        self.addCleanup(conn.close)
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "deals.csv"
            path.write_text(
                "announced_on,target,acquirer,sector,ev,ev_revenue,ev_ebitda,premium_1day,consideration,note\n"
                "2025-03-01,Target Co,Buyer Inc,Widgets,1500,3.2,14.5,0.28,Cash,Two-bidder process\n"
                ",,missing,,,,,,,\n",
                encoding="utf-8",
            )
            result = sec.load_transactions_csv(conn, path)
        self.assertEqual(result["added"], 1)
        row = conn.execute("SELECT target, ev_ebitda, premium_1day FROM transactions").fetchone()
        self.assertEqual(row[0], "Target Co")
        self.assertAlmostEqual(row[1], 14.5)
        self.assertAlmostEqual(row[2], 0.28)


if __name__ == "__main__":
    unittest.main()
