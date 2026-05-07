#!/usr/bin/env julia
#
# Verify chi-squared test against the IS-GPS-200 45-symbol alphabet.
#
# Reference: feature-article.md §3 (footnote 17): z-score 1.84 over the
# distribution of distinct ascii_messages, normal approximation to the
# χ² statistic with df = 44.
#
# Usage:
#   julia --project verify/chi_squared.jl [data/messages.duckdb]

using DuckDB

const DB_PATH = length(ARGS) >= 1 ? ARGS[1] : "data/messages.duckdb"
isfile(DB_PATH) || (println(stderr, "Error: '$DB_PATH' not found"); exit(2))

# IS-GPS-200 special-message alphabet, 45 symbols (including the CP437 °)
const GPS_CHARS = collect("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+-.'°/: \"")

const Z_EXPECTED = 1.84
const Z_TOL      = 0.01

function main()
    db = DuckDB.DB(DB_PATH; readonly=true)
    result = DBInterface.execute(db, "SELECT DISTINCT ascii_message FROM special_messages")

    counts = Dict(c => 0 for c in GPS_CHARS)
    total = 0
    nongps = 0

    for row in result
        for c in row.ascii_message
            total += 1
            if haskey(counts, c)
                counts[c] += 1
            else
                nongps += 1
            end
        end
    end
    DuckDB.close(db)

    n  = length(GPS_CHARS)
    df = n - 1
    expected = (total - nongps) / n
    chi_sq = sum((c - expected)^2 / expected for (_, c) in counts)
    z = (chi_sq - df) / sqrt(2 * df)

    ok = abs(z - Z_EXPECTED) <= Z_TOL
    println("Distinct messages scanned: $(total ÷ 22)")
    println("Total GPS-alphabet bytes:  $(total - nongps)")
    println("Non-GPS bytes (excluded):  $nongps")
    println("Expected per class:        $(round(expected, digits=2))")
    println("χ² statistic:              $(round(chi_sq, digits=2)) (df = $df)")
    println(rpad("z-score:", 27), round(z, digits=3))
    println()
    println(ok ? "[OK]   z = $(round(z, digits=3)) within $(Z_EXPECTED) ± $(Z_TOL)" :
                 "[FAIL] z = $(round(z, digits=3)) outside $(Z_EXPECTED) ± $(Z_TOL)")
    println(ok ? "verify/chi_squared: PASS" : "verify/chi_squared: FAIL")
    exit(ok ? 0 : 1)
end

main()
