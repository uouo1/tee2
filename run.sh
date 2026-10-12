#!/usr/bin/env bash
# Seed the demo corpus on first run, then start the application.
set -euo pipefail
cd "$(dirname "$0")"
DB="${ARGOS_DB:-data/argos.db}"
if [ ! -f "$DB" ]; then
  echo "First run: building the demo corpus…"
  python3 -m argos seed
fi
exec python3 -m argos serve "$@"
