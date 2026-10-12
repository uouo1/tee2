import unittest

from argos import analytics
from tests.support import empty_connection, seeded_connection


class OverviewTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.conn = seeded_connection()

    @classmethod
    def tearDownClass(cls):
        cls.conn.close()

    def test_overview_counts_match_the_tables(self):
        overview = analytics.overview(self.conn)
        documents = self.conn.execute("SELECT COUNT(*) FROM documents").fetchone()[0]
        self.assertEqual(overview["counts"]["documents"], documents)
        self.assertEqual(sum(row["count"] for row in overview["by_type"]), documents)

    def test_overview_is_anchored_to_the_corpus_not_today(self):
        latest = self.conn.execute("SELECT MAX(published_at) FROM documents").fetchone()[0]
        self.assertEqual(analytics.overview(self.conn)["as_of"], latest)

    def test_sentiment_timeline_is_chronological(self):
        timeline = analytics.sentiment_timeline(self.conn, ticker="NVG")
        months = [row["month"] for row in timeline]
        self.assertEqual(months, sorted(months))
        self.assertTrue(all(-1 <= row["sentiment"] <= 1 for row in timeline))

    def test_volume_series_align_with_the_month_axis(self):
        volume = analytics.volume_by_type(self.conn)
        self.assertTrue(volume["months"])
        for series in volume["series"]:
            self.assertEqual(len(series["values"]), len(volume["months"]))

    def test_trending_themes_compare_two_windows(self):
        trends = analytics.trending_themes(self.conn, window_days=180)
        self.assertGreater(trends["recent_documents"], 0)
        self.assertTrue(trends["themes"])
        self.assertTrue(all(row["lift"] > 0 for row in trends["themes"]))

    def test_themes_exclude_speaker_names(self):
        # Themes come from chunk text, which has speaker attribution split off.
        themes = {row["theme"] for row in analytics.trending_themes(self.conn, window_days=365)["themes"]}
        self.assertFalse(any("dana" in theme or "avery" in theme for theme in themes))

    def test_company_profile_is_complete(self):
        profile = analytics.company_profile(self.conn, "nvg")
        for key in ("financials", "market_data", "documents", "kpis", "sentiment_timeline", "themes", "metrics"):
            self.assertIn(key, profile)
        self.assertEqual(profile["ticker"], "NVG")

    def test_unknown_company(self):
        self.assertIsNone(analytics.company_profile(self.conn, "NOPE"))

    def test_kpi_series_group_by_metric_with_history(self):
        series = analytics.kpi_series(self.conn, "NVG")
        self.assertTrue(series)
        for bucket in series:
            self.assertEqual(bucket["observations"], len(bucket["points"]))
            dates = [point["published_at"] for point in bucket["points"]]
            self.assertEqual(dates, sorted(dates))


class EmptyCorpusTests(unittest.TestCase):
    def test_overview_on_an_empty_database(self):
        conn = empty_connection()
        self.addCleanup(conn.close)
        overview = analytics.overview(conn)
        self.assertEqual(overview["counts"]["documents"], 0)
        self.assertEqual(overview["by_type"], [])
        self.assertEqual(overview["trending"], [])

    def test_alerts_without_saved_searches(self):
        conn = empty_connection()
        self.addCleanup(conn.close)
        self.assertEqual(analytics.check_alerts(conn), [])


if __name__ == "__main__":
    unittest.main()
