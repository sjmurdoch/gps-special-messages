#!/usr/bin/env julia
#
# Verify corpus totals: 12,163,006 observations, 3,994 unique messages,
# 32 PRNs, date range 2007-06-19 → 2026-01-23.
#
# Reference: feature-article.md §1, §2 (footnote 2).
#
# Usage:
#   julia --project verify/corpus_totals.jl [data/messages.duckdb]

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

row = DBInterface.execute(db, """
    SELECT COUNT(*)              AS total,
           COUNT(DISTINCT message_hash) AS uniq,
           COUNT(DISTINCT prn)   AS prns,
           MIN(datetime)::DATE   AS first,
           MAX(datetime)::DATE   AS last
    FROM special_messages
""") |> first

DuckDB.close(db)

check("total observations",   12_163_006,        Int(row.total))
check("unique message hashes", 3_994,            Int(row.uniq))
check("PRNs",                  32,               Int(row.prns))
check("first date",            Date(2007, 6, 19), Date(row.first))
check("last date",             Date(2026, 1, 23), Date(row.last))

println(ok ? "\nverify/corpus_totals: PASS" : "\nverify/corpus_totals: FAIL")
exit(ok ? 0 : 1)
