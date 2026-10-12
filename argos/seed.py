"""Deterministic demo dataset.

Every company, filing, transcript and broker note below is fictional and
generated locally from a fixed seed. It exists so the research index, the comps
screen and the valuation models have something real-shaped to chew on out of the
box; swap it for your own corpus with ``argos ingest <path>``.

The generator deliberately builds a *narrative arc* across periods — grid
interconnection backlogs and datacenter load growth become dominant themes late
in the window while pricing pressure builds — so trending-theme detection and
sentiment timelines have signal to find rather than noise.
"""

from __future__ import annotations

import random
import sqlite3
from datetime import date, timedelta
from typing import Any, Iterator

from .db import insert, upsert_company
from .ingest import ingest_many

SECTOR = "Grid & Energy Software"

COMPANIES: tuple[dict[str, Any], ...] = (
    {
        "ticker": "NVG", "name": "NovaGrid Systems", "industry": "Grid orchestration software",
        "country": "United States", "hq": "Austin, TX", "employees": 4280,
        "description": (
            "NovaGrid Systems sells a cloud platform that utilities and large industrial "
            "consumers use to forecast load, schedule distributed energy resources and "
            "settle wholesale market positions. Roughly 78% of revenue is recurring "
            "subscription, with the balance in implementation services."
        ),
        "fin": {"revenue": 1840.0, "growth": 0.168, "ebitda_margin": 0.262, "da_pct": 0.052,
                "capex_pct": 0.041, "shares": 182.0, "net_debt": 410.0,
                "ev_ebitda_target": 17.5, "beta": 1.21},
        "tone": 0.55,
    },
    {
        "ticker": "HLDX", "name": "Helio Dynamics", "industry": "DER management software",
        "country": "United States", "hq": "San Jose, CA", "employees": 3110,
        "description": "Helio Dynamics provides distributed energy resource management and virtual power plant software to investor-owned utilities.",
        "fin": {"revenue": 1320.0, "growth": 0.142, "ebitda_margin": 0.238, "da_pct": 0.049,
                "capex_pct": 0.038, "shares": 141.0, "net_debt": 260.0,
                "ev_ebitda_target": 16.0, "beta": 1.14},
        "tone": 0.35,
    },
    {
        "ticker": "VLTR", "name": "Voltara Networks", "industry": "Grid telemetry & analytics",
        "country": "United States", "hq": "Denver, CO", "employees": 5640,
        "description": "Voltara Networks combines grid-edge sensors with an analytics suite for outage prediction and asset health.",
        "fin": {"revenue": 2410.0, "growth": 0.096, "ebitda_margin": 0.281, "da_pct": 0.061,
                "capex_pct": 0.058, "shares": 238.0, "net_debt": 980.0,
                "ev_ebitda_target": 14.5, "beta": 1.02},
        "tone": 0.15,
    },
    {
        "ticker": "CRGD", "name": "Cerulean Grid", "industry": "Market settlement software",
        "country": "United Kingdom", "hq": "London, UK", "employees": 1980,
        "description": "Cerulean Grid runs trading, scheduling and settlement systems for European balancing markets.",
        "fin": {"revenue": 860.0, "growth": 0.201, "ebitda_margin": 0.221, "da_pct": 0.044,
                "capex_pct": 0.036, "shares": 96.0, "net_debt": 95.0,
                "ev_ebitda_target": 18.5, "beta": 1.33},
        "tone": 0.60,
    },
    {
        "ticker": "PYLN", "name": "Pylon Analytics", "industry": "Transmission planning software",
        "country": "United States", "hq": "Pittsburgh, PA", "employees": 1240,
        "description": "Pylon Analytics licenses transmission planning, interconnection study and congestion modelling tools.",
        "fin": {"revenue": 520.0, "growth": 0.247, "ebitda_margin": 0.184, "da_pct": 0.040,
                "capex_pct": 0.033, "shares": 71.0, "net_debt": -60.0,
                "ev_ebitda_target": 20.0, "beta": 1.42},
        "tone": 0.70,
    },
    {
        "ticker": "TWSW", "name": "Terrawatt Software", "industry": "Renewables asset management",
        "country": "Germany", "hq": "Munich, DE", "employees": 2870,
        "description": "Terrawatt Software manages renewable generation fleets, PPAs and curtailment optimisation for IPPs.",
        "fin": {"revenue": 1150.0, "growth": 0.071, "ebitda_margin": 0.196, "da_pct": 0.055,
                "capex_pct": 0.047, "shares": 128.0, "net_debt": 520.0,
                "ev_ebitda_target": 11.5, "beta": 1.09},
        "tone": -0.30,
    },
    {
        "ticker": "MFCL", "name": "Meridian Flow Controls", "industry": "Industrial control software",
        "country": "United States", "hq": "Milwaukee, WI", "employees": 7320,
        "description": "Meridian Flow Controls sells SCADA and control software bundled with legacy hardware service contracts.",
        "fin": {"revenue": 3080.0, "growth": 0.034, "ebitda_margin": 0.173, "da_pct": 0.068,
                "capex_pct": 0.062, "shares": 311.0, "net_debt": 1640.0,
                "ev_ebitda_target": 9.0, "beta": 0.91},
        "tone": -0.45,
    },
)

TRANSACTIONS: tuple[dict[str, Any], ...] = (
    {"announced_on": "2026-06-18", "target": "Arclight Grid Software", "acquirer": "Siemens-adjacent strategic",
     "sector": SECTOR, "ev": 4100.0, "ev_revenue": 6.4, "ev_ebitda": 22.8, "premium_1day": 0.31,
     "consideration": "Cash", "note": "Full-cash take-private of a subscription-heavy grid planning vendor."},
    {"announced_on": "2026-02-04", "target": "Keystone DERMS", "acquirer": "Thoma-style sponsor",
     "sector": SECTOR, "ev": 2250.0, "ev_revenue": 5.1, "ev_ebitda": 19.4, "premium_1day": 0.27,
     "consideration": "Cash", "note": "Sponsor LBO; carve-out of services backlog pre-close."},
    {"announced_on": "2025-11-12", "target": "Lumen Flow Systems", "acquirer": "Strategic acquirer (industrial)",
     "sector": SECTOR, "ev": 1480.0, "ev_revenue": 4.2, "ev_ebitda": 16.1, "premium_1day": 0.22,
     "consideration": "Cash and stock", "note": "Hardware-weighted mix drove a lower multiple."},
    {"announced_on": "2025-07-29", "target": "Meridian Analytics (division)", "acquirer": "Private equity consortium",
     "sector": SECTOR, "ev": 910.0, "ev_revenue": 3.6, "ev_ebitda": 14.2, "premium_1day": 0.18,
     "consideration": "Cash", "note": "Divisional carve-out with TSA; limited competitive tension."},
    {"announced_on": "2025-03-20", "target": "Quanta Settlement Co", "acquirer": "Exchange operator",
     "sector": SECTOR, "ev": 3350.0, "ev_revenue": 7.1, "ev_ebitda": 24.6, "premium_1day": 0.38,
     "consideration": "Stock", "note": "Scarcity premium for regulated settlement infrastructure."},
    {"announced_on": "2024-10-08", "target": "Northwind Interconnect", "acquirer": "Strategic acquirer (software)",
     "sector": SECTOR, "ev": 1720.0, "ev_revenue": 5.6, "ev_ebitda": 20.1, "premium_1day": 0.29,
     "consideration": "Cash", "note": "Two-bidder process; synergies underwritten at 7% of target revenue."},
)

PERIODS: tuple[tuple[str, str], ...] = (
    ("FY24 Q3", "2024-10-24"), ("FY24 Q4", "2025-01-30"),
    ("FY25 Q1", "2025-04-24"), ("FY25 Q2", "2025-07-24"),
    ("FY25 Q3", "2025-10-23"), ("FY25 Q4", "2026-01-29"),
    ("FY26 Q1", "2026-04-23"), ("FY26 Q2", "2026-07-23"),
)

# Theme pressure by period index: late periods lean on interconnection backlog,
# datacenter load growth and tariff pass-through.
EARLY_THEMES = (
    "storm hardening programmes", "meter data management migrations",
    "regulatory rate case timing", "legacy SCADA replacement cycles",
)
LATE_THEMES = (
    "interconnection queue backlog", "datacenter load growth",
    "tariff pass-through on imported hardware", "transmission constraint pricing",
)

POSITIVE_SENTENCES = (
    "Revenue grew {growth:.1f}% year over year, ahead of the guidance range we set last quarter.",
    "Subscription net dollar retention was {ndr:.0f}%, with expansion concentrated in our largest utility accounts.",
    "Adjusted EBITDA margin reached {margin:.1f}%, an improvement of {bps:.0f} basis points, on pricing discipline and lower cloud unit costs.",
    "Bookings momentum was strong across {theme}, and we exited the quarter with backlog of ${backlog:.0f} million.",
    "We are raising our full-year outlook on the strength of the pipeline we see in {theme}.",
    "Free cash flow was ${fcf:.0f} million, and we repurchased shares opportunistically during the quarter.",
    "Gross margin reached {gm:.1f}% as more of the mix shifted toward platform subscriptions.",
)
NEUTRAL_SENTENCES = (
    "We closed {wins} new platform agreements in the quarter, weighted toward North American investor-owned utilities.",
    "Implementation timelines remain tied to customer rate case calendars, which we model conservatively.",
    "Headcount ended the period at {headcount} employees, broadly flat sequentially.",
    "Capex was {capex:.1f}% of revenue, consistent with our prior commentary.",
    "Our product roadmap this year centres on {theme} and on deeper integration with market settlement systems.",
    "We continue to evaluate tuck-in acquisitions that add engineering capacity in {theme}.",
)
NEGATIVE_SENTENCES = (
    "Revenue declined {decline:.1f}% as two large deployments slipped out of the quarter.",
    "We saw pricing pressure in competitive renewals, and churn ticked up to {churn:.1f}%.",
    "Adjusted EBITDA margin compressed to {margin:.1f}% on higher services mix and cloud cost inflation.",
    "Guidance assumes continued softness in {theme}, and we have taken a cautious view of second-half bookings.",
    "The macro environment remains uncertain, and procurement cycles have lengthened materially.",
    "A restructuring charge of ${charge:.0f} million was recorded as we consolidated delivery centres.",
    "Deceleration in new logo activity was the main driver of the shortfall versus consensus.",
)
ANALYST_QUESTIONS = (
    "Can you unpack the margin trajectory from here, and how much of the improvement is durable versus timing?",
    "How should we think about the pipeline conversion in {theme} over the next two quarters?",
    "What are you assuming for pricing in competitive renewals, and where is churn running?",
    "Is the services mix a structural headwind to gross margin, or does it normalise as deployments mature?",
    "Could you size the revenue opportunity tied to {theme}?",
)
RESEARCH_VIEWS = (
    ("Overweight", "We raise our target on {name} as subscription mix and pricing discipline underwrite a durable "
                   "margin expansion path. Our model assumes {growth:.1f}% revenue growth and {margin:.1f}% EBITDA "
                   "margin, supported by {theme}. Risks are concentrated in deployment timing."),
    ("Neutral", "We stay sidelined on {name}. The {theme} narrative is real but already discounted at {mult:.1f}x "
                "forward EBITDA, and services mix keeps gross margin range-bound. We would revisit on evidence of "
                "net retention above 112%."),
    ("Underweight", "We downgrade {name}. Pricing pressure in competitive renewals and an elongating sales cycle "
                    "point to decelerating bookings, and consensus margin assumptions of {margin:.1f}% look "
                    "optimistic given cloud cost inflation and a weaker mix in {theme}."),
)
NEWS_HEADLINES = (
    ("{name} wins multi-year grid orchestration contract", "A top-ten investor-owned utility selected {name} to run load forecasting and DER scheduling across its service territory. The award covers {years} years and is expected to be accretive to backlog."),
    ("{name} flags longer procurement cycles", "Management told investors that utility procurement cycles have lengthened, citing regulatory calendars and tariff uncertainty on imported hardware. Shares traded lower on the commentary."),
    ("{name} expands {theme} product line", "The company launched a module targeting {theme}, pricing it as a platform upgrade rather than a standalone product."),
    ("{name} named in sector consolidation chatter", "Bankers covering {sector} pointed to {name} as a plausible participant in further consolidation after recent take-private activity in the space."),
)
FILING_RISK_FACTORS = (
    "Our revenue is concentrated among regulated utilities whose spending is subject to rate case outcomes and commission approval timing.",
    "A meaningful portion of our contracts include annual price escalators tied to published indices; a sustained decline in those indices would reduce realised pricing.",
    "We depend on third-party cloud infrastructure providers, and cost inflation in those services may compress gross margin.",
    "Interconnection queue backlogs and permitting delays may defer customer projects and therefore our implementation revenue.",
    "Tariffs on imported sensing and metering hardware could increase the cost of bundled deployments and pressure margins.",
    "We face competition from larger industrial automation vendors that bundle control software with hardware service contracts.",
)


def _derive_market(spec: dict[str, Any], rng: random.Random) -> dict[str, Any]:
    """Derive share price and 52-week range from a target EV/EBITDA multiple.

    Pricing the demo set off a multiple (rather than hardcoding share prices)
    keeps the comps screen internally consistent: implied multiples land where
    the quality spread says they should, instead of wherever a made-up price
    happened to fall.
    """
    fin = spec["fin"]
    ebitda = fin["revenue"] * fin["ebitda_margin"]
    enterprise_value = fin["ev_ebitda_target"] * ebitda
    price = max(1.0, (enterprise_value - fin["net_debt"]) / fin["shares"])
    return {
        "price": round(price, 2),
        "low": round(price * rng.uniform(0.68, 0.78), 2),
        "high": round(price * rng.uniform(1.04, 1.18), 2),
    }


def _fy_from_period(period: str) -> int:
    return 2000 + int(period[2:4])


def _financial_series(spec: dict[str, Any], years: tuple[int, ...]) -> Iterator[dict[str, Any]]:
    """Back-cast and forecast a simple financial series around the base year."""
    base_year = years[len(years) // 2]
    for year in years:
        drift = spec["growth"] * (0.82 if year > base_year else 1.0)
        factor = (1 + drift) ** (year - base_year)
        revenue = spec["revenue"] * factor
        margin = spec["ebitda_margin"] + 0.004 * (year - base_year)
        ebitda = revenue * margin
        dep_amort = revenue * spec["da_pct"]
        ebit = ebitda - dep_amort
        tax_rate = 0.23
        net_income = max(0.0, ebit * (1 - tax_rate)) - max(0.0, spec["net_debt"]) * 0.045 * (1 - tax_rate)
        yield {
            "fiscal_year": year,
            "is_estimate": 1 if year > base_year else 0,
            "revenue": round(revenue, 1),
            "ebitda": round(ebitda, 1),
            "ebit": round(ebit, 1),
            "net_income": round(net_income, 1),
            "eps": round(net_income / spec["shares"], 2),
            "dep_amort": round(dep_amort, 1),
            "capex": round(revenue * spec["capex_pct"], 1),
            "nwc_change": round(revenue * 0.012, 1),
            "tax_rate": tax_rate,
        }


def _transcript(rng: random.Random, spec: dict[str, Any], period: str, when: str, theme: str, tone: float) -> dict[str, Any]:
    fin = spec["fin"]
    numbers = {
        "growth": max(1.0, fin["growth"] * 100 + rng.uniform(-3.5, 3.5)),
        "decline": abs(rng.uniform(1.5, 7.5)),
        "ndr": 100 + tone * 14 + rng.uniform(-3, 5),
        "margin": fin["ebitda_margin"] * 100 + tone * 2.2 + rng.uniform(-1.5, 1.5),
        "bps": abs(tone) * 180 + rng.uniform(20, 120),
        "gm": 62 + tone * 6 + rng.uniform(-2, 3),
        "backlog": fin["revenue"] * rng.uniform(0.55, 0.95),
        "fcf": fin["revenue"] * fin["ebitda_margin"] * rng.uniform(0.45, 0.75),
        "churn": 4.5 - tone * 1.6 + rng.uniform(-0.6, 0.9),
        "wins": rng.randint(4, 23),
        "headcount": spec["employees"] + rng.randint(-220, 320),
        "capex": fin["capex_pct"] * 100 + rng.uniform(-0.6, 0.8),
        "charge": fin["revenue"] * rng.uniform(0.01, 0.035),
        "theme": theme,
        "name": spec["name"],
    }

    def pick(bank: tuple[str, ...], count: int) -> list[str]:
        return [s.format(**numbers) for s in rng.sample(bank, min(count, len(bank)))]

    if tone > 0.2:
        ceo_lines = pick(POSITIVE_SENTENCES, 3) + pick(NEUTRAL_SENTENCES, 1)
        cfo_lines = pick(POSITIVE_SENTENCES, 2) + pick(NEUTRAL_SENTENCES, 2)
    elif tone < -0.2:
        ceo_lines = pick(NEGATIVE_SENTENCES, 3) + pick(NEUTRAL_SENTENCES, 1)
        cfo_lines = pick(NEGATIVE_SENTENCES, 2) + pick(NEUTRAL_SENTENCES, 2)
    else:
        ceo_lines = pick(NEUTRAL_SENTENCES, 2) + pick(POSITIVE_SENTENCES, 1) + pick(NEGATIVE_SENTENCES, 1)
        cfo_lines = pick(NEUTRAL_SENTENCES, 2) + pick(POSITIVE_SENTENCES, 1)

    question = rng.choice(ANALYST_QUESTIONS).format(**numbers)
    answer = " ".join(pick(POSITIVE_SENTENCES if tone >= 0 else NEGATIVE_SENTENCES, 2))
    body = "\n\n".join([
        "Operator: Good morning, and welcome to the "
        f"{spec['name']} {period} earnings conference call. All participants are in listen-only mode.",
        f"Avery Lin, Chief Executive Officer: Thanks, everyone, for joining. {' '.join(ceo_lines)}",
        f"Dana Okafor, Chief Financial Officer: Turning to the financials. {' '.join(cfo_lines)} "
        f"For the full year we now expect revenue growth in the {numbers['growth'] - 1.5:.0f} to "
        f"{numbers['growth'] + 1.5:.0f}% range.",
        f"Priya Raman, Analyst, Northbank Securities: {question}",
        f"Avery Lin, Chief Executive Officer: {answer}",
        f"Dana Okafor, Chief Financial Officer: To add to that, our planning assumption on {theme} is deliberately "
        f"conservative, and we have not embedded upside from it in the guidance range.",
    ])
    return {
        "external_id": f"{spec['ticker']}-{period.replace(' ', '')}-call",
        "title": f"{spec['name']} {period} Earnings Call Transcript",
        "ticker": spec["ticker"],
        "doc_type": "transcript",
        "source": "Company call",
        "author": "Investor Relations",
        "published_at": when,
        "period": period,
        "body": body,
    }


def _research_note(rng: random.Random, spec: dict[str, Any], when: str, theme: str, tone: float) -> dict[str, Any]:
    fin = spec["fin"]
    rating, template = RESEARCH_VIEWS[0] if tone > 0.25 else (RESEARCH_VIEWS[2] if tone < -0.25 else RESEARCH_VIEWS[1])
    numbers = {
        "name": spec["name"], "theme": theme,
        "growth": fin["growth"] * 100 + rng.uniform(-2, 2),
        "margin": fin["ebitda_margin"] * 100 + rng.uniform(-1.5, 1.5),
        "mult": 12 + tone * 5 + rng.uniform(-1.5, 2.5),
    }
    body = "\n\n".join([
        f"Rating: {rating}. Price target ${fin['price'] * (1 + tone * 0.18):.0f}.",
        template.format(**numbers),
        f"Valuation. We value {spec['name']} on {numbers['mult']:.1f}x forward EV/EBITDA, a "
        f"{'premium' if tone > 0 else 'discount'} to the {SECTOR.lower()} peer median, reflecting subscription mix "
        f"of roughly {60 + tone * 20:.0f}% and net debt of ${fin['net_debt']:.0f} million.",
        f"What would change our view. Evidence that {theme} converts to multi-year platform contracts would raise our "
        "estimates; a second consecutive quarter of pricing pressure in renewals would lower them.",
    ])
    return {
        "external_id": f"{spec['ticker']}-research-{when}",
        "title": f"{spec['name']} ({spec['ticker']}): {rating} — {theme.title()}",
        "ticker": spec["ticker"],
        "doc_type": "research",
        "source": "Northbank Securities",
        "author": "P. Raman",
        "published_at": when,
        "body": body,
    }


def _filing(spec: dict[str, Any], year: int, when: str) -> dict[str, Any]:
    fin = spec["fin"]
    body = "\n\n".join([
        f"Item 1. Business. {spec['description']}",
        f"Item 7. Management's Discussion and Analysis. Revenue for fiscal {year} was ${fin['revenue']:.0f} million, "
        f"an increase of {fin['growth'] * 100:.1f}% over the prior year. Adjusted EBITDA margin was "
        f"{fin['ebitda_margin'] * 100:.1f}%. Capex was {fin['capex_pct'] * 100:.1f}% of revenue. We ended the year "
        f"with net debt of ${fin['net_debt']:.0f} million and {spec['employees']} employees.",
        "Item 1A. Risk Factors. " + " ".join(FILING_RISK_FACTORS),
        f"Item 7A. Quantitative and Qualitative Disclosures About Market Risk. Our reported results are exposed to "
        f"currency movements, principally in EUR and GBP, and to floating-rate interest expense on our revolving "
        f"credit facility.",
    ])
    return {
        "external_id": f"{spec['ticker']}-10K-{year}",
        "title": f"{spec['name']} Annual Report (Form 10-K), FY{year}",
        "ticker": spec["ticker"],
        "doc_type": "filing",
        "source": "Regulatory filing",
        "published_at": when,
        "body": body,
    }


def _news(rng: random.Random, spec: dict[str, Any], when: str, theme: str) -> dict[str, Any]:
    headline, template = rng.choice(NEWS_HEADLINES)
    fields = {"name": spec["name"], "theme": theme, "sector": SECTOR, "years": rng.randint(3, 8)}
    return {
        "external_id": f"{spec['ticker']}-news-{when}-{rng.randint(1000, 9999)}",
        "title": headline.format(**fields),
        "ticker": spec["ticker"],
        "doc_type": "news",
        "source": "Market wire",
        "published_at": when,
        "body": template.format(**fields) + "\n\n" + (
            f"{spec['name']} trades at ${spec['fin']['price']:.2f}, within a 52-week range of "
            f"${spec['fin']['low']:.2f} to ${spec['fin']['high']:.2f}."
        ),
    }


def _expert_call(rng: random.Random, when: str, theme: str) -> dict[str, Any]:
    body = "\n\n".join([
        "Interviewer: You spent eleven years on the procurement side at a large investor-owned utility. How do "
        "software vendors actually get selected?",
        f"Expert: Almost everything flows through the rate case. If the spend is not in an approved plan, it does not "
        f"happen, regardless of the payback. What has changed in the last year is {theme} — that pressure is now "
        f"showing up as capital plan line items, which pulls software decisions forward.",
        "Interviewer: Where does pricing pressure come from?",
        "Expert: Competitive renewals. The incumbents know the switching cost is high, so list price escalators hold, "
        "but when an industrial automation vendor bundles control software with a hardware service contract, the "
        "effective discount can reach twenty percent. That is the real pricing pressure in this market, and it is "
        "under-appreciated.",
        f"Interviewer: Which capability is scarce? Expert: Anyone who can model {theme} credibly for a regulator. "
        "That is a small pool of engineers, and it is why tuck-in acquisitions in this space are priced on talent, "
        "not on revenue.",
    ])
    return {
        "external_id": f"expert-{when}-{rng.randint(1000, 9999)}",
        "title": f"Expert Call: Utility Procurement and {theme.title()}",
        "doc_type": "expert-call",
        "source": "Expert network",
        "published_at": when,
        "body": body,
    }


def seed_database(conn: sqlite3.Connection, *, rng_seed: int = 20261012) -> dict[str, Any]:
    """Populate companies, financials, market data, transactions and the corpus."""
    rng = random.Random(rng_seed)
    years = (2023, 2024, 2025, 2026, 2027, 2028)
    company_ids: dict[str, int] = {}
    specs = [{**spec, "fin": {**spec["fin"], **_derive_market(spec, rng)}} for spec in COMPANIES]

    for spec in specs:
        company_id = upsert_company(conn, {
            "ticker": spec["ticker"], "name": spec["name"], "sector": SECTOR,
            "industry": spec["industry"], "country": spec["country"], "hq": spec["hq"],
            "employees": spec["employees"], "currency": "USD", "description": spec["description"],
        })
        company_ids[spec["ticker"]] = company_id
        conn.execute("DELETE FROM financials WHERE company_id = ?", (company_id,))
        for row in _financial_series(spec["fin"], years):
            insert(conn, "financials", {"company_id": company_id, **row})
        fin = spec["fin"]
        conn.execute("DELETE FROM market_data WHERE company_id = ?", (company_id,))
        insert(conn, "market_data", {
            "company_id": company_id, "as_of": "2026-10-09", "share_price": fin["price"],
            "shares_diluted": fin["shares"], "net_debt": fin["net_debt"],
            "week52_low": fin["low"], "week52_high": fin["high"], "beta": fin["beta"],
        })

    if not conn.execute("SELECT 1 FROM transactions LIMIT 1").fetchone():
        for deal in TRANSACTIONS:
            insert(conn, "transactions", deal)

    documents: list[dict[str, Any]] = []
    for spec in specs:
        base_tone = spec["tone"]
        for idx, (period, when) in enumerate(PERIODS):
            late = idx >= len(PERIODS) - 3
            theme = rng.choice(LATE_THEMES if late else EARLY_THEMES)
            # Tone decays slightly over the window for everyone (pricing pressure)
            # and is jittered per quarter so sentiment timelines are not flat.
            tone = max(-1.0, min(1.0, base_tone - 0.07 * idx + rng.uniform(-0.18, 0.18)))
            documents.append(_transcript(rng, spec, period, when, theme, tone))
            if idx % 2 == 0:
                note_when = (date.fromisoformat(when) + timedelta(days=2)).isoformat()
                documents.append(_research_note(rng, spec, note_when, theme, tone))
            if idx % 3 == 1:
                news_when = (date.fromisoformat(when) + timedelta(days=rng.randint(6, 40))).isoformat()
                documents.append(_news(rng, spec, news_when, theme))
        filing_year = 2025
        documents.append(_filing(spec, filing_year, f"{filing_year + 1}-02-14"))

    for when, theme in (("2026-03-05", LATE_THEMES[0]), ("2026-06-11", LATE_THEMES[1]),
                        ("2025-09-17", EARLY_THEMES[0]), ("2026-08-28", LATE_THEMES[2])):
        documents.append(_expert_call(rng, when, theme))

    result = ingest_many(conn, documents)
    conn.commit()
    return {
        "companies": len(company_ids),
        "transactions": conn.execute("SELECT COUNT(*) FROM transactions").fetchone()[0],
        "documents_added": result["added"],
        "documents_skipped": result["skipped"],
        "chunks": conn.execute("SELECT COUNT(*) FROM chunks").fetchone()[0],
        "kpis": conn.execute("SELECT COUNT(*) FROM kpis").fetchone()[0],
    }
