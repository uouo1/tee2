import unittest

from argos import nlp


class SentimentTests(unittest.TestCase):
    def test_direction(self):
        positive = nlp.score_sentiment("Revenue growth accelerated and margins expanded to a record level.")
        negative = nlp.score_sentiment("Demand was weaker and guidance was cut on macro headwinds.")
        self.assertGreater(positive, 0.3)
        self.assertLess(negative, -0.3)

    def test_negation_flips_polarity(self):
        self.assertLess(nlp.score_sentiment("Results were not strong."), 0)
        self.assertGreater(nlp.score_sentiment("Results were strong."), 0)

    def test_intensifier_increases_magnitude(self):
        plain = nlp.score_sentiment("Bookings were weak.")
        intense = nlp.score_sentiment("Bookings were significantly weak.")
        self.assertLess(intense, plain)

    def test_empty_text_is_neutral(self):
        self.assertEqual(nlp.score_sentiment(""), 0.0)
        self.assertEqual(nlp.sentiment_label(0.0), "neutral")

    def test_labels(self):
        self.assertEqual(nlp.sentiment_label(0.5), "positive")
        self.assertEqual(nlp.sentiment_label(-0.5), "negative")
        self.assertEqual(nlp.sentiment_label(0.05), "neutral")


class KpiTests(unittest.TestCase):
    def test_extracts_percentages_and_currency(self):
        text = ("Revenue grew 18.4% while gross margin reached 71.2%. "
                "ARR was $1.4 billion. Net dollar retention of 114%.")
        found = {kpi["metric"]: kpi for kpi in nlp.extract_kpis(text)}
        self.assertAlmostEqual(found["revenue_growth"]["value"], 18.4)
        self.assertAlmostEqual(found["gross_margin"]["value"], 71.2)
        self.assertAlmostEqual(found["net_retention"]["value"], 114.0)
        # Billions are normalised to millions so the series is comparable.
        self.assertAlmostEqual(found["arr"]["value"], 1400.0)
        self.assertEqual(found["arr"]["unit"], "USDm")

    def test_keeps_sentence_context(self):
        kpis = nlp.extract_kpis("Headline. Gross margin was 61.0% in the quarter.")
        self.assertIn("61.0%", kpis[0]["context"])

    def test_no_false_positives_on_plain_text(self):
        self.assertEqual(nlp.extract_kpis("We hired a new chief financial officer."), [])


class SummaryTests(unittest.TestCase):
    def test_returns_sentences_in_source_order(self):
        text = ("Revenue grew 18%. We see headwinds in EMEA. "
                "Margins expanded 240bps on pricing discipline. The CFO will retire.")
        summary = nlp.summarize(text, limit=2)
        self.assertEqual(len(summary), 2)
        self.assertEqual(summary, sorted(summary, key=lambda s: text.index(s)))

    def test_short_text_returned_whole(self):
        self.assertEqual(nlp.summarize("One sentence only.", limit=4), ["One sentence only."])

    def test_query_terms_bias_selection(self):
        text = ("The weather was fine. Churn improved materially this quarter. "
                "We opened a new office. Headcount was flat. Travel costs fell.")
        summary = nlp.summarize(text, limit=1, query_terms=["churn"])
        self.assertIn("Churn", summary[0])


class ThemeTests(unittest.TestCase):
    def test_lift_favours_newly_emerging_phrases(self):
        recent = ["interconnection queue backlog is the constraint"] * 3
        baseline = ["storm hardening programmes dominate the plan"] * 3
        themes = {row["theme"] for row in nlp.theme_trends(recent, baseline, limit=10)}
        self.assertTrue(any("interconnection" in theme for theme in themes))
        self.assertFalse(any("storm" in theme for theme in themes))

    def test_contained_themes_are_removed(self):
        recent = ["datacenter load growth"] * 4
        themes = [row["theme"] for row in nlp.theme_trends(recent, ["unrelated text here"] * 4, limit=10)]
        # "load" must not take a slot next to "datacenter load".
        self.assertNotIn("load", themes)

    def test_expand_query_terms_is_ordered_and_unique(self):
        expanded = nlp.expand_query_terms(["guidance", "guidance"])
        self.assertEqual(expanded[0], "guidance")
        self.assertEqual(len(expanded), len(set(expanded)))
        self.assertIn("outlook", expanded)


class KeywordTests(unittest.TestCase):
    def test_repeated_terms_outrank_singletons(self):
        text = " ".join(["interconnection queue"] * 5 + ["sporadic", "irrelevant", "oneoff"])
        top = [term for term, _ in nlp.keywords(text, limit=3)]
        self.assertTrue(any("interconnection" in term for term in top))

    def test_empty_input(self):
        self.assertEqual(nlp.keywords(""), [])


if __name__ == "__main__":
    unittest.main()
