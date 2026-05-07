#!/usr/bin/env julia
#
# Verify the three rotation-rate regimes and the May 2022 coordinated change
# point.
#
# Reference: feature-article.md §7 (footnote 33) and Figure 4
# (figures/output/rotation_rate.png).
#
# Methodology: this matches the figure rather than Test 4 of the OTAD
# hypothesis report. Figure 4 plots fleet-aggregate weekly unique-message
# count divided by active PRNs ("unique messages per satellite per week");
# inverting that ratio gives days per message.
#
# Test 4 of the OTAD hypothesis report uses a different metric (per
# (message, prn) duration = last_seen − first_seen) which understates the
# post-2022 era because messages from late in the corpus are right-censored.
# It also makes pre-2011 and post-2022 look similar (3.4 d vs 3.3 d) when
# the chart shows them visibly distinct (~3.8 d vs ~4.3 d).
#
# The article paragraph 133's "2.3 d for 2007–2008" comes from a hardcoded
# prose row in `analysis/otad_hypothesis.jl`, not from a computation, and
# is not reproducible from the DB by any documented metric. This verifier
# does not assert it.
#
# Usage:
#   julia --project verify/rotation_regimes.jl [data/messages.duckdb]

using DuckDB
using Dates

const DB_PATH = length(ARGS) >= 1 ? ARGS[1] : "data/messages.duckdb"
isfile(DB_PATH) || (println(stderr, "Error: '$DB_PATH' not found"); exit(2))

# (label, year predicate, expected days/msg, tolerance)
const ERAS = [
    ("2007–2010 (pre-OTAD)",        "BETWEEN 2007 AND 2010", 3.7, 0.2),
    ("2012–2021 (operational OTAD)", "BETWEEN 2012 AND 2021", 1.8, 0.1),
    ("2022+ (modern era)",           ">= 2022",               4.3, 0.5),
]

function era_days_per_msg(db, where_predicate)
    res = DBInterface.execute(db, """
        SELECT AVG(CAST(unique_message_count AS DOUBLE) / NULLIF(active_prn_count, 0)) AS x
        FROM behavioral_metrics
        WHERE granularity = 'weekly' AND prn = 0
          AND unique_message_count IS NOT NULL AND active_prn_count > 0
          AND EXTRACT(YEAR FROM period_start) $where_predicate
    """) |> first
    return 7.0 / res.x
end

function main()
    db = DuckDB.DB(DB_PATH; readonly=true)
    ok = true
    measured = Dict{String, Float64}()

    for (label, where_, expected, tol) in ERAS
        d = era_days_per_msg(db, where_)
        measured[label] = d
        same = abs(d - expected) <= tol
        msg = same ? "[OK]   $label = $(round(d, digits=2)) d (target $expected ± $tol)" :
                     "[FAIL] $label = $(round(d, digits=2)) d (target $expected ± $tol)"
        println(msg)
        same || (ok = false)
    end

    # Qualitative claim: post-2022 era rotates *slower* than pre-2011 era.
    pre  = measured["2007–2010 (pre-OTAD)"]
    post = measured["2022+ (modern era)"]
    qual_ok = post > pre + 0.2  # at least 0.2 d gap (~5 hours)
    qual_msg = qual_ok ?
        "[OK]   post-2022 ($(round(post, digits=2)) d) is slower than pre-2011 ($(round(pre, digits=2)) d) by $(round(post - pre, digits=2)) d" :
        "[FAIL] post-2022 ($(round(post, digits=2)) d) NOT meaningfully slower than pre-2011 ($(round(pre, digits=2)) d)"
    println(qual_msg)
    qual_ok || (ok = false)

    # Coordinated change point in behavioral_change_points around May 2022
    cp_row = DBInterface.execute(db, """
        SELECT detected_at::DATE AS d, metric, direction, coordinated_prn_count
        FROM behavioral_change_points
        WHERE is_coordinated = true
          AND detected_at BETWEEN '2022-04-15' AND '2022-06-30'
        ORDER BY coordinated_prn_count DESC, detected_at
        LIMIT 1
    """) |> iterate

    if cp_row === nothing
        println("[FAIL] no coordinated change point detected between 2022-04-15 and 2022-06-30")
        ok = false
    else
        r = cp_row[1]
        println("[OK]   coordinated CP @ $(r.d) — $(r.metric) $(r.direction), $(r.coordinated_prn_count) PRNs")
    end

    DuckDB.close(db)
    println(ok ? "\nverify/rotation_regimes: PASS" : "\nverify/rotation_regimes: FAIL")
    exit(ok ? 0 : 1)
end

main()
