#!/usr/bin/env julia
#
# Verify the July 2020 fleet-wide sentinel event: 29 PRNs broadcast the
# all-¬ sentinel on 2020-07-22 (1,438 observations — all of 2020's
# sentinel traffic falls on that single day), and that day is the last
# sentinel observation in the corpus (any sentinel byte, not just ¬).
# This event was invisible in the v1 corpus (D30* decoder bug).
#
# Reference: article/the-empty-field-that-wasnt.md (sentinel section);
# analysis/reports/sentinel_nanu.md §3 "2020-07-22"; CLAIMS.md.
#
# Usage:
#   julia --project verify/sentinel_event_2020.jl [data/messages.duckdb]

using DuckDB
using Dates

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

day = DBInterface.execute(db, """
    SELECT COUNT(DISTINCT prn) AS prns, COUNT(*) AS obs FROM special_messages
    WHERE ascii_message = '$SENTINEL' AND datetime::DATE = DATE '2020-07-22'
""") |> first
check("PRNs broadcasting all-¬ on 2020-07-22", 29, Int(day.prns))
check("all-¬ observations on 2020-07-22", 1_438, Int(day.obs))

year_total = Int((DBInterface.execute(db, """
    SELECT COUNT(*) AS n FROM special_messages
    WHERE ascii_message = '$SENTINEL'
      AND datetime::DATE BETWEEN DATE '2020-01-01' AND DATE '2020-12-31'
""") |> first).n)
check("all-¬ observations in calendar 2020 (single-day event)", 1_438, year_total)

# Last sentinel of any kind in the corpus: a sentinel is 22 copies of one byte.
last_sentinel = (DBInterface.execute(db, """
    SELECT MAX(datetime)::DATE AS d FROM special_messages
    WHERE ascii_message = repeat(ascii_message[1], 22)
""") |> first).d
check("last sentinel observation in the corpus", Date(2020, 7, 22), Date(last_sentinel))

DuckDB.close(db)
println(ok ? "\nverify/sentinel_event_2020: PASS" : "\nverify/sentinel_event_2020: FAIL")
exit(ok ? 0 : 1)
