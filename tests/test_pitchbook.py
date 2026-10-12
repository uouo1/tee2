import unittest

from argos import pitchbook
from tests.support import seeded_connection


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


class CompSuggestionTests(unittest.TestCase):
    def test_suggestions_are_same_sector_and_size_ranked(self):
        conn = seeded_connection()
        comps = pitchbook.suggest_comps(conn, "PYLN", limit=3)
        self.assertTrue(comps)
        self.assertNotIn("PYLN", comps)
        self.assertLessEqual(len(comps), 3)


if __name__ == "__main__":
    unittest.main()
