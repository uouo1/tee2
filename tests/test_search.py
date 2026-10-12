import unittest
from datetime import date

from argos import search
from tests.support import seeded_connection


class QueryParsingTests(unittest.TestCase):
    def test_phrases_terms_and_exclusions(self):
        parsed = search.parse_query('"interconnection queue" margin -restructuring type:filing')
        self.assertEqual(parsed.phrases, ["interconnection queue"])
        self.assertEqual(parsed.terms, ["margin"])
        self.assertEqual(parsed.excluded, ["restructuring"])
        self.assertEqual(parsed.fields, {"type": "filing"})

    def test_or_groups(self):
        parsed = search.parse_query("tariff OR datacenter OR curtailment")
        self.assertEqual(parsed.or_groups, [["tariff", "datacenter", "curtailment"]])

    def test_empty_query(self):
        self.assertTrue(search.parse_query("").is_empty)

    def test_match_expression_expands_synonyms(self):
        expression = search.build_match_expression(search.parse_query("guidance"), expand=True)
        self.assertIn('"outlook"', expression)
        plain = search.build_match_expression(search.parse_query("guidance"), expand=False)
        self.assertEqual(plain, '"guidance"')

    def test_match_expression_neutralises_fts_operators(self):
        expression = search.build_match_expression(search.parse_query('"quote" mar*gin'), expand=False)
        self.assertNotIn("*", expression)
        self.assertTrue(expression.count('"') % 2 == 0)

    def test_exclusions_render_as_not(self):
        expression = search.build_match_expression(search.parse_query("margin -churn"), expand=False)
        self.assertIn("NOT", expression)


class SearchTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.conn = seeded_connection()

    def test_returns_ranked_results_with_snippets(self):
        result = search.search(self.conn, "pricing pressure", limit=5)
        self.assertGreater(result["total_documents"], 0)
        self.assertTrue(all("<mark>" in row["snippet_html"] for row in result["results"]))
        scores = [row["score"] for row in result["results"]]
        self.assertEqual(scores, sorted(scores, reverse=True))

    def test_snippets_are_html_escaped(self):
        result = search.search(self.conn, "revenue", limit=5)
        for row in result["results"]:
            self.assertNotIn("<script", row["snippet_html"].lower())

    def test_results_are_deduplicated_per_document(self):
        result = search.search(self.conn, "revenue", limit=20)
        ids = [row["document_id"] for row in result["results"]]
        self.assertEqual(len(ids), len(set(ids)))
        self.assertTrue(any(row["match_count"] >= 1 for row in result["results"]))

    def test_filters_narrow_results(self):
        filtered = search.search(self.conn, "revenue", {"doc_type": ["filing"]}, limit=50)
        self.assertTrue(all(row["doc_type"] == "filing" for row in filtered["results"]))

    def test_inline_field_filter_matches_explicit_filter(self):
        inline = search.search(self.conn, "revenue type:filing", limit=50)
        explicit = search.search(self.conn, "revenue", {"doc_type": ["filing"]}, limit=50)
        self.assertEqual(inline["total_documents"], explicit["total_documents"])

    def test_exclusion_removes_documents(self):
        with_term = search.search(self.conn, "pressure", limit=50)["total_documents"]
        without = search.search(self.conn, "pressure -renewals", limit=50)["total_documents"]
        self.assertLess(without, with_term)

    def test_empty_query_browses_newest_first(self):
        result = search.search(self.conn, "", limit=5)
        dates = [row["published_at"] for row in result["results"]]
        self.assertEqual(dates, sorted(dates, reverse=True))

    def test_facets_cover_every_dimension(self):
        facets = search.search(self.conn, "margin", limit=5)["facets"]
        self.assertEqual(set(facets), {"doc_type", "ticker", "sector", "year", "sentiment"})
        self.assertTrue(all(row["count"] > 0 for row in facets["doc_type"]))

    def test_summary_bullets_carry_citations_and_are_unique(self):
        summary = search.search(self.conn, "pricing pressure renewals", limit=8)["summary"]
        self.assertTrue(summary["bullets"])
        texts = [bullet["text"] for bullet in summary["bullets"]]
        self.assertEqual(len(texts), len(set(texts)))
        self.assertTrue(all(bullet["document_id"] for bullet in summary["bullets"]))

    def test_summary_skips_analyst_questions(self):
        summary = search.search(self.conn, "margin trajectory", limit=10).get("summary", {})
        for bullet in summary.get("bullets", []):
            self.assertFalse(bullet["text"].rstrip().endswith("?"))

    def test_recency_weighting_prefers_newer_documents(self):
        old = search._recency_weight("2020-01-01", today=date(2026, 10, 12))
        new = search._recency_weight("2026-09-01", today=date(2026, 10, 12))
        self.assertGreater(new, old)

    def test_pagination(self):
        first = search.search(self.conn, "revenue", limit=3, offset=0)
        second = search.search(self.conn, "revenue", limit=3, offset=3)
        self.assertNotEqual(
            [row["document_id"] for row in first["results"]],
            [row["document_id"] for row in second["results"]],
        )

    def test_unknown_term_returns_nothing_without_error(self):
        result = search.search(self.conn, "zzzznotaword", limit=5)
        self.assertEqual(result["total_documents"], 0)
        self.assertEqual(result["results"], [])


class DocumentTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.conn = seeded_connection()

    def test_document_view_is_complete(self):
        document_id = search.search(self.conn, "revenue", limit=1)["results"][0]["document_id"]
        document = search.get_document(self.conn, document_id)
        for key in ("chunks", "kpis", "summary", "keywords", "similar", "sentiment_label"):
            self.assertIn(key, document)
        self.assertTrue(document["chunks"])

    def test_missing_document(self):
        self.assertIsNone(search.get_document(self.conn, 10 ** 7))

    def test_similar_documents_are_ranked_and_exclude_self(self):
        document_id = search.search(self.conn, "revenue", limit=1)["results"][0]["document_id"]
        similar = search.similar_documents(self.conn, document_id, limit=5)
        self.assertTrue(similar)
        self.assertNotIn(document_id, [row["document_id"] for row in similar])
        scores = [row["similarity"] for row in similar]
        self.assertEqual(scores, sorted(scores, reverse=True))


if __name__ == "__main__":
    unittest.main()
