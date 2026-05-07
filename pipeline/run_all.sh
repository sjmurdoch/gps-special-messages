#!/usr/bin/env bash
# Run the full pipeline: raw GFZ tars + NAVCEN advisories -> populated messages.duckdb.
# Each step prints an expected-value line to stderr; failures abort early.
#
# Usage:
#   pipeline/run_all.sh                         # default paths under data/
#   pipeline/run_all.sh /path/to/repo           # explicit repo root
#
# Environment:
#   JULIA   override julia binary (default: `julia` on PATH)
#   THREADS thread count for stages 03 and 04 (default: auto)

set -euo pipefail

REPO_ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$REPO_ROOT"

JULIA="${JULIA:-julia}"
THREADS="${THREADS:-auto}"

echo "==> Step 1/5: download raw GFZ navbit archives -> data/raw/" >&2
"$JULIA" --project pipeline/01_download_navbits.jl

echo "==> Step 2/5: decompress data/raw -> data/processed/" >&2
"$JULIA" --project pipeline/02_decompress.jl

echo "==> Step 3/5: convert NetCDF -> Arrow (data/processed -> data/arrow/)" >&2
"$JULIA" --project -t "$THREADS" pipeline/03_convert_to_arrow.jl

echo "==> Step 4/5: build DuckDB (data/arrow/ -> data/messages.duckdb)" >&2
"$JULIA" --project -t "$THREADS" pipeline/04_build_database.jl

echo "==> Step 5/5: download NAVCEN Operational Advisories -> data/ops_advisories/" >&2
"$JULIA" --project pipeline/05_download_ops_advisories.jl

echo "==> pipeline/run_all.sh: done" >&2
