"""Command line interface: ``python -m argos <command>``.

The CLI is a first-class surface, not an afterthought — generating a deck or
running a search without starting the server is how this gets used in a
pipeline.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from . import analytics, ingest, pitchbook, search, seed, server
from .config import CONFIG
from .db import open_db
from .exporters import available_formats, export


def _add_db_argument(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--db", default=None, help=f"SQLite path (default: {CONFIG.db_path})")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="argos",
        description="Argos — research intelligence and pitch book generation in one application.",
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    serve_parser = subparsers.add_parser("serve", help="run the web application")
    serve_parser.add_argument("--host", default=CONFIG.host)
    serve_parser.add_argument("--port", type=int, default=CONFIG.port)
    serve_parser.add_argument("--quiet", action="store_true", help="suppress per-request logging")
    _add_db_argument(serve_parser)

    seed_parser = subparsers.add_parser("seed", help="load the synthetic demo corpus and market data")
    _add_db_argument(seed_parser)

    sec_parser = subparsers.add_parser(
        "load-sec", help="load real companies from SEC EDGAR (financials, market data and filings)"
    )
    sec_parser.add_argument("tickers", nargs="+", help="e.g. ITRI BMI XYL")
    sec_parser.add_argument("--sector", default=None, help="label the loaded set as one sector (used by comps)")
    sec_parser.add_argument("--years", type=int, default=6, help="fiscal years of financials (default 6)")
    sec_parser.add_argument("--annual", type=int, default=1, help="10-K filings per company (default 1)")
    sec_parser.add_argument("--quarterly", type=int, default=2, help="10-Q filings per company (default 2)")
    sec_parser.add_argument("--press-releases", type=int, default=4, help="8-K earnings releases per company (default 4)")
    sec_parser.add_argument("--no-documents", action="store_true", help="fundamentals and market data only")
    _add_db_argument(sec_parser)

    deals_parser = subparsers.add_parser(
        "load-transactions", help="load precedent transactions from a CSV you supply"
    )
    deals_parser.add_argument("path")
    _add_db_argument(deals_parser)

    ingest_parser = subparsers.add_parser("ingest", help="ingest documents from a file or directory")
    ingest_parser.add_argument("path", help=".json / .jsonl / .csv / .txt file, or a directory of them")
    _add_db_argument(ingest_parser)

    search_parser = subparsers.add_parser("search", help="run a research query")
    search_parser.add_argument("query", nargs="+")
    search_parser.add_argument("--limit", type=int, default=10)
    search_parser.add_argument("--json", action="store_true", help="emit raw JSON")
    search_parser.add_argument("--no-expand", action="store_true", help="disable synonym expansion")
    _add_db_argument(search_parser)

    book_parser = subparsers.add_parser("pitchbook", help="generate a pitch book for a target")
    book_parser.add_argument("ticker")
    book_parser.add_argument("--title", default=None)
    book_parser.add_argument("--client", default=None)
    book_parser.add_argument("--banker", default=None)
    book_parser.add_argument("--comps", default=None, help="comma-separated tickers (default: suggested)")
    book_parser.add_argument("--export", dest="export_format", choices=("html", "pptx", "pdf"), default=None)
    book_parser.add_argument("--out", default=None, help="output path for --export")
    _add_db_argument(book_parser)

    export_parser = subparsers.add_parser("export", help="export an existing pitch book")
    export_parser.add_argument("pitchbook_id", type=int)
    export_parser.add_argument("--format", dest="export_format", choices=("html", "pptx", "pdf"), default="html")
    export_parser.add_argument("--out", default=None)
    _add_db_argument(export_parser)

    stats_parser = subparsers.add_parser("stats", help="print corpus statistics")
    _add_db_argument(stats_parser)

    return parser


def _print_search(result: dict) -> None:
    print(f"{result['total_documents']} document(s) in {result['took_ms']}ms   [{result['match_expression'] or 'browse'}]")
    for row in result["results"]:
        print(f"\n  {row['title']}")
        print(f"    {row.get('ticker') or '—'} · {row['doc_type']} · {row['published_at']} · score {row['score']}"
              f" · tone {row['sentiment_label']}")
        snippet = row["snippet_html"].replace("<mark>", "«").replace("</mark>", "»")
        for tag in ("&amp;", "&lt;", "&gt;", "&quot;", "&#x27;"):
            snippet = snippet.replace(tag, {"&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": '"', "&#x27;": "'"}[tag])
        print(f"    {snippet}")
    summary = result.get("summary")
    if summary and summary.get("bullets"):
        print("\n  Summary of the top matches:")
        for bullet in summary["bullets"]:
            print(f"    • {bullet['text']}  [doc {bullet['document_id']}]")


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)

    if args.command == "serve":
        server.serve(args.host, args.port, db_path=args.db, verbose=not args.quiet)
        return 0

    conn = open_db(args.db)

    if args.command == "seed":
        result = seed.seed_database(conn)
        print(json.dumps(result, indent=2))
        return 0

    if args.command == "load-sec":
        from .sources.sec import load_companies

        result = load_companies(
            conn, args.tickers, sector=args.sector, years=args.years,
            annual=args.annual, quarterly=args.quarterly, press_releases=args.press_releases,
            with_documents=not args.no_documents,
        )
        print(json.dumps(result, indent=2))
        return 1 if result["failures"] and not result["loaded"] else 0

    if args.command == "load-transactions":
        from .sources.sec import load_transactions_csv

        path = Path(args.path).expanduser()
        if not path.exists():
            print(f"no such path: {path}", file=sys.stderr)
            return 2
        print(json.dumps(load_transactions_csv(conn, path), indent=2))
        return 0

    if args.command == "ingest":
        path = Path(args.path).expanduser()
        if not path.exists():
            print(f"no such path: {path}", file=sys.stderr)
            return 2
        result = ingest.ingest_path(conn, path) if path.is_dir() or path.suffix else ingest.ingest_path(conn, path)
        print(json.dumps(result, indent=2))
        return 0

    if args.command == "search":
        result = search.search(conn, " ".join(args.query), limit=args.limit, expand=not args.no_expand)
        if args.json:
            print(json.dumps(result, indent=2, default=str))
        else:
            _print_search(result)
        return 0

    if args.command == "pitchbook":
        comps = [t.strip().upper() for t in args.comps.split(",") if t.strip()] if args.comps else None
        try:
            pitchbook_id = pitchbook.create_pitchbook(
                conn,
                title=args.title or f"Project {args.ticker.upper()}",
                target_ticker=args.ticker,
                comp_tickers=comps,
                client_name=args.client,
                banker=args.banker,
            )
        except ValueError as exc:
            print(str(exc), file=sys.stderr)
            return 2
        book = pitchbook.get_pitchbook(conn, pitchbook_id) or {}
        print(f"pitchbook {pitchbook_id}: {book.get('title')} — {len(book.get('slides', []))} slides")
        for slide in book.get("slides", []):
            print(f"  {slide['seq']:>2}  {slide['kind']:<22} {slide['title']}")
        if args.export_format:
            path = Path(args.out) if args.out else CONFIG.export_dir / f"pitchbook-{pitchbook_id}.{args.export_format}"
            if not available_formats().get(args.export_format):
                print(f"format unavailable (missing dependency): {args.export_format}", file=sys.stderr)
                return 3
            export(book, args.export_format, path)
            print(f"exported: {path}")
        return 0

    if args.command == "export":
        book = pitchbook.get_pitchbook(conn, args.pitchbook_id)
        if not book:
            print(f"no such pitchbook: {args.pitchbook_id}", file=sys.stderr)
            return 2
        if not available_formats().get(args.export_format):
            print(f"format unavailable (missing dependency): {args.export_format}", file=sys.stderr)
            return 3
        path = Path(args.out) if args.out else CONFIG.export_dir / f"pitchbook-{args.pitchbook_id}.{args.export_format}"
        export(book, args.export_format, path)
        print(f"exported: {path}")
        return 0

    if args.command == "stats":
        overview = analytics.overview(conn)
        print(json.dumps({
            "as_of": overview["as_of"],
            "counts": overview["counts"],
            "by_type": overview["by_type"],
            "mean_sentiment": overview["sentiment"]["mean"],
            "top_themes": [t["theme"] for t in overview["trending"]],
            "export_formats": available_formats(),
        }, indent=2))
        return 0

    return 1


if __name__ == "__main__":
    raise SystemExit(main())
