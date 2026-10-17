import re
import unittest
from datetime import date
from html import unescape

from argos import __version__, pitchbook
from argos.exporters import render_deck_body
from tests.support import seeded_connection


def _all_strings(value):
    """Every string inside a payload, at any depth."""
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for item in value.values():
            yield from _all_strings(item)
    elif isinstance(value, (list, tuple)):
        for item in value:
            yield from _all_strings(item)


PROSE_KEYS = {"text", "note", "narrative", "rationale", "conclusion_note", "bullets", "footnotes", "wacc_notes", "body"}


def _prose(slides):
    """The sentences a deck prints: titles, subtitles and the prose payload keys."""
    out = []
    for slide in slides:
        out += [slide.get("title") or "", slide.get("subtitle") or ""]

        def walk(value, key=None):
            if isinstance(value, dict):
                for k, v in value.items():
                    walk(v, k)
            elif isinstance(value, list):
                for item in value:
                    walk(item, key)
            elif isinstance(value, str) and key in PROSE_KEYS:
                out.append(value)

        walk(slide["payload"])
    return out


def _html_prose(markup):
    """Text of every paragraph and list item in rendered slide markup."""
    return [unescape(re.sub(r"<[^>]+>", "", m)) for _, m in re.findall(r"<(p|li)(?:\s[^>]*)?>(.*?)</\1>", markup, re.S)]


class CreationTests(unittest.TestCase):
    def setUp(self):
        self.conn = seeded_connection()
        self.book_id = pitchbook.create_pitchbook(
            self.conn, title="Project Lighthouse", target_ticker="NVG",
            client_name="Board of NovaGrid Systems", banker="Argos Advisory",
        )

    def test_every_standard_slide_is_generated_in_order(self):
        slides = pitchbook.get_slides(self.conn, self.book_id)
        self.assertEqual([slide["kind"] for slide in slides], [kind for kind, _ in pitchbook.SLIDE_ORDER])
        self.assertEqual([slide["seq"] for slide in slides], list(range(len(slides))))

    def test_comps_are_suggested_when_not_supplied(self):
        comps = pitchbook.comp_tickers_for(self.conn, self.book_id)
        self.assertTrue(comps)
        self.assertNotIn("NVG", comps)

    def test_unknown_target_is_rejected(self):
        with self.assertRaises(ValueError):
            pitchbook.create_pitchbook(self.conn, title="X", target_ticker="NOPE")

    def test_executive_summary_cites_the_corpus(self):
        summary = self._slide("executive_summary")
        cited = [bullet for bullet in summary["payload"]["bullets"] if bullet.get("source")]
        self.assertTrue(cited, "executive summary should quote the research corpus")
        self.assertTrue(all(bullet["source"]["document_id"] for bullet in cited))

    def test_valuation_slide_matches_the_valuation_engine(self):
        payload = self._slide("valuation_summary")["payload"]
        self.assertTrue(payload["ranges"])
        self.assertGreater(payload["reference_price"], 0)
        self.assertLess(payload["concluded_range"]["low"], payload["concluded_range"]["high"])

    def test_trading_comps_slide_flags_the_target_row(self):
        payload = self._slide("trading_comps")["payload"]
        self.assertTrue(payload["target"]["is_target"])
        self.assertNotIn("NVG", [row["ticker"] for row in payload["rows"]])

    def test_dcf_slide_carries_projections_and_assumptions(self):
        payload = self._slide("dcf")["payload"]
        self.assertTrue(payload["projections"])
        self.assertIn("wacc", payload["assumptions"])
        self.assertAlmostEqual(
            payload["enterprise_value"], payload["pv_explicit"] + payload["pv_terminal"], places=0
        )

    def test_market_overview_uses_trending_themes(self):
        payload = self._slide("market_overview")["payload"]
        self.assertTrue(payload["themes"])
        self.assertTrue(payload["narrative"])

    def test_buyers_slide_ranks_counterparties(self):
        candidates = self._slide("buyers")["payload"]["candidates"]
        self.assertTrue(candidates)
        self.assertTrue(any(row["type"] == "Sponsor" for row in candidates))
        self.assertTrue(all(row["rationale"] for row in candidates))

    def _slide(self, kind):
        return next(s for s in pitchbook.get_slides(self.conn, self.book_id) if s["kind"] == kind)


class EditingTests(unittest.TestCase):
    def setUp(self):
        self.conn = seeded_connection()
        self.book_id = pitchbook.create_pitchbook(self.conn, title="Project Edit", target_ticker="NVG")

    def test_editing_a_slide_pins_it(self):
        slide = pitchbook.get_slides(self.conn, self.book_id)[2]
        updated = pitchbook.update_slide(self.conn, slide["id"], title="Our view")
        self.assertEqual(updated["title"], "Our view")
        self.assertTrue(updated["is_pinned"])

    def test_pinned_slides_survive_a_rebuild(self):
        slide = next(s for s in pitchbook.get_slides(self.conn, self.book_id) if s["kind"] == "executive_summary")
        pitchbook.update_slide(self.conn, slide["id"], title="Hand-written summary")
        pitchbook.rebuild_slides(self.conn, self.book_id)
        rebuilt = next(s for s in pitchbook.get_slides(self.conn, self.book_id) if s["kind"] == "executive_summary")
        self.assertEqual(rebuilt["title"], "Hand-written summary")

    def test_unpinned_slides_are_regenerated(self):
        slide = next(s for s in pitchbook.get_slides(self.conn, self.book_id) if s["kind"] == "process")
        pitchbook.update_slide(self.conn, slide["id"], title="Temporary", pin=False)
        pitchbook.rebuild_slides(self.conn, self.book_id)
        rebuilt = next(s for s in pitchbook.get_slides(self.conn, self.book_id) if s["kind"] == "process")
        self.assertNotEqual(rebuilt["title"], "Temporary")

    def test_missing_slide_returns_none(self):
        self.assertIsNone(pitchbook.update_slide(self.conn, 10 ** 7, title="x"))

    def test_reorder(self):
        slides = pitchbook.get_slides(self.conn, self.book_id)
        reversed_ids = [slide["id"] for slide in reversed(slides)]
        reordered = pitchbook.reorder_slides(self.conn, self.book_id, reversed_ids)
        self.assertEqual([slide["id"] for slide in reordered], reversed_ids)

    def test_changing_comps_rebuilds_the_valuation(self):
        before = next(s for s in pitchbook.get_slides(self.conn, self.book_id) if s["kind"] == "trading_comps")
        pitchbook.set_comps(self.conn, self.book_id, ["TWSW", "MFCL"])
        after = next(s for s in pitchbook.get_slides(self.conn, self.book_id) if s["kind"] == "trading_comps")
        self.assertEqual({row["ticker"] for row in after["payload"]["rows"]}, {"TWSW", "MFCL"})
        self.assertNotEqual(before["payload"]["stats"], after["payload"]["stats"])

    def test_assumptions_are_merged_and_applied(self):
        merged = pitchbook.set_assumptions(self.conn, self.book_id, {"wacc": 0.14})
        self.assertAlmostEqual(merged["wacc"], 0.14)
        payload = next(s for s in pitchbook.get_slides(self.conn, self.book_id) if s["kind"] == "dcf")["payload"]
        self.assertAlmostEqual(payload["assumptions"]["wacc"], 0.14)

    def test_delete(self):
        self.assertTrue(pitchbook.delete_pitchbook(self.conn, self.book_id))
        self.assertIsNone(pitchbook.get_pitchbook(self.conn, self.book_id))
        self.assertEqual(pitchbook.get_slides(self.conn, self.book_id), [])


class EvidenceTests(unittest.TestCase):
    def setUp(self):
        self.conn = seeded_connection()
        self.book_id = pitchbook.create_pitchbook(self.conn, title="Project Evidence", target_ticker="NVG")
        self.chunk = self.conn.execute(
            "SELECT id, document_id, text FROM chunks WHERE length(text) > 120 LIMIT 1"
        ).fetchone()

    def test_pinning_updates_the_appendix(self):
        pitchbook.add_evidence(
            self.conn, self.book_id, quote=self.chunk["text"],
            document_id=self.chunk["document_id"], chunk_id=self.chunk["id"], note="Diligence item",
        )
        appendix = next(s for s in pitchbook.get_slides(self.conn, self.book_id) if s["kind"] == "evidence_appendix")
        items = appendix["payload"]["items"]
        self.assertEqual(len(items), 1)
        self.assertEqual(items[0]["document_id"], self.chunk["document_id"])
        self.assertEqual(items[0]["note"], "Diligence item")

    def test_quote_is_recovered_from_the_chunk(self):
        evidence = pitchbook.add_evidence(self.conn, self.book_id, quote="", chunk_id=self.chunk["id"])
        self.assertTrue(evidence["quote"])
        self.assertEqual(evidence["document_id"], self.chunk["document_id"])

    def test_empty_evidence_is_rejected(self):
        with self.assertRaises(ValueError):
            pitchbook.add_evidence(self.conn, self.book_id, quote="   ")

    def test_delete_evidence_updates_the_appendix(self):
        evidence = pitchbook.add_evidence(self.conn, self.book_id, quote="Churn ticked up.", document_id=self.chunk["document_id"])
        self.assertTrue(pitchbook.delete_evidence(self.conn, evidence["id"]))
        appendix = next(s for s in pitchbook.get_slides(self.conn, self.book_id) if s["kind"] == "evidence_appendix")
        self.assertEqual(appendix["payload"]["items"], [])
        self.assertFalse(pitchbook.delete_evidence(self.conn, evidence["id"]))

    def test_evidence_is_removed_with_the_deck(self):
        pitchbook.add_evidence(self.conn, self.book_id, quote="Churn ticked up.", document_id=self.chunk["document_id"])
        pitchbook.delete_pitchbook(self.conn, self.book_id)
        remaining = self.conn.execute(
            "SELECT COUNT(*) FROM evidence WHERE pitchbook_id = ?", (self.book_id,)
        ).fetchone()[0]
        self.assertEqual(remaining, 0)


class AuditFindingTests(unittest.TestCase):
    """Slide prose and payloads after the October 2026 audit (docs/AUDIT.md;
    docs/RAILS_PORT.md items 7 and 16-22). Numbers are hand-checked against the
    demo seed: every company's latest fiscal year is FY2026, prices are dated
    2026-10-09 and the target's newest document is dated 2026-08-19."""

    def setUp(self):
        self.conn = seeded_connection()

    def tearDown(self):
        self.conn.close()

    def _deck(self, ticker, **kwargs):
        book_id = pitchbook.create_pitchbook(self.conn, title="Project Audit", target_ticker=ticker, **kwargs)
        return book_id, pitchbook.get_slides(self.conn, book_id)

    @staticmethod
    def _kind(slides, kind):
        return next(s for s in slides if s["kind"] == kind)

    # (a) executive summary ------------------------------------------------

    def test_lowest_margin_target_renders_below_the_peer_median_with_numbers(self):
        # MFCL has the lowest FY2026 EBITDA margin in the seed (532.8 / 3,080 =
        # 17.3%). Its six peers' margins are 18.4, 19.6, 22.1, 23.8, 26.2 and
        # 28.1%, so the median is (22.1 + 23.8) / 2 = 22.95%, which formats as
        # 22.9% (0.2295 is stored just below the half). Replaces the fixed 0.22
        # threshold, which called every margin under 22% "in line".
        _, slides = self._deck("MFCL")
        payload = self._kind(slides, "executive_summary")["payload"]
        texts = [b["text"] for b in payload["bullets"]]
        self.assertTrue(any(
            "17.3% EBITDA margin is below the peer median of 22.9% across 6 peers" in t for t in texts
        ), texts)
        self.assertEqual(payload["margin_position"], "below")
        self.assertAlmostEqual(payload["peer_median_margin"], 0.2295, places=4)

    def test_highest_margin_target_is_above_the_peer_median(self):
        # NVG 26.2% against peers 17.3, 18.4, 19.6, 22.1, 23.8, 28.1%:
        # median (19.6 + 22.1) / 2 = 20.85% -> "20.9%".
        _, slides = self._deck("NVG")
        texts = [b["text"] for b in self._kind(slides, "executive_summary")["payload"]["bullets"]]
        self.assertTrue(any("26.2% EBITDA margin is above the peer median of 20.9%" in t for t in texts), texts)

    def test_margin_position_bands(self):
        self.assertEqual(pitchbook.margin_position(0.25, 0.23), "in line with")   # exactly 2 points
        self.assertEqual(pitchbook.margin_position(0.211, 0.23), "in line with")
        self.assertEqual(pitchbook.margin_position(0.2501, 0.23), "above")
        self.assertEqual(pitchbook.margin_position(0.20, 0.23), "below")
        self.assertIsNone(pitchbook.margin_position(None, 0.23))
        self.assertIsNone(pitchbook.margin_position(0.2, None))

    def test_executive_summary_states_the_range_without_a_move(self):
        _, slides = self._deck("NVG")
        payload = self._kind(slides, "executive_summary")["payload"]
        texts = " ".join(b["text"] for b in payload["bullets"])
        low, high = payload["concluded_range"]["low"], payload["concluded_range"]["high"]
        self.assertIn(
            f"implied value at peer multiples and DCF of ${low:,.2f}–${high:,.2f} per share against the current $44.10",
            texts,
        )
        self.assertNotIn("implying", texts)
        self.assertNotIn("move", texts)
        # Every multiple names its basis: 8,436.2 / 482.1 = 17.50 -> "17.5x FY2026
        # EBITDA". NTM (integration: Rails ntm_metrics blends the year in progress,
        # 22.7% FY2026 + 77.3% FY2027 = 539.9; was FY2027 alone, 556.9 -> 15.15):
        # 8,436.2 / 539.9 = 15.63, printed "15.6x" as in the comps table.
        self.assertIn("17.5x FY2026 EBITDA", texts)
        self.assertIn("15.6x NTM EBITDA", texts)

    def test_multiples_carry_the_ltm_label_when_an_ltm_row_exists(self):
        company_id = self.conn.execute("SELECT id FROM companies WHERE ticker = 'NVG'").fetchone()[0]
        self.conn.execute(
            "INSERT INTO financials (company_id, fiscal_year, period_type, period_end, is_estimate, revenue, ebitda,"
            " ebit, net_income, eps, dep_amort, capex, nwc_change, tax_rate)"
            " VALUES (?, 2026, 'LTM', '2026-06-30', 0, 1900, 500, 400, 300, 1.6, 100, 80, 20, 0.23)",
            (company_id,),
        )
        self.conn.execute(
            "UPDATE market_data SET net_debt_as_of = '2026-06-30', balance_sheet_form = '10-Q' WHERE company_id = ?",
            (company_id,),
        )
        self.conn.commit()
        _, slides = self._deck("NVG")
        texts = " ".join(b["text"] for b in self._kind(slides, "executive_summary")["payload"]["bullets"])
        # 8,436.2 / 500 = 16.87 -> "16.9x LTM Jun-26 EBITDA"; LTM margin 500 / 1,900 = 26.3%.
        self.assertIn("16.9x LTM Jun-26 EBITDA", texts)
        self.assertIn("LTM Jun-26 revenue of $1.9bn at a 26.3% EBITDA margin", texts)
        comps = self._kind(slides, "trading_comps")["payload"]
        self.assertEqual(comps["target"]["basis"], "LTM Jun-26")
        self.assertEqual(comps["target"]["balance_sheet_date"], "2026-06-30")
        # The LTM row must not plot as a second FY2026 column.
        years = [r["fiscal_year"] for r in self._kind(slides, "financial_performance")["payload"]["rows"]]
        self.assertEqual(len(years), len(set(years)))

    # (a)-(c) language bans -------------------------------------------------

    def test_upside_and_modest_never_appear_in_any_slide_text(self):
        for ticker in ("NVG", "MFCL", "PYLN"):
            book_id, slides = self._deck(ticker)
            strings = [s["title"] or "" for s in slides] + [s["subtitle"] or "" for s in slides]
            for slide in slides:
                strings += list(_all_strings(slide["payload"]))
            markup = render_deck_body(pitchbook.get_pitchbook(self.conn, book_id)).lower()
            for banned in ("upside", "modest", "subscription pricing", "accretive margin profile",
                           "emphasis rather than of subject matter"):
                self.assertFalse([t for t in strings if banned in t.lower()], (ticker, banned))
                self.assertNotIn(banned, markup, (ticker, banned))

    # (b) process slide ------------------------------------------------------

    def test_leverage_is_phrased_from_net_debt_to_ebitda_bands(self):
        # NVG 410 / 482.1 = 0.85x; MFCL 1,640 / 532.8 = 3.08x; PYLN net cash 60.
        self.assertIn("is 0.9x FY2026 EBITDA of $482m (below 1x)",
                      pitchbook.leverage_sentence(410.0, 482.1, "FY2026", "USD"))
        self.assertIn("is 3.1x FY2026 EBITDA of $533m (above 3x), which constrains incremental leverage",
                      pitchbook.leverage_sentence(1640.0, 532.8, "FY2026", "USD"))
        self.assertIn("(1–3x)", pitchbook.leverage_sentence(300.0, 150.0, "FY2026", "USD"))   # exactly 2.0x
        self.assertIn("(1–3x)", pitchbook.leverage_sentence(300.0, 100.0, "FY2026", "USD"))   # 3.0x is inclusive
        self.assertTrue(pitchbook.leverage_sentence(-60.0, 95.7, "FY2026", "USD").startswith("Net cash of $60m"))
        self.assertIn("not assessed", pitchbook.leverage_sentence(None, 95.7, "FY2026", "USD"))
        _, slides = self._deck("MFCL")
        bullets = self._kind(slides, "process")["payload"]["bullets"]
        self.assertIn("Net debt of $1.6bn is 3.1x FY2026 EBITDA of $533m (above 3x), which constrains incremental leverage.", bullets)
        self.assertTrue(any(b.startswith("Diligence focus: quality of earnings") for b in bullets))
        self.assertFalse(any("move versus" in b for b in bullets))

    # (c) counterparties -----------------------------------------------------

    def test_counterparty_rationale_uses_each_peers_numbers(self):
        _, slides = self._deck("MFCL")
        rows = {c["ticker"]: c for c in self._kind(slides, "buyers")["payload"]["candidates"]}
        # VLTR: EV 9,819.3 / 4,796.6 = 2.05x the target's, net debt 980 / 677.2 =
        # 1.4x EBITDA -> both capacity tests pass.
        self.assertTrue(rows["VLTR"]["capacity"])
        self.assertIn("EV 2.05x the target's at 1.4x net debt / EBITDA: balance-sheet capacity", rows["VLTR"]["rationale"])
        self.assertIn("EBITDA margin 28.1% vs the target's 17.3% (higher)", rows["VLTR"]["rationale"])
        self.assertIn("EV/EBITDA 14.5x (FY2026) vs the target's 9.0x (FY2026)", rows["VLTR"]["rationale"])
        # NVG is 1.76x the target's EV: below the 2x scale test, so no capacity claim.
        self.assertFalse(rows["NVG"]["capacity"])
        self.assertNotIn("balance-sheet capacity", rows["NVG"]["rationale"])
        sponsor = rows["—"]
        self.assertIn("(above 3x)", sponsor["rationale"])
        self.assertIn("median one-day premium of 28.0%", sponsor["rationale"])

    def test_capacity_requires_scale_and_leverage_below_three_turns(self):
        base = {"enterprise_value": 3000.0, "ebitda": 200.0, "ebitda_margin": 0.25, "ev_ebitda": 15.0, "basis": "FY2026"}
        kwargs = {"target_ev": 1000.0, "target_margin": 0.20, "target_multiple": 12.0, "basis_label": "FY2026"}
        levered = pitchbook.counterparty_rationale({**base, "net_debt": 700.0}, **kwargs)   # 3.5x
        self.assertFalse(levered["capacity"])
        self.assertIn("net debt / EBITDA of 3.5x limits debt funding", levered["rationale"])
        unknown = pitchbook.counterparty_rationale({**base, "net_debt": None}, **kwargs)
        self.assertIsNone(unknown["capacity"])
        self.assertIn("balance-sheet capacity not assessed (net debt unknown)", unknown["rationale"])
        cash_rich = pitchbook.counterparty_rationale({**base, "net_debt": -50.0}, **kwargs)
        self.assertTrue(cash_rich["capacity"])
        self.assertIn("at net cash", cash_rich["rationale"])

    def test_precedent_premium_sentences_need_a_median(self):
        self.conn.execute("UPDATE transactions SET premium_1day = NULL")
        self.conn.commit()
        _, slides = self._deck("NVG")
        sponsor = self._kind(slides, "buyers")["payload"]["candidates"][-1]
        self.assertIn("no precedent premium data loaded", sponsor["rationale"])
        process = self._kind(slides, "process")["payload"]["bullets"]
        self.assertFalse(any("Precedent one-day premia" in b for b in process))
        note = self._kind(slides, "precedent_transactions")["payload"]["note"]
        self.assertNotIn("n/a", note)
        self.assertIn("one-day premia are not loaded", note)

    # (d) DCF -----------------------------------------------------------------

    def test_dcf_table_includes_da_nwc_and_a_terminal_row_that_ties(self):
        book_id, slides = self._deck("NVG")
        payload = self._kind(slides, "dcf")["payload"]
        rows = payload["projection_rows"]
        self.assertTrue(rows[-1]["is_terminal"])
        self.assertEqual(rows[-1]["label"], f"Terminal ({payload['projections'][-1]['year'] + 1})")
        for row in rows:
            self.assertIn("dep_amort", row)
            self.assertIn("nwc_change", row)
            # UFCF = EBIT − taxes + D&A − capex − ΔNWC, to the 0.1m rounding of each line.
            tied = row["ebit"] - row["taxes"] + row["dep_amort"] - row["capex"] - row["nwc_change"]
            self.assertAlmostEqual(tied, row["fcf_full_year"], delta=0.31)
        for row in rows[:-1]:
            self.assertAlmostEqual(row["fcf"], row["fcf_full_year"] * row["period_fraction"], delta=0.11)
        self.assertEqual(payload["terminal_year"]["fcf"], rows[-1]["fcf"])
        self.assertEqual(payload["valuation_date"], "2026-10-09")
        self.assertIsNotNone(payload["stub_fraction"])
        self.assertIsNotNone(payload["implied_exit_multiple"])
        self.assertIsNotNone(payload["implied_terminal_growth"])
        build = payload["wacc_build"]
        for key in ("risk_free_rate", "equity_risk_premium", "beta", "cost_of_equity", "after_tax_cost_of_debt",
                    "weight_debt", "weight_equity", "wacc", "notes"):
            self.assertIn(key, build)
        markup = render_deck_body(pitchbook.get_pitchbook(self.conn, book_id))
        for header in ("D&amp;A", "ΔNWC", "UFCF (full yr)", "Terminal (", "WACC build", "Cost of equity (CAPM)",
                       "Implied exit multiple", "Stub fraction", "Valuation date"):
            self.assertIn(header, markup)

    def test_wacc_override_is_called_out(self):
        book_id, _ = self._deck("NVG")
        pitchbook.set_assumptions(self.conn, book_id, {"wacc": 0.14})
        payload = self._kind(pitchbook.get_slides(self.conn, book_id), "dcf")["payload"]
        self.assertTrue(any("14.00% set in the deck assumptions overrides" in n for n in payload["wacc_notes"]))

    # (e) valuation summary ----------------------------------------------------

    def test_valuation_summary_marks_reference_and_excluded_bars(self):
        book_id, slides = self._deck("NVG")
        payload = self._kind(slides, "valuation_summary")["payload"]
        for row in payload["ranges"]:
            for key in ("in_conclusion", "reference", "note"):
                self.assertIn(key, row)
        excluded = {e["method"] for e in payload["excluded"]}
        # The 52-week range is a reference bar; NVG's 26.2% margin is outside the
        # peer interquartile range, so EV/Revenue is shown but excluded.
        self.assertEqual(excluded, {"52-week trading range", "Trading comps — EV/Revenue"})
        self.assertNotIn("52-week trading range", payload["concluded_methods"])
        self.assertEqual(payload["basis_label"], "FY2026")
        markup = render_deck_body(pitchbook.get_pitchbook(self.conn, book_id))
        self.assertIn("52-week trading range (reference)", markup)
        self.assertIn("Trading comps — EV/Revenue (excluded)", markup)
        self.assertIn("The conclusion rests on: ", markup)

    # (f) trading comps -------------------------------------------------------

    def test_trading_comps_label_basis_dates_shares_and_ebitda_definition(self):
        book_id, slides = self._deck("NVG")
        payload = self._kind(slides, "trading_comps")["payload"]
        for row in [payload["target"], *payload["rows"]]:
            self.assertEqual(row["basis"], "FY2026")
            self.assertEqual(row["price_date"], "2026-10-09")
            self.assertIn("share_basis", row)
            self.assertIn("balance_sheet_date", row)
            self.assertIn("ev_ebitda_ntm", row)
        self.assertEqual(payload["target"]["ev_ebitda_ntm"], 15.63)  # integration: was 15.15 (FY2027-only NTM)
        self.assertIn("GAAP operating income plus depreciation and amortisation, unadjusted", payload["footnotes"][0])
        markup = render_deck_body(pitchbook.get_pitchbook(self.conn, book_id))
        for header in ("Basis", "Price date", "B/S date", "EV/NTM EBITDA", "Shares", "GAAP operating income"):
            self.assertIn(header, markup)

    # (g) stamp ----------------------------------------------------------------

    def test_every_slide_is_stamped(self):
        book_id, slides = self._deck("NVG")
        expected = (
            f"Data as of 2026-08-19, price as of 2026-10-09, built {date.today().isoformat()} · Argos {__version__}"
        )
        cover = self._kind(slides, "cover")["payload"]
        self.assertEqual(cover["stamp"]["text"], expected)
        self.assertEqual(cover["price_date"], "2026-10-09")
        self.assertTrue(all(s["payload"].get("stamp") for s in slides))
        markup = render_deck_body(pitchbook.get_pitchbook(self.conn, book_id))
        self.assertEqual(markup.count('<footer class="stamp">'), len(slides) - 1)   # the cover prints it inline
        self.assertEqual(markup.count(expected), len(slides))

    # (h) market overview ------------------------------------------------------

    def test_boilerplate_themes_are_filtered(self):
        themes = ["loss net", "comprehensive income", "datacenter load", "file reports", "accounting standards",
                  "net", "stock incentive", "n/a", "load growth"]
        self.assertEqual(pitchbook.filter_themes(themes), ["datacenter load", "load growth"])
        self.assertEqual(
            pitchbook.filter_themes(["meridian flow", "flow controls", "pricing pressure"], company_name="Meridian Flow Controls"),
            ["pricing pressure"],
        )

    def test_theme_shift_is_only_claimed_when_shares_move(self):
        moved = [
            {"theme": "datacenter load", "share": 0.30, "prior_share": 0.05, "share_change": 0.25},
            {"theme": "rate cases", "share": 0.10, "prior_share": 0.30, "share_change": -0.20},
        ]
        sentence = pitchbook.theme_shift_sentence(moved, 59, 360)
        self.assertIn("shifted toward datacenter load (5% to 30% of documents) from rate cases (30% to 10%", sentence)
        flat = [
            {"theme": "datacenter load", "share": 0.30, "prior_share": 0.25, "share_change": 0.05},
            {"theme": "rate cases", "share": 0.20, "prior_share": 0.22, "share_change": -0.02},
        ]
        self.assertIn("the topic mix is stable", pitchbook.theme_shift_sentence(flat, 59, 360))
        _, slides = self._deck("NVG")
        payload = self._kind(slides, "market_overview")["payload"]
        self.assertTrue(all(pitchbook.filter_themes([t["theme"]]) for t in payload["themes"]))
        # Seed: "datacenter load" is in 8 of 31 recent documents (26%) and 0 of
        # 59 before; nothing loses 10 points, so the mix is called stable.
        self.assertIn("datacenter load gained share (0% to 26% of documents)", payload["narrative"])
        self.assertIn("the topic mix is otherwise stable", payload["narrative"])

    # unknown net debt --------------------------------------------------------

    def test_unknown_net_debt_deck_has_no_na_inside_sentences(self):
        self.conn.execute(
            "UPDATE market_data SET net_debt = NULL WHERE company_id = (SELECT id FROM companies WHERE ticker = 'NVG')"
        )
        self.conn.commit()
        book_id, slides = self._deck("NVG")
        for sentence in _prose(slides):
            self.assertNotIn("n/a", sentence)
        summary = " ".join(b["text"] for b in self._kind(slides, "executive_summary")["payload"]["bullets"])
        self.assertIn("could not be bridged", summary)
        self.assertIn("net debt is not reported, so no enterprise value or EV multiple is quoted", summary)
        self.assertEqual(self._kind(slides, "executive_summary")["payload"]["reference_range"], {})
        dcf = self._kind(slides, "dcf")["payload"]
        self.assertIsNone(dcf["value_per_share"])
        self.assertIn("Net debt unknown", dcf["note"])
        process = self._kind(slides, "process")["payload"]["bullets"]
        self.assertIn("Net debt is not reported on the latest balance sheet loaded, so leverage capacity is not assessed.", process)
        for row in self._kind(slides, "buyers")["payload"]["candidates"][:-1]:
            self.assertIn("relative size not assessed (target net debt unknown)", row["rationale"])
        markup = render_deck_body(pitchbook.get_pitchbook(self.conn, book_id))
        for sentence in _html_prose(markup):
            self.assertNotIn("n/a", sentence)
        self.assertIn("not bridged", markup)

    def test_unknown_net_debt_deck_exports_in_every_available_format(self):
        # Integration: pptx_export formatted equity_value / value_per_share with
        # f"{None:,.0f}" and raised TypeError once valuation returned None for an
        # unknown net debt. Every available exporter must now write the deck.
        import tempfile
        from pathlib import Path
        from argos.exporters import available_formats, export
        self.conn.execute(
            "UPDATE market_data SET net_debt = NULL WHERE company_id = (SELECT id FROM companies WHERE ticker = 'NVG')"
        )
        self.conn.commit()
        book_id, _slides = self._deck("NVG")
        book = pitchbook.get_pitchbook(self.conn, book_id)
        with tempfile.TemporaryDirectory() as tmp:
            for fmt, ok in available_formats().items():
                if not ok:
                    continue
                with self.subTest(fmt=fmt):
                    written = export(book, fmt, Path(tmp) / f"deck.{fmt}")
                    self.assertGreater(written.stat().st_size, 0)


class CompSuggestionTests(unittest.TestCase):
    def test_suggestions_are_same_sector_and_size_ranked(self):
        conn = seeded_connection()
        comps = pitchbook.suggest_comps(conn, "PYLN", limit=3)
        self.assertTrue(comps)
        self.assertNotIn("PYLN", comps)
        self.assertLessEqual(len(comps), 3)


if __name__ == "__main__":
    unittest.main()
