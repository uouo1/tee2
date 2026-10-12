"""Shared fixtures. Seeding costs a second or two, so each module seeds once."""

from __future__ import annotations

import sqlite3

from argos.db import open_db
from argos.seed import seed_database

_CACHE: dict[str, bytes] = {}


def seeded_connection() -> sqlite3.Connection:
    """A fresh in-memory database holding the demo corpus.

    The first call seeds and serialises the database; later calls deserialise
    that snapshot, so a module full of tests pays the seeding cost once while
    each test still gets an isolated connection it can write to.
    """
    conn = open_db(":memory:")
    if "snapshot" in _CACHE:
        conn.deserialize(_CACHE["snapshot"])
        return conn
    seed_database(conn)
    _CACHE["snapshot"] = conn.serialize()
    return conn


def empty_connection() -> sqlite3.Connection:
    return open_db(":memory:")
