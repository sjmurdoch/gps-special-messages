#!/usr/bin/env julia
#
# Verify the five shared-substring pairs (lengths 7–10) found by the
# PPM-D order-8 marginal-entropy analysis.
#
# Reference: feature-article.md §8 (footnote 40); analysis/reports/
# marginal_entropy_ppm.txt section "REPEATING SUBSTRINGS".
#
# Each substring is asserted to appear in exactly two distinct ascii_messages
# in the corpus.  We don't re-run PPM-D here (5+ minutes); the SQL `LIKE`
# check is independent and cheap.
#
# Usage:
#   julia --project verify/shared_substrings.jl [data/messages.duckdb]

using DuckDB

const DB_PATH = length(ARGS) >= 1 ? ARGS[1] : "data/messages.duckdb"
isfile(DB_PATH) || (println(stderr, "Error: '$DB_PATH' not found"); exit(2))

# (length, substring) — ° renders as CP437 0xF8 in the ASCII column.
const PAIRS = [
    (10, ".'HX-+7UX "),
    ( 9, "LY47IRP16"),
    ( 9, ":U'5PSF8T"),
    ( 9, "ZU°SGZ8PJ"),
    ( 7, "S°6L.D°"),
]

function main()
    db = DuckDB.DB(DB_PATH; readonly=true)
    stmt = DBInterface.prepare(db,
        "SELECT COUNT(DISTINCT ascii_message) AS n FROM special_messages WHERE ascii_message LIKE ?")
    ok = true
    for (len, sub) in PAIRS
        n = Int((DBInterface.execute(stmt, ["%" * sub * "%"]) |> first).n)
        same = n == 2 && length(sub) == len
        msg = same ? "[OK]   $(len)-char \"$sub\" → 2 distinct messages" :
                     "[FAIL] $(len)-char \"$sub\" → $n distinct messages (expected 2)"
        println(msg)
        same || (ok = false)
    end
    DuckDB.close(db)
    println(ok ? "\nverify/shared_substrings: PASS" : "\nverify/shared_substrings: FAIL")
    exit(ok ? 0 : 1)
end

main()
