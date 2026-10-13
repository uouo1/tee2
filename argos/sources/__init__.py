"""Loaders for real-world data.

Argos ships with a synthetic demo corpus so it runs offline, but it is built to
work on real filings. These modules pull public company data from SEC EDGAR and
public market quotes, and write them into the same tables the demo seeder uses.
"""

from .market import fetch_quote
from .sec import load_companies

__all__ = ["fetch_quote", "load_companies"]
