#!/usr/bin/env julia
#
# Verify the message-replacement claim: for any given PRN, every unique
# message appears within at most two calendar months — except the all-¬
# sentinel, which is the only payload spanning more than two calendar
# months on any PRN (up to 6 distinct months on a single PRN).
#
# Reference: article/the-empty-field-that-wasnt.md (sentinel section);
# CLAIMS.md. The v1 article cited this to behavioral_changes.md, where
# it never appeared; this verifier is its home now.
#
# Usage:
#   julia --project verify/calendar_months.jl [data/messages.duckdb]

using DuckDB

const DB_PATH = length(ARGS) >= 1 ? ARGS[1] : "data/messages.duckdb"
isfile(DB_PATH) || (println(stderr, "Error: '$DB_PATH' not found"); exit(2))

const SENTINEL = repeat('¬', 22)   # CP437 byte 0xAA, stored as U+00AC

ok = true
function check(label, expected, actual)
    same = expected == actual
    println(same ? "[OK]   $label = $actual" : "[FAIL] $label: expected $expected, got $actual")
    same || (global ok = false)
end

db = DuckDB.DB(DB_PATH; readonly=true)

rows = collect(DBInterface.execute(db, """
    WITH spans AS (
        SELECT ascii_message, prn,
               COUNT(DISTINCT strftime(datetime, '%Y-%m')) AS n_months
        FROM special_messages
        GROUP BY ascii_message, prn
    )
    SELECT ascii_message, MAX(n_months) AS max_months
    FROM spans
    WHERE n_months > 2
    GROUP BY ascii_message
"""))

check("messages spanning >2 calendar months on some PRN", 1, length(rows))
if length(rows) == 1
    check("that message is the all-¬ sentinel", SENTINEL, rows[1].ascii_message)
    check("maximum calendar months on a single PRN", 6, Int(rows[1].max_months))
end

DuckDB.close(db)
println(ok ? "\nverify/calendar_months: PASS" : "\nverify/calendar_months: FAIL")
exit(ok ? 0 : 1)
