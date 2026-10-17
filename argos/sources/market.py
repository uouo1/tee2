"""Public market quotes and consensus estimates.

Share price, 52-week range and beta come from public quote endpoints; shares
outstanding come from the filer's own cover page in EDGAR, because that is the
authoritative number and it arrives with the rest of the fundamentals.

Consensus revenue and EPS for the current and next fiscal year come from
Yahoo's quoteSummary, which needs a session cookie and a "crumb" token. The
crumb is a credential of sorts, so only the parsed estimates are ever cached.
"""

from __future__ import annotations

import gzip
import http.cookiejar
import json
import urllib.error
import urllib.parse
import urllib.request
import zlib
from datetime import date, datetime, timezone
from typing import Any

from . import http as argos_http
from .http import fetch_json

QUOTE_URL = "https://query1.finance.yahoo.com/v8/finance/chart/{ticker}?range=1y&interval=1d"
# A browser-ish agent: the quote endpoint rejects the SEC-style identifier.
QUOTE_USER_AGENT = "Mozilla/5.0 (compatible; Argos-Research-Tool/1.0)"

# The crumb flow: fc.yahoo.com sets the session cookie (answering 404 while it
# does), getcrumb trades the cookie for a token, quoteSummary wants both.
COOKIE_URL = "https://fc.yahoo.com"
CRUMB_URL = "https://query2.finance.yahoo.com/v1/test/getcrumb"
SUMMARY_URL = (
    "https://query2.finance.yahoo.com/v10/finance/quoteSummary/{ticker}"
    "?modules=earningsTrend,defaultKeyStatistics"
)
# quoteSummary refuses the polite identifier QUOTE_USER_AGENT uses.
BROWSER_USER_AGENT = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/124.0 Safari/537.36"
)
ESTIMATE_PERIODS = ("0y", "+1y")   # current and next fiscal year


def quote_url(ticker: str, *, on: date | None = None) -> str:
    """The chart URL for a ticker, carrying the calendar day.

    The disk cache is keyed by URL, so the day rides along as a query parameter
    the endpoint ignores; without it a cached quote was served forever and
    "re-run the loader to refresh" was false (the audited Ruby port's fix).
    """
    day = (on or date.today()).isoformat()
    return f"{QUOTE_URL.format(ticker=ticker.upper())}&asof={day}"


def fetch_quote(ticker: str, *, cache: bool = True, on: date | None = None) -> dict[str, Any] | None:
    """Return price, 52-week range and currency for a ticker, or None."""
    try:
        payload = fetch_json(quote_url(ticker, on=on), cache=cache, user_agent=QUOTE_USER_AGENT)
    except Exception:
        return None
    results = (payload.get("chart") or {}).get("result") or []
    if not results:
        return None
    meta = results[0].get("meta") or {}
    price = meta.get("regularMarketPrice")
    if price is None:
        return None

    # Fall back to the year of closes when the summary range is absent.
    closes = [
        value for value in
        (((results[0].get("indicators") or {}).get("quote") or [{}])[0].get("close") or [])
        if value is not None
    ]
    low = meta.get("fiftyTwoWeekLow") or (min(closes) if closes else None)
    high = meta.get("fiftyTwoWeekHigh") or (max(closes) if closes else None)
    return {
        "ticker": meta.get("symbol", ticker.upper()),
        "share_price": round(float(price), 2),
        "currency": meta.get("currency", "USD"),
        "week52_low": round(float(low), 2) if low else None,
        "week52_high": round(float(high), 2) if high else None,
        "as_of": _as_of(meta),
        "exchange": meta.get("fullExchangeName"),
    }


def _as_of(meta: dict[str, Any]) -> str | None:
    stamp = meta.get("regularMarketTime")
    if not stamp:
        return None
    return datetime.fromtimestamp(int(stamp), tz=timezone.utc).date().isoformat()


# -------------------------------------------------------------- estimates


def _fiscal_year(end: str) -> int:
    """Fiscal year for a period end — the same rule as ``sec._fiscal_year``.

    Restated here because sec imports this module; early-January ends belong
    to the prior year (52/53-week filers), so an estimate lands on the same
    fiscal_year as the actuals it continues.
    """
    ended = date.fromisoformat(end)
    return ended.year - 1 if (ended.month == 1 and ended.day <= 15) else ended.year


def estimates_cache_key(ticker: str, *, on: date | None = None) -> str:
    """What the parsed estimates are cached under: ticker and calendar day.

    Deliberately the summary URL WITHOUT the crumb, so the token never reaches
    the disk, even as a filename's preimage.
    """
    day = (on or date.today()).isoformat()
    return f"{SUMMARY_URL.format(ticker=ticker.upper())}&asof={day}"


def _build_opener() -> urllib.request.OpenerDirector:
    """An opener with its own cookie jar; the three requests must share it."""
    return urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))


def _read(opener: urllib.request.OpenerDirector, url: str, *, timeout: int) -> bytes:
    argos_http._throttle()
    request = urllib.request.Request(url, headers={"User-Agent": BROWSER_USER_AGENT, "Accept": "*/*"})
    with opener.open(request, timeout=timeout) as response:
        payload = response.read()
        encoding = response.headers.get("Content-Encoding") if response.headers else None
    if encoding == "gzip":
        payload = gzip.decompress(payload)
    elif encoding == "deflate":
        payload = zlib.decompress(payload)
    return payload


def _fetch_summary(ticker: str, *, timeout: int = 30) -> dict[str, Any]:
    """Run the cookie → crumb → quoteSummary flow and return the raw payload."""
    opener = _build_opener()
    try:
        _read(opener, COOKIE_URL, timeout=timeout)
    except urllib.error.HTTPError:
        pass  # fc.yahoo.com answers 404; the cookie arrives with the error
    crumb = _read(opener, CRUMB_URL, timeout=timeout).decode("utf-8", errors="replace").strip()
    if not crumb or "<" in crumb or " " in crumb:
        raise RuntimeError("no crumb issued")   # an HTML error page, not a token
    url = f"{SUMMARY_URL.format(ticker=urllib.parse.quote(ticker.upper()))}&crumb={urllib.parse.quote(crumb, safe='')}"
    return json.loads(_read(opener, url, timeout=timeout).decode("utf-8", errors="replace"))


def _raw(node: Any, *path: str) -> Any:
    """``node[path...]["raw"]``, or None anywhere along the way (Yahoo sends {} for missing)."""
    for key in path:
        if not isinstance(node, dict):
            return None
        node = node.get(key)
    return node.get("raw") if isinstance(node, dict) else None


def parse_estimates(payload: dict[str, Any], *, on: date | None = None) -> dict[str, Any] | None:
    """Current- and next-year consensus from a quoteSummary payload, or None.

    Revenue is in millions (as every stored figure), EPS per share. A period
    with neither a revenue nor an EPS estimate is dropped rather than stored
    as an empty forecast.
    """
    results = ((payload or {}).get("quoteSummary") or {}).get("result") or []
    if not results:
        return None
    body = results[0] or {}
    estimates = []
    for entry in (body.get("earningsTrend") or {}).get("trend") or []:
        if entry.get("period") not in ESTIMATE_PERIODS or not entry.get("endDate"):
            continue
        period_end = str(entry["endDate"])[:10]
        revenue = _raw(entry, "revenueEstimate", "avg")
        eps = _raw(entry, "earningsEstimate", "avg")
        if revenue is None and eps is None:
            continue
        analysts = _raw(entry, "revenueEstimate", "numberOfAnalysts")
        if analysts is None:
            source = "consensus (Yahoo Finance)"
        else:
            analysts = int(analysts)
            source = f"consensus (Yahoo Finance, {analysts} analyst{'' if analysts == 1 else 's'})"
        estimates.append({
            "fiscal_year": _fiscal_year(period_end),
            "period_end": period_end,
            "revenue": round(float(revenue) / 1e6, 1) if revenue is not None else None,
            "eps": round(float(eps), 2) if eps is not None else None,
            "analysts": analysts,
            "source": source,
        })
    beta = _raw(body, "defaultKeyStatistics", "beta")
    if not estimates and beta is None:
        return None
    estimates.sort(key=lambda row: row["fiscal_year"])
    return {
        "estimates": estimates,
        "beta": float(beta) if beta is not None else None,
        "as_of": (on or date.today()).isoformat(),
    }


def fetch_estimates(ticker: str, *, cache: bool = True, on: date | None = None) -> dict[str, Any] | None:
    """Consensus revenue/EPS for the current and next fiscal year, plus beta.

    Returns ``{"estimates": [{"fiscal_year", "period_end", "revenue", "eps",
    "analysts", "source"}], "beta", "as_of"}`` or None on any failure — a
    missing estimate must never sink a company load. The parsed result is
    cached per ticker and calendar day under the HTTP cache directory; the
    crumb never is.
    """
    path = argos_http.cache_path(estimates_cache_key(ticker, on=on), ".json")
    if cache and path.exists():
        try:
            return json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            pass   # a torn cache file is refetched, not trusted
    try:
        parsed = parse_estimates(_fetch_summary(ticker), on=on)
    except Exception:
        return None
    if parsed is not None and cache:
        try:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(json.dumps(parsed), encoding="utf-8")
        except OSError:
            pass
    return parsed
