"""Argos — research intelligence and pitch book generation in one application.

Two modules share one data model:

* ``alpha`` side: ingest a corpus of filings, transcripts, broker research and
  news; search it; extract KPIs, sentiment and emerging themes.
* ``pitchbook`` side: turn companies, market data and the evidence surfaced by
  the research module into a banker-ready deck with comps, precedent
  transactions, a DCF and a football field valuation.
"""

__version__ = "1.0.0"
__all__ = ["__version__"]
