#!/usr/bin/env bash
# Run every analysis script in turn, populating the DuckDB analysis tables and
# writing markdown reports to analysis/reports/. Assumes pipeline/04 has
# produced data/messages.duckdb and pipeline/05 has populated
# data/ops_advisories/.
#
# Usage:
#   analysis/run_all.sh                  # default paths under data/
#   analysis/run_all.sh /path/to/db.duckdb # explicit DB file
#   analysis/run_all.sh /repo/root       # explicit repo root
#
# Environment:
#   JULIA   override julia binary (default: `julia` on PATH)
#   DB      override DB path (default: data/messages.duckdb); takes precedence
#           over any positional argument.
#   OA_DIR  override ops-advisory dir (default: data/ops_advisories)

set -euo pipefail

# The positional argument may be either a repo root (directory) or a DB file.
SCRIPT_REPO="$(cd "$(dirname "$0")/.." && pwd)"
arg="${1:-}"
if [[ -n "$arg" && -f "$arg" ]]; then
    DB_ARG="$(cd "$(dirname "$arg")" && pwd)/$(basename "$arg")"
    REPO_ROOT="$SCRIPT_REPO"
else
    REPO_ROOT="${arg:-$SCRIPT_REPO}"
fi
cd "$REPO_ROOT"

JULIA="${JULIA:-julia}"
DB="${DB:-${DB_ARG:-data/messages.duckdb}}"
OA_DIR="${OA_DIR:-data/ops_advisories}"
REPORTS_DIR="analysis/reports"
mkdir -p "$REPORTS_DIR"

run() {
    echo "==> $*" >&2
    "$@"
}

echo "==> Step 0/7: wipe stale analysis-table contents (idempotent)" >&2
"$JULIA" --project -e '
using DuckDB
db = DuckDB.DB(ARGS[1])
# Delete in foreign-key-safe order (children before parents).
for sql in (
    "DELETE FROM change_point_nanu_correlations",
    "DELETE FROM sentinel_nanu_correlations",
    "DELETE FROM nanu_records",
    "DELETE FROM behavioral_change_points",
    "DELETE FROM behavioral_metrics",
)
    try
        DBInterface.execute(db, sql)
    catch err
        if !occursin("does not exist", sprint(showerror, err))
            rethrow()
        end
    end
end
DBInterface.close!(db)
' "$DB"

echo "==> Step 1/7: duplicates audit" >&2
run "$JULIA" --project analysis/duplicates_audit.jl "$DB"

echo "==> Step 2/7: behavioral changes (CUSUM)" >&2
run "$JULIA" --project analysis/behavioral_changes.jl "$DB"

echo "==> Step 3/7: NANU correlation" >&2
run "$JULIA" --project analysis/nanu_correlation.jl "$DB" "$OA_DIR"

echo "==> Step 4/7: sentinel–NANU correlation" >&2
run "$JULIA" --project analysis/sentinel_nanu.jl "$DB" "$OA_DIR"

echo "==> Step 5/7: OTAD hypothesis" >&2
run "$JULIA" --project analysis/otad_hypothesis.jl "$DB"

echo "==> Step 6/7: statistical significance" >&2
run "$JULIA" --project analysis/statistical_significance.jl "$DB"

echo "==> Step 7/7: marginal entropy (PPM-D order 8)" >&2
run "$JULIA" --project analysis/marginal_entropy_ppm.jl "$DB" 8

echo "==> analysis/run_all.sh: done" >&2
