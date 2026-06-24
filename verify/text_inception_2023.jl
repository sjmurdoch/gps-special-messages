#!/usr/bin/env julia
#
# Verify the fleet-wide TEXT inception of 12–13 December 2023: the first
# TEXT-prefixed message appears on 9 PRNs on 2023-12-12, and on
# 2023-12-13 all 32 PRNs broadcast TEXT-prefixed messages (two distinct
# payloads across the two days). The v1 article's "single-satellite
# trial" reading (PRN 8 alone) is withdrawn — it was an artifact of the
# D30* decoder bug (see CHANGELOG.md).
#
# Aggregate TEXT totals (55 unique / 122 PRN-days / 8,248 obs) are
# pinned separately by verify/text_migration.jl.
#
# Reference: article/the-empty-field-that-wasnt.md (TEXT section);
# CLAIMS.md.
#
# Usage:
#   julia --project verify/text_inception_2023.jl [data/messages.duckdb]

using DuckDB
using Dates

const DB_PATH = length(ARGS) >= 1 ? ARGS[1] : "data/messages.duckdb"
isfile(DB_PATH) || (println(stderr, "Error: '$DB_PATH' not found"); exit(2))

ok = true
function check(label, expected, actual)
    same = expected == actual
    println(same ? "[OK]   $label = $actual" : "[FAIL] $label: expected $expected, got $actual")
    same || (global ok = false)
end

db = DuckDB.DB(DB_PATH; readonly=true)

first_day = (DBInterface.execute(db, """
    SELECT MIN(datetime)::DATE AS d FROM special_messages
    WHERE ascii_message LIKE 'TEXT%'
""") |> first).d
check("first TEXT-prefixed broadcast date", Date(2023, 12, 12), Date(first_day))

day12 = DBInterface.execute(db, """
    SELECT COUNT(DISTINCT prn) AS prns, COUNT(DISTINCT ascii_message) AS msgs
    FROM special_messages
    WHERE ascii_message LIKE 'TEXT%' AND datetime::DATE = DATE '2023-12-12'
""") |> first
check("PRNs broadcasting TEXT on 2023-12-12", 9, Int(day12.prns))
check("distinct TEXT payloads on 2023-12-12", 1, Int(day12.msgs))

day13 = DBInterface.execute(db, """
    SELECT COUNT(DISTINCT prn) AS prns, COUNT(DISTINCT ascii_message) AS msgs
    FROM special_messages
    WHERE ascii_message LIKE 'TEXT%' AND datetime::DATE = DATE '2023-12-13'
""") |> first
check("PRNs broadcasting TEXT on 2023-12-13", 32, Int(day13.prns))
check("distinct TEXT payloads on 2023-12-13", 2, Int(day13.msgs))

inception_obs = Int((DBInterface.execute(db, """
    SELECT COUNT(*) AS n FROM special_messages
    WHERE ascii_message LIKE 'TEXT%'
      AND datetime::DATE BETWEEN DATE '2023-12-12' AND DATE '2023-12-13'
""") |> first).n)
check("TEXT observations across 12–13 Dec 2023", 2_737, inception_obs)

DuckDB.close(db)
println(ok ? "\nverify/text_inception_2023: PASS" : "\nverify/text_inception_2023: FAIL")
exit(ok ? 0 : 1)
