#!/usr/bin/env julia
#
# Verify the information capacity of the Subframe 4, Page 17 field.
#
# The slot is physically 176 data bits (22 × 8), but IS-GPS-200 restricts
# the field to 22 characters from a 45-symbol alphabet, and the data obey
# that restriction: across the unique corpus, all but a vanishing fraction
# of bytes are in-alphabet, and the only out-of-alphabet bytes are the two
# degenerate sentinels (all-0x00 and all-0xAA). The cipher is therefore
# format-preserving over 45 symbols, so the *usable* capacity is
# 22·log₂45 ≈ 120.8 bits, not 176 — a 128-bit key (needing 24 symbols)
# does not fit.
#
# Reference: feature-article.md §"When Encrypted Messages Share Their
# Spelling" (footnote 50); IS-GPS-200N §20.3.3.5.1.8 (footnote 12).
#
# Usage:
#   julia --project verify/field_capacity.jl [data/messages.duckdb]

using DuckDB

const DB_PATH = length(ARGS) >= 1 ? ARGS[1] : "data/messages.duckdb"
isfile(DB_PATH) || (println(stderr, "Error: '$DB_PATH' not found"); exit(2))

# IS-GPS-200 special-message alphabet as raw byte values (45 symbols).
# Note ° is CP437 0xF8 (248), a high byte, so "in-alphabet" already
# includes a non-ASCII value.
const GPS_BYTES = Set{Int}(vcat(
    collect(Int(UInt8('A')):Int(UInt8('Z'))),       # A–Z
    collect(Int(UInt8('0')):Int(UInt8('9'))),       # 0–9
    Int.([UInt8('+'), UInt8('-'), UInt8('.'), UInt8('\''),
          0xF8, UInt8('/'), UInt8(':'), UInt8(' '), UInt8('"')]),  # 9 punctuation/spacing
))
@assert length(GPS_BYTES) == 45

ok = true
function check(label, expected, actual)
    same = expected == actual
    println(same ? "[OK]   $label = $actual" : "[FAIL] $label: expected $expected, got $actual")
    same || (global ok = false)
end
function check_true(label, cond, detail)
    println(cond ? "[OK]   $label ($detail)" : "[FAIL] $label ($detail)")
    cond || (global ok = false)
end

db = DuckDB.DB(DB_PATH; readonly=true)

# Per-value byte histogram over the *distinct* messages. raw_bytes is a
# 22-byte BLOB; hex() gives 44 hex chars, parsed two at a time.
result = DBInterface.execute(db, """
    WITH d AS (SELECT DISTINCT message_hash, hex(raw_bytes) AS h FROM special_messages),
         b AS (SELECT ('0x' || substring(h, 2*i-1, 2))::INTEGER AS bv
               FROM d, generate_series(1,22) AS t(i))
    SELECT bv, COUNT(*) AS n FROM b GROUP BY bv ORDER BY bv
""")

hist = Dict{Int,Int}()
for r in result
    hist[Int(r.bv)] = Int(r.n)
end
DuckDB.close(db)

total      = sum(values(hist))
in_bytes   = sum(n for (v, n) in hist if v in GPS_BYTES; init=0)
in_present = sort([v for v in keys(hist) if v in GPS_BYTES])
out_vals   = sort([v for v in keys(hist) if !(v in GPS_BYTES)])
frac       = in_bytes / total

# Capacity arithmetic (the load-bearing claim the article rests on).
cap_bits   = 22 * log2(45)              # ≈ 120.82
sym_for128 = ceil(Int, 128 / log2(45))  # = 24

println("Total bytes (distinct msgs × 22): $total")
println("In-alphabet bytes:                $in_bytes ($(round(100frac, digits=3))%)")
println("Distinct alphabet symbols used:   $(length(in_present)) / 45")
println("Out-of-alphabet byte values:      $(map(v -> string("0x", uppercase(string(v, base=16, pad=2))), out_vals))")
println("Usable capacity 22·log₂45:        $(round(cap_bits, digits=2)) bits")
println("Symbols a 128-bit key needs:      $sym_for128 (field has 22)")
println()

check("all 45 alphabet symbols present", 45, length(in_present))
check("out-of-alphabet byte values", [0x00, 0xAA], UInt8.(out_vals))
check_true("≥99.9% of bytes in-alphabet", frac >= 0.999, "$(round(100frac, digits=3))%")
check_true("usable capacity ≈ 120.8 bits", isapprox(cap_bits, 120.82; atol=0.02), "$(round(cap_bits, digits=2)) bits")
check_true("128-bit key overflows the field", sym_for128 > 22, "needs $sym_for128 symbols > 22")

println(ok ? "\nverify/field_capacity: PASS" : "\nverify/field_capacity: FAIL")
exit(ok ? 0 : 1)
