#!/usr/bin/env bash
# Run every claim-level verifier against data/messages.duckdb.
#
# Each verify/<name>.jl asserts a specific quantitative claim from
# analysis_results/feature-article.md and exits non-zero with a
# diagnostic on divergence.  This wrapper runs all of them, prints
# a summary, and exits non-zero if any fail.
#
# Usage:
#   verify/run_all.sh                    # default DB path
#   verify/run_all.sh /path/to/repo      # explicit repo root
#
# Environment:
#   JULIA   override julia binary (default: `julia` on PATH)
#   DB      override DB path (default: data/messages.duckdb)

set -uo pipefail

REPO_ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$REPO_ROOT"

JULIA="${JULIA:-julia}"
DB="${DB:-data/messages.duckdb}"

scripts=(
    corpus_totals
    chi_squared
    fleet_flash_2011
    text_migration
    rotation_regimes
    shared_substrings
    prn25_timeline
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
