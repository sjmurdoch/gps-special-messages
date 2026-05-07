#!/usr/bin/env julia
#
# Verify the PRN 25 lifecycle case study: the NANU sequence
# UNUSUFN 2009-12-18 (2009130) → LAUNCH 2010-05-28 (2010098) →
# USABINIT 2010-08-27 (2010113), each correlating with all-¬ sentinel
# observations in the special-message field.
#
# Reference: feature-article.md §5.
#
# Usage:
#   julia --project verify/prn25_timeline.jl [data/messages.duckdb]

using DuckDB
using Dates

const DB_PATH = length(ARGS) >= 1 ? ARGS[1] : "data/messages.duckdb"
isfile(DB_PATH) || (println(stderr, "Error: '$DB_PATH' not found"); exit(2))

# (NANU id, expected type, expected event date)
const EXPECTED_NANUS = [
    ("2009130", "UNUSUFN",  Date(2009, 12, 18)),
    ("2010098", "LAUNCH",   Date(2010, 5,  28)),
    ("2010113", "USABINIT", Date(2010, 8,  27)),
]

const ALL_NEG = repeat("¬", 22)

function main()
    db = DuckDB.DB(DB_PATH; readonly=true)
    ok = true

    # NANUs
    stmt = DBInterface.prepare(db, """
        SELECT nanu_id, msg_datetime::DATE AS d, nanu_type
        FROM nanu_records WHERE nanu_id = ?
    """)
    for (nid, ntype, ndate) in EXPECTED_NANUS
        row = DBInterface.execute(stmt, [nid]) |> iterate
        if row === nothing
            println("[FAIL] NANU $nid: not found")
            ok = false
            continue
        end
        r = row[1]
        match = r.nanu_type == ntype && Date(r.d) == ndate
        msg = match ? "[OK]   NANU $nid: $(r.nanu_type) on $(r.d)" :
                      "[FAIL] NANU $nid: got $(r.nanu_type) $(r.d), expected $ntype $ndate"
        println(msg)
        match || (ok = false)
    end

    # Sentinel observations on PRN 25, 2010
    sentinel_count = Int((DBInterface.execute(db, """
        SELECT COUNT(*) AS n
        FROM special_messages
        WHERE prn = 25
          AND ascii_message = ?
          AND datetime >= '2010-01-01' AND datetime < '2011-01-01'
    """, [ALL_NEG]) |> first).n)

    has_sentinels = sentinel_count > 0
    println(has_sentinels ?
        "[OK]   PRN 25 broadcast all-¬ sentinel $sentinel_count times in 2010" :
        "[FAIL] no all-¬ sentinel observations for PRN 25 in 2010")
    has_sentinels || (ok = false)

    DuckDB.close(db)
    println(ok ? "\nverify/prn25_timeline: PASS" : "\nverify/prn25_timeline: FAIL")
    exit(ok ? 0 : 1)
end

main()
