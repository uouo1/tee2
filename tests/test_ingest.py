import json
import tempfile
import unittest
from pathlib import Path

from argos import ingest
from tests.support import empty_connection


class ChunkingTests(unittest.TestCase):
    def test_speaker_attribution(self):
        body = ("Operator: Good morning.\n\n"
                "Jane Doe, CEO: Revenue grew 18.4% this quarter and momentum is strong.\n\n"
                "John Roe, CFO: We see headwinds in EMEA and expect slower bookings.")
        chunks = ingest.chunk_body(body)
        self.assertEqual([chunk["speaker"] for chunk in chunks],
                         ["Operator", "Jane Doe, CEO", "John Roe, CFO"])
        self.assertNotIn("Jane Doe", chunks[1]["text"])

    def test_long_paragraph_is_split(self):
        body = " ".join(["This is a sentence about grid software."] * 120)
        chunks = ingest.chunk_body(body)
        self.assertGreater(len(chunks), 1)
        self.assertTrue(all(len(chunk["text"]) <= ingest.MAX_CHUNK_CHARS + 200 for chunk in chunks))

    def test_empty_body(self):
        self.assertEqual(ingest.chunk_body(""), [])


class IngestTests(unittest.TestCase):
    def setUp(self):
        self.conn = empty_connection()
        self.doc = {
            "external_id": "doc-1",
            "title": "Q3 call",
            "doc_type": "transcript",
            "published_at": "2026-08-01",
            "ticker": "NVG",
            "company_name": "NovaGrid",
            "body": "Jane Doe, CEO: Revenue grew 12.5% and gross margin reached 68.0%.",
        }

    def test_creates_document_chunks_and_kpis(self):
        document_id = ingest.ingest_document(self.conn, self.doc)
        self.assertIsNotNone(document_id)
        self.assertEqual(self.conn.execute("SELECT COUNT(*) FROM chunks").fetchone()[0], 1)
        metrics = {row[0] for row in self.conn.execute("SELECT metric FROM kpis")}
        self.assertEqual(metrics, {"revenue_growth", "gross_margin"})

    def test_company_is_resolved_from_ticker(self):
        ingest.ingest_document(self.conn, self.doc)
        row = self.conn.execute("SELECT c.ticker FROM documents d JOIN companies c ON c.id = d.company_id").fetchone()
        self.assertEqual(row[0], "NVG")

    def test_external_id_makes_ingest_idempotent(self):
        ingest.ingest_document(self.conn, self.doc)
        self.assertIsNone(ingest.ingest_document(self.conn, self.doc))
        self.assertEqual(self.conn.execute("SELECT COUNT(*) FROM documents").fetchone()[0], 1)

    def test_missing_fields_raise(self):
        with self.assertRaises(ValueError):
            ingest.ingest_document(self.conn, {"title": "No body"})

    def test_fts_index_is_populated(self):
        ingest.ingest_document(self.conn, self.doc)
        hits = self.conn.execute("SELECT COUNT(*) FROM chunks_fts WHERE chunks_fts MATCH 'margin'").fetchone()[0]
        self.assertEqual(hits, 1)

    def test_deleting_a_document_clears_the_index(self):
        document_id = ingest.ingest_document(self.conn, self.doc)
        self.conn.execute("DELETE FROM documents WHERE id = ?", (document_id,))
        self.conn.commit()
        hits = self.conn.execute("SELECT COUNT(*) FROM chunks_fts WHERE chunks_fts MATCH 'margin'").fetchone()[0]
        self.assertEqual(hits, 0)


class FileIngestTests(unittest.TestCase):
    def test_reads_json_jsonl_and_directory(self):
        conn = empty_connection()
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "a.json").write_text(json.dumps([{
                "external_id": "a1", "title": "A", "doc_type": "news",
                "published_at": "2026-01-01", "body": "Margins expanded.",
            }]), encoding="utf-8")
            (root / "b.jsonl").write_text(json.dumps({
                "external_id": "b1", "title": "B", "doc_type": "news",
                "published_at": "2026-01-02", "body": "Guidance was raised.",
            }) + "\n", encoding="utf-8")
            result = ingest.ingest_path(conn, root)
        self.assertEqual(result["added"], 2)
        self.assertEqual(result["files"], 2)


if __name__ == "__main__":
    unittest.main()
