#!/usr/bin/env julia
#
# Verify the per-year unique-message diversity quoted in the behavioral-
# regime section: 50–114 distinct payloads per year in the pre-operational
# era (2007–2010) and 368–404 per year in the operational era (2012–2021).
# 2011 is the activation/transition year and 2022+ the modern era; both
# are deliberately outside these two ranges.
#
# Reference: article/the-empty-field-that-wasnt.md ("From One Message Every
# Few Days to One a Day" — regime bullets); CLAIMS.md, footnote [^40].
#
# Usage:
#   julia --project verify/message_diversity.jl [data/messages.duckdb]

using DuckDB

const DB_PATH = length(ARGS) >= 1 ? ARGS[1] : "data/messages.duckdb"
isfile(DB_PATH) || (println(stderr, "Error: '$DB_PATH' not found"); exit(2))

ok = true
function check(label, expected, actual)
    same = expected == actual
    println(same ? "[OK]   $label = $actual" : "[FAIL] $label: expected $expected, got $actual")
    same || (global ok = false)
end

db = DuckDB.DB(DB_PATH; readonly=true)

function era_minmax(db, y0, y1)
    r = DBInterface.execute(db, """
        WITH per_year AS (
            SELECT year, COUNT(DISTINCT message_hash) AS n
            FROM special_messages
            WHERE year BETWEEN $y0 AND $y1
            GROUP BY year
        )
        SELECT MIN(n) AS lo, MAX(n) AS hi FROM per_year
    """) |> first
    return Int(r.lo), Int(r.hi)
end

pre_lo, pre_hi = era_minmax(db, 2007, 2010)
check("pre-operational (2007–2010) min distinct messages/year", 50, pre_lo)
check("pre-operational (2007–2010) max distinct messages/year", 114, pre_hi)

op_lo, op_hi = era_minmax(db, 2012, 2021)
check("operational (2012–2021) min distinct messages/year", 368, op_lo)
check("operational (2012–2021) max distinct messages/year", 404, op_hi)

DuckDB.close(db)
println(ok ? "\nverify/message_diversity: PASS" : "\nverify/message_diversity: FAIL")
exit(ok ? 0 : 1)
