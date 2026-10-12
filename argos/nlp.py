"""Lightweight, dependency-free text analytics.

Everything here runs locally: a finance-tuned sentiment lexicon, tf-idf keyword
and theme extraction, an extractive summarizer and a KPI pattern matcher. No
network calls and no model downloads, so the app behaves identically offline and
in CI.
"""

from __future__ import annotations

import math
import re
from collections import Counter
from dataclasses import dataclass, field
from typing import Iterable, Sequence

WORD_RE = re.compile(r"[A-Za-z][A-Za-z'&/-]+|\d+(?:\.\d+)?%?")
SENTENCE_RE = re.compile(r"(?<=[.!?])\s+(?=[A-Z0-9\"'(])")

STOPWORDS: frozenset[str] = frozenset(
    """
    a about above after again against all also am an and any are aren't as at be because been
    before being below between both but by can cannot could couldn't did didn't do does doesn't
    doing don't down during each few for from further had hadn't has hasn't have haven't having
    he her here hers herself him himself his how i if in into is isn't it its itself just let's
    me more most mustn't my myself no nor not of off on once only or other ought our ours
    ourselves out over own same shan't she should shouldn't so some such than that that's the
    their theirs them themselves then there these they this those through to too under until up
    very was wasn't we were weren't what when where which while who whom why with won't would
    wouldn't you your yours yourself yourselves will shall may might must us thing things
    quarter year years thank thanks please question questions next first second third call
    going got get go really lot bit kind sort going want want's said say says one two three
    """.split()
)

# Finance-tuned polarity. Values are deliberately coarse: the signal that matters
# is direction and relative intensity across a corpus, not a calibrated score.
POSITIVE_LEXICON: dict[str, float] = {
    "accelerate": 1.4, "accelerated": 1.4, "accelerating": 1.5, "acceleration": 1.5,
    "accretive": 1.2, "advantage": 0.8, "ahead": 1.0, "beat": 1.5, "benefit": 0.8,
    "best": 1.0, "boost": 1.1, "breakthrough": 1.3, "confident": 1.2, "confidence": 1.0,
    "demand": 0.5, "disciplined": 0.9, "durable": 1.0, "efficiency": 0.8, "efficient": 0.8,
    "exceed": 1.5, "exceeded": 1.5, "exceeding": 1.5, "expand": 0.9, "expanded": 1.0,
    "expanding": 1.0, "expansion": 1.0, "favorable": 1.1, "gain": 0.9, "gains": 0.9,
    "grew": 1.1, "growth": 0.9, "improve": 1.0, "improved": 1.1, "improvement": 1.1,
    "improving": 1.1, "increase": 0.7, "increased": 0.8, "leadership": 0.8, "momentum": 1.3,
    "opportunity": 0.8, "outperform": 1.5, "outperformed": 1.5, "outstanding": 1.3,
    "premium": 0.5, "profitable": 1.2, "profitability": 1.0, "raise": 1.2, "raised": 1.3,
    "raising": 1.3, "record": 1.3, "resilient": 1.1, "robust": 1.2, "stabilized": 0.7,
    "strength": 1.1, "strong": 1.2, "stronger": 1.3, "strongest": 1.4, "surpassed": 1.5,
    "tailwind": 1.3, "tailwinds": 1.3, "upside": 1.2, "upgrade": 1.3, "win": 1.0, "wins": 1.0,
}
NEGATIVE_LEXICON: dict[str, float] = {
    "adverse": 1.1, "below": 0.9, "challenge": 0.9, "challenged": 1.1, "challenging": 1.1,
    "churn": 1.2, "compression": 1.2, "concern": 1.0, "concerns": 1.0, "contraction": 1.3,
    "decelerate": 1.4, "decelerated": 1.4, "decelerating": 1.5, "deceleration": 1.5,
    "decline": 1.2, "declined": 1.2, "declining": 1.3, "deficit": 1.1, "delay": 1.1,
    "delayed": 1.2, "delays": 1.2, "deteriorate": 1.4, "deteriorating": 1.4, "difficult": 1.0,
    "dilution": 1.0, "dilutive": 1.0, "disappointing": 1.5, "downgrade": 1.3, "downside": 1.2,
    "downturn": 1.4, "guidance-cut": 1.6, "headwind": 1.3, "headwinds": 1.3, "impairment": 1.3,
    "litigation": 1.0, "loss": 1.2, "losses": 1.2, "miss": 1.4, "missed": 1.4, "pressure": 1.0,
    "pressured": 1.1, "recession": 1.3, "restructuring": 0.9, "risk": 0.7, "risks": 0.7,
    "shortfall": 1.4, "slow": 0.9, "slowdown": 1.4, "slower": 1.1, "slowing": 1.2,
    "soft": 1.0, "softer": 1.1, "softness": 1.2, "uncertain": 1.1, "uncertainty": 1.1,
    "underperform": 1.4, "weak": 1.2, "weaker": 1.3, "weakness": 1.3, "writedown": 1.3,
}
NEGATORS: frozenset[str] = frozenset({"not", "no", "never", "without", "less", "lack", "nor", "hardly", "barely"})
INTENSIFIERS: dict[str, float] = {"very": 1.4, "significantly": 1.5, "materially": 1.5, "substantially": 1.5,
                                  "slightly": 0.6, "modestly": 0.7, "somewhat": 0.7, "extremely": 1.6}

# Query expansion: the vocabulary gap between how analysts ask and how filings
# are written is the single biggest cause of "no results" in research search.
SYNONYMS: dict[str, tuple[str, ...]] = {
    "guidance": ("outlook", "forecast", "guide"),
    "outlook": ("guidance", "forecast"),
    "headwind": ("pressure", "challenge", "drag"),
    "tailwind": ("benefit", "support"),
    "margin": ("profitability", "margins"),
    "churn": ("attrition", "retention"),
    "layoff": ("workforce reduction", "restructuring", "redundancies"),
    "ai": ("artificial intelligence", "machine learning", "genai"),
    "capex": ("capital expenditure", "capital spending"),
    "buyback": ("repurchase", "share repurchase"),
    "m&a": ("acquisition", "merger", "takeover"),
    "pricing": ("price increase", "price realization", "list price"),
    "supply chain": ("logistics", "suppliers", "sourcing"),
    "demand": ("bookings", "orders", "pipeline"),
    "recession": ("downturn", "macro weakness"),
    "cloud": ("hyperscaler", "saas", "subscription"),
    "retention": ("renewal", "churn"),
    "backlog": ("rpo", "remaining performance obligations", "order book"),
}

KPI_PATTERNS: tuple[tuple[str, re.Pattern[str], str], ...] = (
    ("revenue_growth", re.compile(r"revenue\s+(?:grew|increased|rose|was up|up)\s+(?:by\s+)?(\d+(?:\.\d+)?)\s?%", re.I), "%"),
    ("revenue_decline", re.compile(r"revenue\s+(?:fell|declined|decreased|was down|down)\s+(?:by\s+)?(\d+(?:\.\d+)?)\s?%", re.I), "%"),
    ("gross_margin", re.compile(r"gross margin\D{0,24}?(\d+(?:\.\d+)?)\s?%", re.I), "%"),
    ("ebitda_margin", re.compile(r"(?:adjusted\s+)?ebitda margin\D{0,24}?(\d+(?:\.\d+)?)\s?%", re.I), "%"),
    ("operating_margin", re.compile(r"operating margin\D{0,24}?(\d+(?:\.\d+)?)\s?%", re.I), "%"),
    ("net_retention", re.compile(r"(?:net (?:dollar )?retention|ndr)\D{0,24}?(\d+(?:\.\d+)?)\s?%", re.I), "%"),
    ("churn", re.compile(r"churn\D{0,24}?(\d+(?:\.\d+)?)\s?%", re.I), "%"),
    ("arr", re.compile(r"(?:arr|annual recurring revenue)\D{0,24}?\$?(\d+(?:\.\d+)?)\s?(?:million|m|billion|bn|b)\b", re.I), "currency"),
    ("backlog", re.compile(r"(?:backlog|rpo|remaining performance obligations)\D{0,24}?\$?(\d+(?:\.\d+)?)\s?(?:million|m|billion|bn|b)\b", re.I), "currency"),
    ("headcount", re.compile(r"(?:headcount|employees)\D{0,24}?([\d,]{3,})\b", re.I), "count"),
    ("free_cash_flow", re.compile(r"free cash flow\D{0,24}?\$?(\d+(?:\.\d+)?)\s?(?:million|m|billion|bn|b)\b", re.I), "currency"),
    ("capex_intensity", re.compile(r"capex\D{0,24}?(\d+(?:\.\d+)?)\s?%\s+of revenue", re.I), "%"),
)


def tokenize(text: str) -> list[str]:
    """Lowercased word tokens, punctuation dropped."""
    return [m.group(0).lower() for m in WORD_RE.finditer(text or "")]


def content_tokens(text: str) -> list[str]:
    return [t for t in tokenize(text) if t not in STOPWORDS and len(t) > 2 and not t[0].isdigit()]


def sentences(text: str) -> list[str]:
    raw = [s.strip() for s in SENTENCE_RE.split((text or "").strip()) if s.strip()]
    return [s for s in raw if len(s) > 2]


def score_sentiment(text: str) -> float:
    """Return a polarity score in roughly [-1, 1].

    Handles negation ("not strong") and intensity ("significantly weaker") with a
    three-token look-back, which is enough for the hedged register of filings.
    """
    tokens = tokenize(text)
    if not tokens:
        return 0.0
    total = 0.0
    hits = 0
    for i, token in enumerate(tokens):
        weight = POSITIVE_LEXICON.get(token, 0.0) or -NEGATIVE_LEXICON.get(token, 0.0)
        if not weight:
            continue
        window = tokens[max(0, i - 3):i]
        for prior in window:
            if prior in NEGATORS:
                weight *= -0.85
            weight *= INTENSIFIERS.get(prior, 1.0)
        total += weight
        hits += 1
    if not hits:
        return 0.0
    # Normalise by a soft document length so a long bullish transcript does not
    # swamp a short bullish headline.
    denom = max(hits, math.sqrt(len(tokens)))
    return max(-1.0, min(1.0, total / (denom * 1.35)))


def sentiment_label(score: float) -> str:
    if score >= 0.18:
        return "positive"
    if score <= -0.18:
        return "negative"
    return "neutral"


def expand_query_terms(terms: Sequence[str]) -> list[str]:
    """Add lexicon synonyms for each term, preserving order and uniqueness."""
    out: list[str] = []
    seen: set[str] = set()
    for term in terms:
        key = term.lower()
        for candidate in (key, *SYNONYMS.get(key, ())):
            if candidate not in seen:
                seen.add(candidate)
                out.append(candidate)
    return out


@dataclass
class Corpus:
    """Document-frequency statistics used for tf-idf keywording."""

    doc_count: int = 0
    doc_freq: Counter[str] = field(default_factory=Counter)

    def add(self, text: str) -> None:
        self.doc_count += 1
        for token in set(content_tokens(text)):
            self.doc_freq[token] += 1

    def idf(self, token: str) -> float:
        return math.log((1 + self.doc_count) / (1 + self.doc_freq.get(token, 0))) + 1.0


def keywords(text: str, corpus: Corpus | None = None, limit: int = 8) -> list[tuple[str, float]]:
    """Top tf-idf unigrams and bigrams for a piece of text.

    Sublinear term frequency with a minimum-count floor on longer texts: without
    the floor, every word that happens to appear exactly once ties on score and
    the result degenerates into an alphabetical list of rare noise.
    """
    tokens = content_tokens(text)
    if not tokens:
        return []
    counts = Counter(tokens)
    min_count = 2 if len(tokens) >= 90 else 1
    candidates = {t: c for t, c in counts.items() if c >= min_count} or dict(counts)

    def idf(token: str) -> float:
        return corpus.idf(token) if corpus else 1.0

    scores: dict[str, float] = {
        token: (1.0 + math.log(count)) * idf(token) for token, count in candidates.items()
    }
    for gram, count in Counter(f"{a} {b}" for a, b in zip(tokens, tokens[1:])).items():
        if count < max(2, min_count):
            continue
        left, right = gram.split(" ", 1)
        scores[gram] = (1.0 + math.log(count)) * 1.45 * (idf(left) + idf(right)) / 2
    ranked = sorted(scores.items(), key=lambda kv: (-kv[1], -counts.get(kv[0], 0), kv[0]))
    return ranked[:limit]


def summarize(text: str, limit: int = 4, query_terms: Sequence[str] = ()) -> list[str]:
    """Extractive summary: rank sentences by keyword mass, position and query hit.

    Returns sentences in their original order so the summary still reads as prose.
    """
    sents = sentences(text)
    if not sents:
        return []
    if len(sents) <= limit:
        return sents
    weights = Counter(content_tokens(text))
    query_set = {t.lower() for t in query_terms}
    scored: list[tuple[float, int, str]] = []
    for idx, sentence in enumerate(sents):
        toks = content_tokens(sentence)
        if not toks:
            continue
        mass = sum(weights[t] for t in toks) / math.sqrt(len(toks))
        position_bonus = 1.25 if idx == 0 else (1.1 if idx < 3 else 1.0)
        query_bonus = 1.5 if query_set & set(toks) else 1.0
        numeric_bonus = 1.15 if re.search(r"\d", sentence) else 1.0
        scored.append((mass * position_bonus * query_bonus * numeric_bonus, idx, sentence))
    top = sorted(scored, key=lambda s: -s[0])[:limit]
    return [sentence for _, _, sentence in sorted(top, key=lambda s: s[1])]


def extract_kpis(text: str) -> list[dict[str, object]]:
    """Pull numeric KPIs out of narrative text with the sentence as context."""
    found: list[dict[str, object]] = []
    for sentence in sentences(text) or [text]:
        for metric, pattern, unit in KPI_PATTERNS:
            for match in pattern.finditer(sentence):
                raw = match.group(1).replace(",", "")
                try:
                    value = float(raw)
                except ValueError:
                    continue
                if unit == "currency" and re.search(r"billion|bn\b|\bb\b", match.group(0), re.I):
                    value *= 1000.0  # normalise to millions
                found.append({
                    "metric": metric,
                    "value": value,
                    "unit": "USDm" if unit == "currency" else unit,
                    "context": sentence.strip(),
                })
    return found


def cosine_similarity(a: Counter[str], b: Counter[str]) -> float:
    if not a or not b:
        return 0.0
    common = set(a) & set(b)
    num = sum(a[t] * b[t] for t in common)
    if not num:
        return 0.0
    den = math.sqrt(sum(v * v for v in a.values())) * math.sqrt(sum(v * v for v in b.values()))
    return num / den if den else 0.0


def vector(text: str, corpus: Corpus | None = None) -> Counter[str]:
    counts = Counter(content_tokens(text))
    if corpus is None:
        return counts
    return Counter({t: c * corpus.idf(t) for t, c in counts.items()})


def theme_trends(
    recent: Iterable[str], baseline: Iterable[str], limit: int = 10, min_recent: int = 2
) -> list[dict[str, object]]:
    """Themes over-represented in ``recent`` text versus a ``baseline`` period.

    Lift is a ratio of normalised document frequencies, which is what makes a
    theme read as "emerging" rather than merely common. Bigrams are scored
    alongside unigrams because "interconnection queue" is a theme while
    "queue" on its own is barely a word.
    """

    def features(text: str) -> set[str]:
        tokens = content_tokens(text)
        grams = {f"{a} {b}" for a, b in zip(tokens, tokens[1:])}
        return set(tokens) | grams

    recent_counts: Counter[str] = Counter()
    recent_docs = 0
    for text in recent:
        recent_docs += 1
        recent_counts.update(features(text))
    base_counts: Counter[str] = Counter()
    base_docs = 0
    for text in baseline:
        base_docs += 1
        base_counts.update(features(text))

    recent_docs = max(1, recent_docs)
    base_docs = max(1, base_docs)
    # Require more supporting documents as the window grows: in a large window a
    # phrase appearing twice is noise, in a small one it is the whole signal.
    floor = max(min_recent, round(recent_docs / 12) or min_recent)
    rows: list[dict[str, object]] = []
    for token, count in recent_counts.items():
        if count < floor:
            continue
        recent_rate = count / recent_docs
        base_rate = base_counts.get(token, 0) / base_docs
        lift = recent_rate / base_rate if base_rate else float(1 + count)
        is_phrase = " " in token
        rows.append({
            "theme": token,
            "mentions": count,
            "prior_mentions": base_counts.get(token, 0),
            "lift": round(lift, 2),
            # Phrases are more informative per character than single tokens, and
            # a theme carried by more documents outranks one carried by two.
            "rank": round(lift * (1.25 if is_phrase else 1.0) * (1 + 0.4 * math.log(count)), 3),
        })
    rows.sort(key=lambda r: (-float(r["rank"]), -int(r["mentions"]), str(r["theme"])))
    return _dedupe_themes(rows, limit)


def _dedupe_themes(rows: list[dict[str, object]], limit: int) -> list[dict[str, object]]:
    """Drop themes contained in another accepted theme.

    Without this the top of the list reads "constraint pricing, transmission
    constraint, constraint, transmission" — four slots spent on one idea.
    Phrases are considered first, then single tokens that no accepted phrase
    already covers.
    """
    accepted: list[tuple[set[str], dict[str, object]]] = []

    def consider(row: dict[str, object]) -> None:
        tokens = set(str(row["theme"]).split())
        for existing, _ in accepted:
            if tokens <= existing or existing <= tokens:
                return
        accepted.append((tokens, row))

    for row in rows:
        if " " in str(row["theme"]):
            consider(row)
    for row in rows:
        if " " not in str(row["theme"]):
            consider(row)
    chosen = [row for _, row in accepted]
    chosen.sort(key=lambda r: (-float(r["rank"]), -int(r["mentions"]), str(r["theme"])))
    return chosen[:limit]
