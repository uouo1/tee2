import io
import json
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from tempfile import TemporaryDirectory

from argos.__main__ import main


class CliTests(unittest.TestCase):
    """The CLI is a supported surface, so it gets the same treatment as the API."""

    def setUp(self):
        self._tmp = TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.db = str(Path(self._tmp.name) / "cli.db")

    def run_cli(self, *args) -> tuple[int, str]:
        """Return (exit code, stdout + stderr) with the streams captured apart.

        They are captured separately because stdout carries machine-readable
        JSON for several commands; a stray warning on stderr must not land in
        the middle of it.
        """
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            code = main([*args, "--db", self.db])
        self.stdout, self.stderr = out.getvalue(), err.getvalue()
        return code, self.stdout

    def test_seed_then_stats(self):
        code, out = self.run_cli("seed")
        self.assertEqual(code, 0)
        self.assertGreater(json.loads(out)["documents_added"], 0)
        code, out = self.run_cli("stats")
        self.assertEqual(code, 0)
        self.assertGreater(json.loads(out)["counts"]["documents"], 0)

    def test_search_text_and_json(self):
        self.run_cli("seed")
        code, out = self.run_cli("search", "pricing", "pressure", "--limit", "3")
        self.assertEqual(code, 0)
        self.assertIn("document(s) in", out)
        code, out = self.run_cli("search", "margin", "--json", "--limit", "2")
        self.assertEqual(code, 0)
        self.assertIn("results", json.loads(out))

    def test_pitchbook_generation_and_export(self):
        self.run_cli("seed")
        target = str(Path(self._tmp.name) / "deck.html")
        code, out = self.run_cli(
            "pitchbook", "NVG", "--title", "Project CLI", "--comps", "HLDX,VLTR",
            "--export", "html", "--out", target,
        )
        self.assertEqual(code, 0)
        self.assertIn("14 slides", out)
        self.assertTrue(Path(target).exists())
        self.assertIn("<!doctype html>", Path(target).read_text(encoding="utf-8")[:120].lower())

    def test_export_existing_pitchbook(self):
        self.run_cli("seed")
        self.run_cli("pitchbook", "NVG")
        target = str(Path(self._tmp.name) / "again.html")
        code, _ = self.run_cli("export", "1", "--format", "html", "--out", target)
        self.assertEqual(code, 0)
        self.assertTrue(Path(target).exists())

    def test_unknown_ticker_exits_non_zero(self):
        self.run_cli("seed")
        code, _ = self.run_cli("pitchbook", "NOPE")
        self.assertEqual(code, 2)
        self.assertIn("unknown target ticker", self.stderr)

    def test_missing_ingest_path_exits_non_zero(self):
        code, _ = self.run_cli("ingest", "/nonexistent/corpus.json")
        self.assertEqual(code, 2)
        self.assertIn("no such path", self.stderr)

    def test_ingest_file(self):
        corpus = Path(self._tmp.name) / "docs.jsonl"
        corpus.write_text(json.dumps({
            "external_id": "cli-1", "title": "Note", "doc_type": "memo",
            "published_at": "2026-05-05", "body": "Pricing held firm through the renewal cycle.",
        }) + "\n", encoding="utf-8")
        code, out = self.run_cli("ingest", str(corpus))
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(out)["added"], 1)


if __name__ == "__main__":
    unittest.main()
