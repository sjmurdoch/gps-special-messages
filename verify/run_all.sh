#!/usr/bin/env bash
# Run every claim-level verifier against data/messages.duckdb.
#
# Each verify/<name>.jl asserts a specific quantitative claim from the
# article (mapped to its verifier in CLAIMS.md) and exits non-zero with a
# diagnostic on divergence.  This wrapper runs all of them, prints
# a summary, and exits non-zero if any fail.
#
# Usage:
#   verify/run_all.sh                    # default DB path (data/messages.duckdb)
#   verify/run_all.sh /path/to/db.duckdb # explicit DB file
#   verify/run_all.sh /path/to/repo      # explicit repo root (DB resolved under it)
#
# Environment:
#   JULIA   override julia binary (default: `julia` on PATH)
#   DB      override DB path (default: data/messages.duckdb); takes precedence
#           over any positional argument.

set -uo pipefail

# The positional argument may be either a repo root (directory) or a DB file.
# Detect a file and treat it as the DB so that, e.g.,
# `verify/run_all.sh data/messages.duckdb` does the obvious thing.
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

scripts=(
    corpus_totals
    chi_squared
    field_capacity
    fleet_flash_2011
    text_migration
    rotation_regimes
    message_diversity
    shared_substrings
    prn25_timeline
    sentinel_onset_2011
    sentinel_event_2020
    text_inception_2023
    text_timeline
    calendar_months
)

pass=0
fail=0
failed_scripts=()

for s in "${scripts[@]}"; do
    echo "════════════════════════════════════════════════════"
    echo "==> verify/$s.jl"
    echo "════════════════════════════════════════════════════"
    if "$JULIA" --project "verify/$s.jl" "$DB"; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        failed_scripts+=("$s")
    fi
    echo
done

total=$((pass + fail))
echo "════════════════════════════════════════════════════"
echo "Verifier summary: $pass / $total passed"
if (( fail > 0 )); then
    echo "Failed: ${failed_scripts[*]}"
    exit 1
fi
echo "All verifiers passed."
