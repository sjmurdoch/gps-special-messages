#!/usr/bin/env julia
#
# Verify the TEXT-prefix migration timeline plotted in Figure 6. After the
# 12–13 Dec 2023 fleet-wide inception (verify/text_inception_2023.jl), the
# format appears as four multi-PRN one-day distribution events through 2024,
# then as sustained single-PRN daily bursts that migrate between satellites
# (PRN 1 → PRN 21 → PRN 20), a different payload each day of a burst.
#
# Reference: article/the-empty-field-that-wasnt.md (TEXT section, migration
# bullets) and Figure 6; CLAIMS.md, footnote [^53].
#
# Usage:
#   julia --project verify/text_timeline.jl [data/messages.duckdb]

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

# distinct (PRNs, payloads) of TEXT broadcasts on a single calendar day
function day_counts(db, d)
    r = DBInterface.execute(db, """
        SELECT COUNT(DISTINCT prn) AS prns, COUNT(DISTINCT message_hash) AS msgs
        FROM special_messages
        WHERE ascii_message LIKE 'TEXT%' AND datetime::DATE = DATE '$d'
    """) |> first
    return Int(r.prns), Int(r.msgs)
end

# distinct TEXT days (and payloads) for one PRN within an inclusive range
function run_counts(db, prn, d0, d1)
    r = DBInterface.execute(db, """
        SELECT COUNT(DISTINCT datetime::DATE) AS days,
               COUNT(DISTINCT message_hash) AS msgs
        FROM special_messages
        WHERE ascii_message LIKE 'TEXT%' AND prn = $prn
          AND datetime::DATE BETWEEN DATE '$d0' AND DATE '$d1'
    """) |> first
    return Int(r.days), Int(r.msgs)
end

# Four 2024 multi-PRN one-day distribution events (one payload each)
for (d, prns) in [("2024-03-18", 10), ("2024-03-25", 9), ("2024-07-31", 9), ("2024-10-10", 4)]
    p, m = day_counts(db, d)
    check("TEXT distribution $d — PRNs", prns, p)
    check("TEXT distribution $d — distinct payloads", 1, m)
end

# Sustained single-PRN daily bursts of the migrating daily-duty satellite.
# Each range below is fully covered (distinct days == calendar span), i.e.
# consecutive, and PRN 1 carries a distinct payload on every one of its days.
d1days, d1msgs = run_counts(db, 1, "2024-12-28", "2025-01-13")
check("PRN 1 daily run 2024-12-28..2025-01-13 — days", 17, d1days)
check("PRN 1 daily run — distinct payloads (one per day)", 17, d1msgs)

d21a, _ = run_counts(db, 21, "2025-03-19", "2025-04-04")
check("PRN 21 daily run 2025-03-19..2025-04-04 — days", 17, d21a)
d21b, _ = run_counts(db, 21, "2025-06-09", "2025-06-18")
check("PRN 21 daily run 2025-06-09..2025-06-18 — days", 10, d21b)

d20, _ = run_counts(db, 20, "2025-07-31", "2025-08-04")
check("PRN 20 daily run 2025-07-31..2025-08-04 — days", 5, d20)

DuckDB.close(db)
println(ok ? "\nverify/text_timeline: PASS" : "\nverify/text_timeline: FAIL")
exit(ok ? 0 : 1)
