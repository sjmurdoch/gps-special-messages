#!/usr/bin/env julia
#
# Verify the 2011-05-26 fleet-wide sentinel flash: 31 PRNs entered the
# all-¬ (0xAA) sentinel on this day. PRN 1 is absent.
#
# Reference: feature-article.md §6 (footnote 29).
#
# Usage:
#   julia --project verify/fleet_flash_2011.jl [data/messages.duckdb]

using DuckDB

const DB_PATH = length(ARGS) >= 1 ? ARGS[1] : "data/messages.duckdb"
isfile(DB_PATH) || (println(stderr, "Error: '$DB_PATH' not found"); exit(2))

const ALL_NEG    = repeat("¬", 22)
const FLASH_DATE = "2011-05-26"
const EXPECTED_PRNS = collect(2:32)        # 31 PRNs, no PRN 1

function main()
    db = DuckDB.DB(DB_PATH; readonly=true)

    # PRNs whose previous (non-equal) message was something else and which
    # observed the all-¬ sentinel on 2011-05-26.
    sql = """
    WITH t AS (
        SELECT prn,
               datetime::DATE AS d,
               ascii_message,
               LAG(ascii_message) OVER (PARTITION BY prn ORDER BY datetime) AS prev_msg
        FROM special_messages
        WHERE datetime BETWEEN '2011-05-24' AND '2011-05-28'
    )
    SELECT DISTINCT prn FROM t
    WHERE d = DATE '$FLASH_DATE'
      AND ascii_message = ?
      AND prev_msg IS NOT NULL
      AND prev_msg != ascii_message
    ORDER BY prn
    """
    stmt = DBInterface.prepare(db, sql)
    result = DBInterface.execute(stmt, [ALL_NEG])
    prns = sort([Int(row.prn) for row in result])
    DuckDB.close(db)

    ok = prns == EXPECTED_PRNS
    println("Date:                $FLASH_DATE")
    println("PRNs entering all-¬: $(length(prns))")
    println("PRN list:            $(join(prns, ", "))")
    println("PRN 1 present:       $(1 in prns)")
    println()
    if ok
        println("[OK]   31 PRNs (2..32), PRN 1 absent")
        println("verify/fleet_flash_2011: PASS")
        exit(0)
    else
        missing_prns  = setdiff(EXPECTED_PRNS, prns)
        unexpected    = setdiff(prns, EXPECTED_PRNS)
        !isempty(missing_prns) && println("[FAIL] missing PRNs: $(join(missing_prns, ", "))")
        !isempty(unexpected)   && println("[FAIL] unexpected PRNs: $(join(unexpected, ", "))")
        println("verify/fleet_flash_2011: FAIL")
        exit(1)
    end
end

main()
