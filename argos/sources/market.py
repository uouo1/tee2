"""Public market quotes.

Share price, 52-week range and beta come from a public quote endpoint; shares
outstanding come from the filer's own cover page in EDGAR, because that is the
authoritative number and it arrives with the rest of the fundamentals.
"""

from __future__ import annotations

from typing import Any

from .http import fetch_json

QUOTE_URL = "https://query1.finance.yahoo.com/v8/finance/chart/{ticker}?range=1y&interval=1d"
# A browser-ish agent: the quote endpoint rejects the SEC-style identifier.
QUOTE_USER_AGENT = "Mozilla/5.0 (compatible; Argos-Research-Tool/1.0)"


def fetch_quote(ticker: str, *, cache: bool = True) -> dict[str, Any] | None:
    """Return price, 52-week range and currency for a ticker, or None."""
    try:
        payload = fetch_json(
            QUOTE_URL.format(ticker=ticker.upper()), cache=cache, user_agent=QUOTE_USER_AGENT
        )
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
    from datetime import datetime, timezone

    stamp = meta.get("regularMarketTime")
    if not stamp:
        return None
    return datetime.fromtimestamp(int(stamp), tz=timezone.utc).date().isoformat()
