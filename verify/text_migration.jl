#!/usr/bin/env julia
#
# Verify TEXT-prefix message migration totals: 55 unique messages, 122
# (PRN, day) combinations, 8,248 observations.
#
# Reference: feature-article.md §9, Figure 6.
#
# Usage:
#   julia --project verify/text_migration.jl [data/messages.duckdb]

using DuckDB

const DB_PATH = length(ARGS) >= 1 ? ARGS[1] : "data/messages.duckdb"
isfile(DB_PATH) || (println(stderr, "Error: '$DB_PATH' not found"); exit(2))

function main()
    db = DuckDB.DB(DB_PATH; readonly=true)

    row = DBInterface.execute(db, """
        SELECT
            COUNT(*)                                       AS total,
            COUNT(DISTINCT message_hash)                   AS uniq,
            COUNT(DISTINCT (prn, datetime::DATE))          AS prn_days
        FROM special_messages
        WHERE ascii_message LIKE 'TEXT%'
    """) |> first

    DuckDB.close(db)

    total = Int(row.total)
    uniq  = Int(row.uniq)
    prn_days = Int(row.prn_days)

    ok = true
    function check(label, expected, actual)
        same = expected == actual
        println(same ? "[OK]   $label = $actual" : "[FAIL] $label: expected $expected, got $actual")
        same || (ok = false)
    end

    check("unique TEXT messages",     55,    uniq)
    check("(PRN, day) combinations",  122,   prn_days)
    check("total TEXT observations",  8_248, total)

    println(ok ? "\nverify/text_migration: PASS" : "\nverify/text_migration: FAIL")
    exit(ok ? 0 : 1)
end

main()
