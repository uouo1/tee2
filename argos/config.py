"""Runtime configuration, resolved from the environment with sane defaults."""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent


def _env_path(name: str, default: Path) -> Path:
    raw = os.environ.get(name)
    return Path(raw).expanduser().resolve() if raw else default


@dataclass(frozen=True)
class Config:
    """Everything the app needs to know about where things live."""

    db_path: Path = _env_path("ARGOS_DB", REPO_ROOT / "data" / "argos.db")
    seed_dir: Path = _env_path("ARGOS_SEED_DIR", REPO_ROOT / "data" / "seed")
    export_dir: Path = _env_path("ARGOS_EXPORT_DIR", REPO_ROOT / "data" / "exports")
    static_dir: Path = REPO_ROOT / "argos" / "static"
    host: str = os.environ.get("ARGOS_HOST", "127.0.0.1")
    port: int = int(os.environ.get("ARGOS_PORT", "8787"))

    # Search behaviour.
    snippet_tokens: int = 34
    max_results: int = 200
    # Valuation defaults, overridable per pitch book.
    default_wacc: float = 0.095
    default_terminal_growth: float = 0.025
    default_tax_rate: float = 0.23
    projection_years: int = 5

    def ensure_dirs(self) -> None:
        self.db_path.parent.mkdir(parents=True, exist_ok=True)
        self.export_dir.mkdir(parents=True, exist_ok=True)


CONFIG = Config()
