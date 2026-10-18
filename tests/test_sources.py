"""Offline tests for the real-data loaders.

Everything here runs against small hand-built fact structures and HTML
fragments — no network — so the suite stays runnable in CI while still pinning
down the XBRL selection rules that decide which numbers reach a pitch book.
"""

import json
import sqlite3
import tempfile
import unittest
import urllib.error
from datetime import date
from pathlib import Path
from unittest import mock

from argos import db
from argos.sources import http as argos_http
from argos.sources import market, sec
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
        self.assertEqual([row["period_type"] for row in rows], ["FY", "FY"])  # no 10-Q, no LTM row
        self.assertEqual(by_year[2025]["period_end"], "2025-12-31")
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

    def test_shares_outstanding_without_weighted_count_is_the_cover_page(self):
        # Audit item 15: shares_outstanding is now shares()["diluted"]; with no
        # weighted diluted tag in the fixture that is still the cover count.
        self.assertAlmostEqual(sec.shares_outstanding(facts_fixture()), 43_790_000)
        self.assertEqual(sec.shares(facts_fixture())["basis"], "cover_page")

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

    def test_a_hidden_span_does_not_swallow_the_paragraphs_that_follow_it(self):
        text = html_to_text(
            '<span style="display:none">hidden fact</span><p>Revenue rose 12% this quarter.</p>'
            '<div><p>Backlog was $4.4 billion.</p></div>'
        )
        self.assertIn("Revenue rose 12%", text)
        self.assertIn("Backlog was $4.4 billion", text)
        self.assertNotIn("hidden fact", text)

    def test_a_hidden_block_ends_when_its_own_tag_closes_even_with_nested_copies(self):
        text = html_to_text('<div style="display:none"><div>inner</div>still hidden</div><p>Visible after.</p>')
        self.assertNotIn("inner", text)
        self.assertNotIn("still hidden", text)
        self.assertIn("Visible after.", text)

    def test_a_hidden_void_tag_does_not_hide_the_rest_of_the_document(self):
        text = html_to_text('<br style="display:none"><p>Still visible.</p>')
        self.assertIn("Still visible.", text)

    def test_an_unclosed_hidden_span_ends_with_the_element_that_contains_it(self):
        # The stack holds every open element, so closing the cell closes the span
        # inside it, as a browser would; the next cell is content again.
        text = html_to_text(
            '<table><tr><td><span style="display:none">hidden fact</td><td>Visible cell text.</td></tr></table>'
            '<p>Visible paragraph.</p>'
        )
        self.assertNotIn("hidden fact", text)
        self.assertIn("Visible cell text.", text)
        self.assertIn("Visible paragraph.", text)

    def test_hidden_table_cells_do_not_truncate_the_filing(self):
        # Inline-XBRL statements carry hidden <td> cells; the earlier converter
        # counted each one as an open hidden block that only a </div> could
        # close, so everything after the first financial table was lost.
        cells = "".join('<td style="display:none">x</td>' for _ in range(8))
        markup = (
            "<p>Before the table.</p>"
            f"<table><tr>{cells}<td>Net income</td><td>53,473</td></tr></table>"
            "<p>Total bookings and backlog include certain contracts.</p>"
            "<div><p>Risk factors follow.</p></div>"
        )
        text = html_to_text(markup)
        self.assertIn("Net income", text)
        self.assertIn("Total bookings and backlog", text)
        self.assertIn("Risk factors follow.", text)
        self.assertNotIn("x", text.replace("Risk factors", "").replace("table", "").replace("Net income", ""))

    def test_a_stray_close_tag_and_hidden_markup_inside_skipped_elements_are_harmless(self):
        text = html_to_text('</div></span><noscript><div style="display:none">x</noscript><p>Shown anyway.</p>')
        self.assertEqual("Shown anyway.", text)

    def test_whitespace_only_spans_keep_words_apart(self):
        text = html_to_text("<p><span>the</span><span> </span><span>FASB</span></p>")
        self.assertIn("the FASB", text)

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


# ----------------------------------------------------------------- audit ports


def _q(val, start, end, *, fp="Q2", filed="2026-08-01"):
    return _fact(val, start, end, form="10-Q", fp=fp, filed=filed)


def ltm_fixture():
    """facts_fixture plus a Q2 2026 10-Q: six-month YTD and its prior-year comparable.

    The three-month quarter is listed FIRST on purpose: it ends on the same day
    and its ~91-day span sits inside the Q1 window, so it must not be rolled.
    """
    facts = facts_fixture()
    gaap = facts["facts"]["us-gaap"]

    def add(tag, unit, *entries):
        gaap.setdefault(tag, {"units": {}})["units"].setdefault(unit, []).extend(entries)

    add("RevenueFromContractWithCustomerExcludingAssessedTax", "USD",
        _q(700e6, "2026-04-01", "2026-06-30"),            # three months — ignored
        _q(1_300e6, "2026-01-01", "2026-06-30"),
        _q(1_150e6, "2025-01-01", "2025-06-30"),
        _q(560e6, "2025-01-01", "2025-03-31", fp="Q1", filed="2025-05-01"))  # older Q1, ends before FY
    add("OperatingIncomeLoss", "USD", _q(170e6, "2026-01-01", "2026-06-30"), _q(140e6, "2025-01-01", "2025-06-30"))
    add("NetIncomeLoss", "USD", _q(90e6, "2026-01-01", "2026-06-30"), _q(70e6, "2025-01-01", "2025-06-30"))
    add("EarningsPerShareDiluted", "USD/shares", _q(2.10, "2026-01-01", "2026-06-30"), _q(1.70, "2025-01-01", "2025-06-30"))
    add("PaymentsToAcquirePropertyPlantAndEquipment", "USD",
        _q(18e6, "2026-01-01", "2026-06-30"), _q(14e6, "2025-01-01", "2025-06-30"))
    return facts


class TagResolutionTests(unittest.TestCase):
    """Audit item 11: tags resolve per year / per date, never once per company."""

    def test_later_tag_fills_years_the_preferred_tag_lacks(self):
        facts = {"facts": {"us-gaap": {
            "Revenues": {"units": {"USD": [
                _fact(1e9, "2023-01-01", "2023-12-31", filed="2024-02-01"),
                _fact(1.1e9, "2024-01-01", "2024-12-31", filed="2025-02-01"),
            ]}},
            "SalesRevenueNet": {"units": {"USD": [
                _fact(9e8, "2024-01-01", "2024-12-31", filed="2025-02-01"),
                _fact(1.2e9, "2025-01-01", "2025-12-31"),
            ]}},
        }}}
        entries = sec.duration_entries(facts, sec.TAGS["revenue"])
        self.assertEqual({y: r["tag"] for y, r in entries.items()},
                         {2023: "Revenues", 2024: "Revenues", 2025: "SalesRevenueNet"})
        self.assertEqual(entries[2024]["value"], 1.1e9)          # earlier tag wins the shared year
        self.assertEqual(entries[2025]["period_end"], date(2025, 12, 31))
        # The old once-per-company rule stopped at Revenues and lost FY2025.
        self.assertEqual(sorted(sec.duration_values(facts, sec.TAGS["revenue"])), [2023, 2024, 2025])

    def test_instant_entries_fill_dates_per_tag_and_keep_latest_filed(self):
        facts = {"facts": {"us-gaap": {
            "LongTermDebtCurrent": {"units": {"USD": [_instant(10e6, "2024-12-31", filed="2025-02-01")]}},
            "DebtCurrent": {"units": {"USD": [
                _instant(99e6, "2024-12-31", filed="2025-02-01"),
                _instant(20e6, "2025-12-31", filed="2026-02-01"),
                _instant(21e6, "2025-12-31", filed="2026-03-01"),  # restated
                _instant(5e6, "2026-06-30", form="10-Q", fp="Q2", filed="2026-08-01"),
            ]}},
        }}}
        entries = sec.instant_entries(facts, sec.INSTANT_TAGS["debt_current"])
        self.assertEqual(entries[date(2024, 12, 31)]["value"], 10e6)
        self.assertEqual(entries[date(2025, 12, 31)]["value"], 21e6)
        self.assertNotIn(date(2026, 6, 30), entries)               # 10-K, FY only by default
        quarterly = sec.instant_entries(facts, sec.INSTANT_TAGS["debt_current"],
                                        forms=sec.BALANCE_FORMS, fiscal_year_only=False)
        self.assertEqual(quarterly[date(2026, 6, 30)]["form"], "10-Q")
        self.assertEqual(sec.instant_values(facts, sec.INSTANT_TAGS["debt_current"]), {2024: 10e6, 2025: 21e6})

    def test_instant_values_take_the_latest_date_in_a_fiscal_year(self):
        facts = {"facts": {"us-gaap": {"AssetsCurrent": {"units": {"USD": [
            _instant(7e6, "2026-01-02"), _instant(6e6, "2025-06-30"),
        ]}}}}}
        self.assertEqual(sec.instant_values(facts, ("AssetsCurrent",)), {2025: 7e6})

    def test_new_instant_tag_groups(self):
        self.assertEqual(sec.INSTANT_TAGS["debt_total"][0], "LongTermDebt")
        self.assertIn("DebtInstrumentCarryingAmount", sec.INSTANT_TAGS["debt_total"])
        self.assertEqual(sec.INSTANT_TAGS["minority_interest"], ("MinorityInterest",))
        self.assertEqual(sec.INSTANT_TAGS["preferred_equity"], ("PreferredStockValue", "PreferredStockCarryingAmount"))
        self.assertIn("Cash", sec.INSTANT_TAGS["cash"])


class LatestBalanceSheetTests(unittest.TestCase):
    """Audit item 11: the EV bridge uses the newest 10-K/10-Q balance sheet."""

    def test_newest_quarter_wins_and_every_line_is_read_at_that_date(self):
        facts = facts_fixture()
        gaap = facts["facts"]["us-gaap"]
        q = dict(form="10-Q", fp="Q2", filed="2026-08-01")
        gaap["CashAndCashEquivalentsAtCarryingValue"]["units"]["USD"].append(_instant(700e6, "2026-06-30", **q))
        gaap["LongTermDebtCurrent"]["units"]["USD"].append(_instant(50e6, "2026-06-30", **q))
        gaap["LongTermDebtNoncurrent"]["units"]["USD"].append(_instant(1_400e6, "2026-06-30", **q))
        gaap["ShortTermInvestments"] = {"units": {"USD": [_instant(100e6, "2026-06-30", **q)]}}
        gaap["MinorityInterest"] = {"units": {"USD": [_instant(12.34e6, "2026-06-30", **q)]}}
        sheet = sec.latest_balance_sheet(facts)
        self.assertEqual(sheet["as_of"], "2026-06-30")
        self.assertEqual(sheet["form"], "10-Q")
        self.assertEqual(sheet["gross_debt"], 1450.0)
        self.assertEqual(sheet["net_debt"], 650.0)          # 50 + 1400 - 700 - 100
        self.assertEqual(sheet["minority_interest"], 12.3)
        self.assertEqual(sheet["preferred_equity"], 0.0)
        self.assertIsNone(sheet["debt_total"])
        self.assertIsNone(sheet["debt_note"])

    def test_fixture_year_end_sheet(self):
        sheet = sec.latest_balance_sheet(facts_fixture())
        self.assertEqual((sheet["as_of"], sheet["form"], sheet["net_debt"]), ("2025-12-31", "10-K", 250.0))

    def test_total_debt_tag_when_no_split_lines(self):
        facts = {"facts": {"us-gaap": {
            "CashAndCashEquivalentsAtCarryingValue": {"units": {"USD": [_instant(100e6, "2025-12-31")]}},
            "LongTermDebt": {"units": {"USD": [_instant(400e6, "2025-12-31")]}},
            "PreferredStockValue": {"units": {"USD": [_instant(25e6, "2025-12-31")]}},
        }}}
        sheet = sec.latest_balance_sheet(facts)
        self.assertEqual((sheet["gross_debt"], sheet["debt_total"], sheet["net_debt"]), (400.0, 400.0, 300.0))
        self.assertEqual(sheet["preferred_equity"], 25.0)
        self.assertIsNone(sheet["debt_current"])

    def test_no_debt_line_is_zero_with_a_note(self):
        facts = {"facts": {"us-gaap": {
            "Cash": {"units": {"USD": [_instant(80e6, "2025-12-31")]}},
            # A debt line at another date must not be borrowed.
            "LongTermDebtNoncurrent": {"units": {"USD": [_instant(500e6, "2024-12-31", filed="2025-02-01")]}},
        }}}
        sheet = sec.latest_balance_sheet(facts)
        self.assertEqual((sheet["gross_debt"], sheet["net_debt"]), (0.0, -80.0))
        self.assertEqual(sheet["debt_note"], "No debt line tagged at 2025-12-31; gross debt taken as zero.")

    def test_no_cash_means_no_sheet(self):
        self.assertIsNone(sec.latest_balance_sheet({"facts": {"us-gaap": {}}}))


class ShareCountTests(unittest.TestCase):
    """Audit item 15: weighted diluted only when current and on the cover's scale."""

    def _with_diluted(self, *entries, cover=True):
        facts = facts_fixture()
        if not cover:
            facts["facts"]["dei"] = {}
        facts["facts"]["us-gaap"]["WeightedAverageNumberOfDilutedSharesOutstanding"] = {"units": {"shares": list(entries)}}
        return facts

    def test_weighted_diluted_from_latest_year_is_used(self):
        facts = self._with_diluted(_fact(46_320_000, "2025-01-01", "2025-12-31"),
                                   _fact(45_000_000, "2024-01-01", "2024-12-31", filed="2025-02-20"))
        self.assertEqual(sec.shares(facts), {"diluted": 46_320_000, "basic": 43_790_000,
                                             "basis": "weighted_diluted", "fallback_reason": None})
        self.assertEqual(sec.shares_outstanding(facts), 46_320_000)

    def test_stale_weighted_count_falls_back_to_cover(self):
        facts = self._with_diluted(_fact(44_000_000, "2024-01-01", "2024-12-31", filed="2025-02-20"))
        result = sec.shares(facts)
        self.assertEqual((result["diluted"], result["basis"]), (43_790_000, "cover_page"))
        self.assertEqual(result["fallback_reason"], "diluted count is from FY2024, revenue runs to FY2025")

    def test_off_scale_weighted_count_falls_back_to_cover(self):
        facts = self._with_diluted(_fact(716, "2025-01-01", "2025-12-31"))   # tagged in millions
        result = sec.shares(facts)
        self.assertEqual((result["diluted"], result["basis"]), (43_790_000, "cover_page"))
        self.assertEqual(result["fallback_reason"], "diluted count 716 is off-scale against the cover page 43790000")

    def test_zero_cover_is_none_and_weighted_stands_alone(self):
        facts = self._with_diluted(_fact(33_000_000, "2025-01-01", "2025-12-31"))
        facts["facts"]["dei"]["EntityCommonStockSharesOutstanding"]["units"]["shares"] = [_instant(0, "2026-07-30")]
        self.assertEqual(sec.shares(facts), {"diluted": 33_000_000, "basic": None,
                                             "basis": "weighted_diluted", "fallback_reason": None})

    def test_nothing_tagged(self):
        facts = {"facts": {"us-gaap": {}}}
        self.assertEqual(sec.shares(facts), {"diluted": None, "basic": None, "basis": "none", "fallback_reason": None})


class LtmTests(unittest.TestCase):
    """Audit item 12: FY + current YTD − prior YTD from the latest 10-Q."""

    def test_ltm_row_rolls_each_flow(self):
        rows = sec.build_financials(ltm_fixture())
        self.assertEqual([(r["fiscal_year"], r["period_type"]) for r in rows], [(2024, "FY"), (2025, "FY"), (2025, "LTM")])
        ltm = rows[-1]
        # Hand-checked against the FY2025 row (2400 / 300 / 60 / 150 / 3.50 / 30):
        self.assertEqual(ltm["period_end"], "2026-06-30")
        self.assertEqual(ltm["revenue"], 2550.0)      # 2400 + (1300 - 1150); NOT 2400 + 700 - ...
        self.assertEqual(ltm["ebit"], 330.0)          # 300 + (170 - 140)
        self.assertEqual(ltm["dep_amort"], 60.0)      # no YTD D&A tagged -> FY figure
        self.assertEqual(ltm["ebitda"], 390.0)
        self.assertEqual(ltm["net_income"], 170.0)    # 150 + (90 - 70)
        self.assertEqual(ltm["eps"], 3.9)             # 3.50 + (2.10 - 1.70)
        self.assertEqual(ltm["capex"], 34.0)          # 30 + (18 - 14)
        self.assertIsNone(ltm["nwc_change"])
        self.assertEqual(ltm["tax_rate"], 0.2)
        self.assertEqual(ltm["is_estimate"], 0)

    def test_ytd_d_and_a_is_rolled_when_tagged(self):
        facts = ltm_fixture()
        facts["facts"]["us-gaap"]["DepreciationDepletionAndAmortization"]["units"]["USD"] += [
            _q(34e6, "2026-01-01", "2026-06-30"), _q(29e6, "2025-01-01", "2025-06-30")]
        ltm = sec.build_financials(facts)[-1]
        self.assertEqual((ltm["dep_amort"], ltm["ebitda"]), (65.0, 395.0))

    def test_no_prior_year_comparable_means_no_ltm(self):
        facts = ltm_fixture()
        revenue = facts["facts"]["us-gaap"]["RevenueFromContractWithCustomerExcludingAssessedTax"]["units"]["USD"]
        revenue[:] = [e for e in revenue if e["end"] != "2025-06-30"]
        self.assertEqual([r["period_type"] for r in sec.build_financials(facts)], ["FY", "FY"])

    def test_latest_ytd_spans(self):
        facts = {"facts": {"us-gaap": {"Revenues": {"units": {"USD": [
            _q(300, "2026-01-01", "2026-03-31", fp="Q1"), _q(280, "2025-01-01", "2025-03-31", fp="Q1"),
            _q(950, "2026-01-01", "2026-09-30", fp="Q3", filed="2026-11-01"),
            _q(900, "2025-01-01", "2025-09-30", fp="Q3", filed="2026-11-01"),
            _q(999, "2026-01-01", "2026-12-31", fp="Q3", filed="2026-11-01"),   # a year-long span is not YTD
        ]}}}}}
        found = sec.latest_ytd(facts, ("Revenues",), after=date(2025, 12, 31))
        self.assertEqual((found["quarter"], found["value"], found["prior_value"]), (3, 950.0, 900.0))
        self.assertEqual(found["period_end"], date(2026, 9, 30))
        pinned = sec.latest_ytd(facts, ("Revenues",), after=date(2025, 12, 31), period_end=date(2026, 3, 31))
        self.assertEqual((pinned["quarter"], pinned["prior_value"]), (1, 280.0))
        self.assertIsNone(sec.latest_ytd(facts, ("Revenues",), after=date(2026, 9, 30)))

    def test_sub_line_revenue_tag_yields_to_the_total_in_fy_and_ltm(self):
        # Charter (ported from Rails bcf843e): 889m of one revenue stream under
        # the preferred contract-revenue tag, the 55bn total under Revenues.
        # Before the fix the FY row read 889 and the LTM rolled the Revenues
        # YTD onto it: 889 + (27123 - 27501) = 511.
        facts = facts_fixture()
        gaap = facts["facts"]["us-gaap"]
        gaap["RevenueFromContractWithCustomerExcludingAssessedTax"] = {"units": {"USD": [
            _fact(889e6, "2025-01-01", "2025-12-31"),
            _q(220e6, "2026-01-01", "2026-06-30"),
            _q(210e6, "2025-01-01", "2025-06-30"),
        ]}}
        gaap["Revenues"] = {"units": {"USD": [
            _fact(55_000e6, "2025-01-01", "2025-12-31"),
            _fact(2_000e6, "2024-01-01", "2024-12-31", filed="2025-02-20"),
            _q(27_123e6, "2026-01-01", "2026-06-30"),
            _q(27_501e6, "2025-01-01", "2025-06-30"),
        ]}}
        rows = sec.build_financials(facts)
        fy = next(r for r in rows if r["fiscal_year"] == 2025 and r["period_type"] == "FY")
        self.assertEqual(fy["revenue"], 55_000.0)          # 889 < 0.2 x 55,000 -> sub-line
        ltm = next(r for r in rows if r["period_type"] == "LTM")
        self.assertEqual(ltm["revenue"], 54_622.0)         # 55,000 + 27,123 - 27,501, on the FY's own tag
        guarded = sec.duration_entries(facts, sec.TAGS["revenue"], sub_line_guard=True)
        self.assertEqual(guarded[2025]["tag"], "Revenues")
        self.assertEqual(sec.duration_entries(facts, sec.TAGS["revenue"])[2025]["tag"],
                         "RevenueFromContractWithCustomerExcludingAssessedTax")  # no guard: preference wins

    def test_ltm_tries_the_fiscal_year_tag_first(self):
        facts = ltm_fixture()
        # A preferred tag with a YTD but no FY figure must not displace the FY's own tag.
        facts["facts"]["us-gaap"]["NetIncomeLoss"]["units"]["USD"] = [
            e for e in facts["facts"]["us-gaap"]["NetIncomeLoss"]["units"]["USD"] if e["form"] == "10-Q"]
        facts["facts"]["us-gaap"]["ProfitLoss"] = {"units": {"USD": [
            _fact(155e6, "2025-01-01", "2025-12-31"),
            _q(95e6, "2026-01-01", "2026-06-30"), _q(80e6, "2025-01-01", "2025-06-30")]}}
        ltm = sec.build_financials(facts)[-1]
        self.assertEqual(ltm["net_income"], 170.0)         # 155 + (95 - 80) on ProfitLoss; NOT 155 + (90 - 70)

    def test_leap_day_comparable(self):
        self.assertEqual(sec._year_earlier(date(2024, 2, 29)), date(2023, 2, 28))


def old_schema_text():
    """The schema as first released: the inline UNIQUE (company_id, fiscal_year)
    and none of the audit columns. Rebuilt from today's text so the rest of
    the database is exactly what an old install has."""
    schema = db.SCHEMA
    for _table, additions in db.ADDED_COLUMNS.items():
        for name, _decl in additions:
            lines = [line for line in schema.splitlines() if not line.strip().startswith(name + " ")]
            schema = "\n".join(lines)
    old = schema.replace("UNIQUE (company_id, fiscal_year, period_type)", "UNIQUE (company_id, fiscal_year)")
    assert "period_type" not in old and "net_debt_as_of" not in old
    return old


class MigrationTests(unittest.TestCase):
    def _old_database(self, path):
        conn = sqlite3.connect(str(path))
        conn.executescript(old_schema_text())
        conn.execute("INSERT INTO companies (id, ticker, name) VALUES (1, 'OLD', 'Old Co')")
        conn.execute("INSERT INTO financials (id, company_id, fiscal_year, revenue) VALUES (7, 1, 2024, 100.0)")
        conn.execute("INSERT INTO financials (id, company_id, fiscal_year, revenue, is_estimate) VALUES (8, 1, 2025, 120.0, 1)")
        conn.execute("INSERT INTO market_data (company_id, share_price, net_debt) VALUES (1, 10.0, 5.0)")
        conn.commit()
        conn.close()

    def test_old_database_is_rebuilt_once_and_keeps_its_rows(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "old.db"
            self._old_database(path)
            conn = db.open_db(path)
            self.addCleanup(conn.close)
            cols = [r[1] for r in conn.execute("PRAGMA table_info(financials)")]
            for name in ("period_type", "period_end", "estimate_source"):
                self.assertIn(name, cols)
            md_cols = [r[1] for r in conn.execute("PRAGMA table_info(market_data)")]
            for name in ("shares_basic", "net_debt_as_of", "balance_sheet_form", "minority_interest",
                         "preferred_equity", "debt_note"):
                self.assertIn(name, md_cols)
            rows = db.query(conn, "SELECT id, fiscal_year, revenue, is_estimate, period_type FROM financials ORDER BY id")
            self.assertEqual(rows, [
                {"id": 7, "fiscal_year": 2024, "revenue": 100.0, "is_estimate": 0, "period_type": "FY"},
                {"id": 8, "fiscal_year": 2025, "revenue": 120.0, "is_estimate": 1, "period_type": "FY"},
            ])
            self.assertEqual(db.scalar(conn, "SELECT net_debt FROM market_data"), 5.0)
            keys = db._unique_keys(conn, "financials")
            self.assertIn(db.FINANCIALS_KEY, keys)
            self.assertNotIn(("company_id", "fiscal_year"), keys)
            # An LTM row may now share a fiscal year; a second FY row may not.
            db.insert(conn, "financials", {"company_id": 1, "fiscal_year": 2024, "period_type": "LTM", "revenue": 110.0})
            with self.assertRaises(sqlite3.IntegrityError):
                db.insert(conn, "financials", {"company_id": 1, "fiscal_year": 2024, "revenue": 1.0})
            conn.commit()
            # Idempotent: reopening changes nothing.
            again = db.open_db(path)
            self.addCleanup(again.close)
            self.assertEqual(db.scalar(again, "SELECT COUNT(*) FROM financials"), 3)
            self.assertEqual(db._unique_keys(again, "financials").count(db.FINANCIALS_KEY), 1)
            # The foreign key survived the rebuild.
            again.execute("DELETE FROM companies WHERE id = 1")
            self.assertEqual(db.scalar(again, "SELECT COUNT(*) FROM financials"), 0)

    def test_connect_alone_migrates(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "old.db"
            self._old_database(path)
            conn = db.connect(path)
            self.addCleanup(conn.close)
            self.assertIn("period_type", [r[1] for r in conn.execute("PRAGMA table_info(financials)")])

    def test_failed_rebuild_leaves_old_table(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "old.db"
            self._old_database(path)
            conn = sqlite3.connect(str(path))
            self.addCleanup(conn.close)
            with mock.patch.object(db, "_financials_ddl", return_value="CREATE TABLE IF NOT EXISTS financials (oops"):
                with self.assertRaises(sqlite3.Error):
                    db.migrate(conn)
            self.assertIn(("company_id", "fiscal_year"), db._unique_keys(conn, "financials"))
            self.assertEqual(conn.execute("SELECT COUNT(*) FROM financials").fetchone()[0], 2)
            self.assertIsNone(conn.execute(
                "SELECT name FROM sqlite_master WHERE name = 'financials_rebuild'").fetchone())

    def test_fresh_database_has_the_new_key(self):
        conn = empty_connection()
        self.addCleanup(conn.close)
        self.assertIn(db.FINANCIALS_KEY, db._unique_keys(conn, "financials"))
        self.assertNotIn(("company_id", "fiscal_year"), db._unique_keys(conn, "financials"))


def summary_payload():
    """The shape of a real quoteSummary answer (ITRI, October 2026), trimmed."""
    def trend(period, end, revenue, eps, analysts):
        return {"period": period, "endDate": end,
                "revenueEstimate": {"avg": {"raw": revenue, "fmt": "x"}, "numberOfAnalysts": {"raw": analysts}},
                "earningsEstimate": {"avg": {"raw": eps}, "numberOfAnalysts": {"raw": analysts}}}
    return {"quoteSummary": {"error": None, "result": [{
        "earningsTrend": {"trend": [
            {"period": "0q", "endDate": "2026-09-30", "revenueEstimate": {"avg": {"raw": 6e8}}},
            trend("0y", "2026-12-31", 2388120370, 6.41503, 9),
            trend("+1y", "2027-12-31", 2553173750, 6.99504, 1),
        ]},
        "defaultKeyStatistics": {"beta": {"raw": 1.321, "fmt": "1.32"}},
    }]}}


class _FakeResponse:
    def __init__(self, body: bytes):
        self.body, self.headers = body, {}

    def read(self):
        return self.body

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


class _FakeOpener:
    """Stands in for the cookie-jar opener; records every request it sees."""

    def __init__(self, crumb=b"ab/c+d=", summary=None):
        self.crumb, self.summary, self.requests = crumb, summary or summary_payload(), []

    def open(self, request, timeout=None):
        self.requests.append(request)
        url = request.full_url
        if url == market.COOKIE_URL:
            raise urllib.error.HTTPError(url, 404, "Not Found", {}, None)
        if url == market.CRUMB_URL:
            return _FakeResponse(self.crumb)
        return _FakeResponse(json.dumps(self.summary).encode())


class EstimatesTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        patcher = mock.patch.object(argos_http, "CACHE_DIR", Path(tmp.name))
        patcher.start()
        self.addCleanup(patcher.stop)
        self.cache_dir = Path(tmp.name)
        throttle = mock.patch.object(argos_http, "_throttle", lambda: None)
        throttle.start()
        self.addCleanup(throttle.stop)

    def test_parse_matches_the_live_payload_shape(self):
        parsed = market.parse_estimates(summary_payload(), on=date(2026, 10, 17))
        self.assertEqual(parsed, {
            "estimates": [
                {"fiscal_year": 2026, "period_end": "2026-12-31", "revenue": 2388.1, "eps": 6.42,
                 "analysts": 9, "source": "consensus (Yahoo Finance, 9 analysts)"},
                {"fiscal_year": 2027, "period_end": "2027-12-31", "revenue": 2553.2, "eps": 7.0,
                 "analysts": 1, "source": "consensus (Yahoo Finance, 1 analyst)"},
            ],
            "beta": 1.321,
            "as_of": "2026-10-17",
        })

    def test_parse_early_january_end_and_gaps(self):
        payload = {"quoteSummary": {"result": [{"earningsTrend": {"trend": [
            {"period": "0y", "endDate": "2027-01-01", "revenueEstimate": {"avg": {"raw": 1e9}, "numberOfAnalysts": {}},
             "earningsEstimate": {"avg": {}}},
            {"period": "+1y", "endDate": "2028-01-01", "revenueEstimate": {}, "earningsEstimate": {}},
        ]}, "defaultKeyStatistics": {"beta": {}}}]}}
        parsed = market.parse_estimates(payload, on=date(2026, 10, 17))
        self.assertEqual(parsed["estimates"], [{"fiscal_year": 2026, "period_end": "2027-01-01", "revenue": 1000.0,
                                                "eps": None, "analysts": None, "source": "consensus (Yahoo Finance)"}])
        self.assertIsNone(parsed["beta"])
        self.assertIsNone(market.parse_estimates({"quoteSummary": {"result": []}}))
        self.assertIsNone(market.parse_estimates({}))

    def test_crumb_flow_shares_one_cookie_jar_and_never_caches_the_crumb(self):
        opener = _FakeOpener()
        with mock.patch.object(market, "_build_opener", return_value=opener) as build:
            first = market.fetch_estimates("itri", on=date(2026, 10, 17))
            second = market.fetch_estimates("ITRI", on=date(2026, 10, 17))
        self.assertEqual(build.call_count, 1)                   # second call came from the cache
        self.assertEqual(first, second)
        self.assertEqual(first["beta"], 1.321)
        urls = [r.full_url for r in opener.requests]
        self.assertEqual(urls[:2], [market.COOKIE_URL, market.CRUMB_URL])
        self.assertEqual(urls[2], "https://query2.finance.yahoo.com/v10/finance/quoteSummary/ITRI"
                                  "?modules=earningsTrend,defaultKeyStatistics&crumb=ab%2Fc%2Bd%3D")
        for request in opener.requests:
            self.assertTrue(request.get_header("User-agent").startswith("Mozilla/5.0 (Windows"))
        cached = list(self.cache_dir.iterdir())
        self.assertEqual(len(cached), 1)
        text = cached[0].read_text()
        self.assertNotIn("ab/c+d=", text)
        self.assertNotIn("crumb", text)
        self.assertEqual(cached[0], argos_http.cache_path(market.estimates_cache_key("ITRI", on=date(2026, 10, 17)), ".json"))
        self.assertNotIn("crumb", market.estimates_cache_key("ITRI"))

    def test_a_new_day_is_a_new_cache_entry(self):
        self.assertNotEqual(market.estimates_cache_key("ITRI", on=date(2026, 10, 17)),
                            market.estimates_cache_key("ITRI", on=date(2026, 10, 18)))

    def test_failures_return_none(self):
        for opener in (_FakeOpener(crumb=b""), _FakeOpener(crumb=b"<html>Too Many Requests</html>"),
                       _FakeOpener(summary={"quoteSummary": {"result": None, "error": {"code": "Unauthorized"}}})):
            with mock.patch.object(market, "_build_opener", return_value=opener):
                self.assertIsNone(market.fetch_estimates("ITRI", cache=False))
        broken = mock.Mock()
        broken.open.side_effect = OSError("no route")
        with mock.patch.object(market, "_build_opener", return_value=broken):
            self.assertIsNone(market.fetch_estimates("ITRI"))
        self.assertEqual(list(self.cache_dir.iterdir()), [])     # failures are not cached

    def test_quote_url_carries_the_day(self):
        self.assertTrue(market.quote_url("itri", on=date(2026, 10, 17)).endswith(
            "/chart/ITRI?range=1y&interval=1d&asof=2026-10-17"))


class LoadCompanyTests(unittest.TestCase):
    """The loader writes FY, LTM and estimate rows and the dated EV bridge."""

    def _load(self, estimates, facts=None, **kwargs):
        conn = empty_connection()
        self.addCleanup(conn.close)
        facts = facts or ltm_fixture()
        facts["facts"]["us-gaap"]["WeightedAverageNumberOfDilutedSharesOutstanding"] = {
            "units": {"shares": [_fact(46_320_000, "2025-01-01", "2025-12-31")]}}
        submissions = {"name": "ITRON INC", "sicDescription": "Instruments", "sic": "3829",
                       "addresses": {"business": {"city": "Liberty Lake", "stateOrCountry": "WA"}}}
        quote = {"share_price": 101.5, "as_of": "2026-10-16", "week52_low": 80.0, "week52_high": 140.0}
        with mock.patch.object(sec, "resolve_cik", return_value="0000780571"), \
                mock.patch.object(sec, "fetch_submissions", return_value=submissions), \
                mock.patch.object(sec, "fetch_facts", return_value=facts), \
                mock.patch.object(sec, "fetch_quote", return_value=quote), \
                mock.patch.object(sec, "fetch_estimates", return_value=estimates) as fetch:
            summary = sec.load_company(conn, "itri", with_documents=False, **kwargs)
        return conn, summary, fetch

    def test_rows_market_data_and_summary(self):
        estimates = market.parse_estimates(summary_payload(), on=date(2026, 10, 17))
        conn, summary, _ = self._load(estimates)
        rows = db.query(conn, "SELECT fiscal_year, period_type, period_end, is_estimate, revenue, eps, ebitda, "
                              "estimate_source FROM financials ORDER BY fiscal_year, period_type")
        self.assertEqual([(r["fiscal_year"], r["period_type"], r["is_estimate"]) for r in rows],
                         [(2024, "FY", 0), (2025, "FY", 0), (2025, "LTM", 0), (2026, "FY", 1), (2027, "FY", 1)])
        self.assertEqual(rows[2]["period_end"], "2026-06-30")
        self.assertEqual(rows[3], {"fiscal_year": 2026, "period_type": "FY", "period_end": "2026-12-31",
                                   "is_estimate": 1, "revenue": 2388.1, "eps": 6.42, "ebitda": None,
                                   "estimate_source": "consensus (Yahoo Finance, 9 analysts)"})
        md = db.query_one(conn, "SELECT * FROM market_data")
        self.assertEqual(md["shares_diluted"], 46.32)            # weighted diluted (audit item 15)
        self.assertEqual(md["shares_basic"], 43.79)              # cover page
        self.assertEqual((md["net_debt"], md["net_debt_as_of"], md["balance_sheet_form"]), (250.0, "2025-12-31", "10-K"))
        self.assertEqual((md["minority_interest"], md["preferred_equity"], md["debt_note"]), (0.0, 0.0, None))
        self.assertEqual(md["beta"], 1.321)
        self.assertEqual(summary["fiscal_years"], [2024, 2025])  # FY rows only
        self.assertEqual(summary["latest_revenue"], 2400.0)
        self.assertEqual(summary["ltm_period_end"], "2026-06-30")
        self.assertEqual(summary["shares_basis"], "weighted_diluted")
        self.assertEqual(summary["net_debt_as_of"], "2025-12-31")
        self.assertEqual(summary["estimate_years"], [2026, 2027])
        self.assertEqual(summary["quote_as_of"], "2026-10-16")

    def test_missing_estimates_never_sink_the_load(self):
        conn, summary, _ = self._load(None)
        self.assertEqual(db.scalar(conn, "SELECT COUNT(*) FROM financials WHERE is_estimate = 1"), 0)
        self.assertIsNone(db.scalar(conn, "SELECT beta FROM market_data"))
        self.assertEqual(summary["estimate_years"], [])

    def test_estimate_for_a_reported_year_is_skipped(self):
        estimates = {"estimates": [{"fiscal_year": 2025, "period_end": "2025-12-31", "revenue": 1.0, "eps": 1.0,
                                    "analysts": 3, "source": "consensus (Yahoo Finance, 3 analysts)"}],
                     "beta": None, "as_of": "2026-01-05"}
        conn, summary, _ = self._load(estimates)
        self.assertEqual(db.scalar(conn, "SELECT revenue FROM financials WHERE fiscal_year = 2025 AND period_type = 'FY'"),
                         2400.0)
        self.assertEqual(summary["estimate_years"], [])

    def test_with_estimates_false_does_not_fetch(self):
        _, _, fetch = self._load(None, with_estimates=False)
        fetch.assert_not_called()


if __name__ == "__main__":
    unittest.main()
