#!/usr/bin/env julia
#
# Verify the January 2011 fleet-wide sentinel onset: all 32 PRNs entered
# the all-¬ sentinel on 2011-01-11 and exited on 2011-01-13, with no
# all-¬ broadcasts in the preceding week. For 28 of the 32 PRNs this was
# their first-ever all-¬ observation (PRNs 1, 5, 13, 25 had earlier
# windows). This event reframes the 26 May 2011 flash as the culmination
# of a phased January–May activation.
#
# Reference: article/the-empty-field-that-wasnt.md (May 2011 section);
# analysis/reports/sentinel_nanu.md §3 "2011-01-11"; CLAIMS.md.
#
# Usage:
#   julia --project verify/sentinel_onset_2011.jl [data/messages.duckdb]

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

prns_on(day) = Int((DBInterface.execute(db, """
    SELECT COUNT(DISTINCT prn) AS n FROM special_messages
    WHERE ascii_message = '$SENTINEL' AND datetime::DATE = DATE '$day'
""") |> first).n)

check("PRNs broadcasting all-¬ on 2011-01-11", 32, prns_on("2011-01-11"))
check("PRNs broadcasting all-¬ on 2011-01-13", 32, prns_on("2011-01-13"))

quiet_before = Int((DBInterface.execute(db, """
    SELECT COUNT(*) AS n FROM special_messages
    WHERE ascii_message = '$SENTINEL'
      AND datetime::DATE BETWEEN DATE '2011-01-04' AND DATE '2011-01-10'
""") |> first).n)
check("all-¬ observations in the preceding week (Jan 4–10)", 0, quiet_before)

window_end = (DBInterface.execute(db, """
    SELECT MAX(datetime)::DATE AS d FROM special_messages
    WHERE ascii_message = '$SENTINEL'
      AND datetime::DATE BETWEEN DATE '2011-01-11' AND DATE '2011-01-31'
""") |> first).d
check("last all-¬ date of the January window", Date(2011, 1, 13), Date(window_end))

first_ever = Int((DBInterface.execute(db, """
    WITH firsts AS (
        SELECT prn, MIN(datetime)::DATE AS first_day FROM special_messages
        WHERE ascii_message = '$SENTINEL' GROUP BY prn
    )
    SELECT COUNT(*) AS n FROM firsts WHERE first_day = DATE '2011-01-11'
""") |> first).n)
check("PRNs whose first-ever all-¬ is 2011-01-11", 28, first_ever)

DuckDB.close(db)
println(ok ? "\nverify/sentinel_onset_2011: PASS" : "\nverify/sentinel_onset_2011: FAIL")
exit(ok ? 0 : 1)
