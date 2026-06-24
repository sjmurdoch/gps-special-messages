#!/usr/bin/env julia
#
# Plot: Message rotation rate over time
#
# A single time series showing fleet-mean unique messages per PRN per week,
# with the pre-2011 slow regime, mid-2011 step change, and coordinated
# change points marked.  Simpler than the full visualization — one clean
# line with annotated regime shifts.
#
# Usage:
#   julia --project plot_rotation_rate.jl [messages.duckdb]

using DuckDB, DataFrames, Dates
using CairoMakie
using Colors
using Statistics

const DB_PATH = length(ARGS) >= 1 ? ARGS[1] : "data/messages.duckdb"
const OUT_DIR = joinpath(@__DIR__, "output")
mkpath(OUT_DIR)

# ── Load data ────────────────────────────────────────────────────────────────
println("Loading data from $DB_PATH...")
db = DuckDB.DB(DB_PATH; readonly=true)

# Fleet-wide weekly diversity (prn=0 is fleet aggregate)
fleet = DBInterface.execute(db, """
    SELECT period_start,
           CAST(unique_message_count AS DOUBLE) / NULLIF(active_prn_count, 0)
               AS mean_unique_per_prn,
           active_prn_count
    FROM behavioral_metrics
    WHERE granularity = 'weekly' AND prn = 0
      AND unique_message_count IS NOT NULL AND active_prn_count > 0
    ORDER BY period_start
""") |> DataFrame

# Cross-PRN spread (σ across individual satellites each week)
spread = DBInterface.execute(db, """
    SELECT
        period_start,
        AVG(CAST(unique_message_count AS DOUBLE)) AS mu,
        STDDEV(CAST(unique_message_count AS DOUBLE)) AS sigma
    FROM behavioral_metrics
    WHERE granularity = 'weekly' AND prn != 0 AND unique_message_count IS NOT NULL
    GROUP BY period_start
    ORDER BY period_start
""") |> DataFrame

# Coordinated change points (diversity metric, strong effect size)
# Load all CPs and filter to coordinated diversity events
cp_all = DBInterface.execute(db, """
    SELECT detected_at, direction, coordinated_prn_count
    FROM behavioral_change_points
    WHERE is_coordinated = true
      AND metric = 'unique_message_count'
      AND granularity = 'weekly'
    ORDER BY detected_at
""") |> DataFrame

close(db)

println("Loaded $(nrow(fleet)) weekly fleet diversity rows")
println("Loaded $(nrow(cp_all)) coordinated diversity change points")

dropmissing!(fleet, :mean_unique_per_prn)
dropmissing!(spread, [:mu, :sigma])
sort!(fleet, :period_start)
sort!(spread, :period_start)

# ── Tufte theme ──────────────────────────────────────────────────────────────
set_theme!(Theme(
    backgroundcolor = :white,
    fontsize        = 16,
    Axis = (
        backgroundcolor   = :transparent,
        xgridvisible      = false,
        ygridvisible      = false,
        topspinevisible   = false,
        rightspinevisible = false,
        leftspinecolor    = :gray40,
        bottomspinecolor  = :gray40,
        xtickcolor        = :gray40,
        ytickcolor        = :gray40,
        xticklabelcolor   = :gray20,
        yticklabelcolor   = :gray20,
        xlabelcolor       = :gray20,
        ylabelcolor       = :gray20,
    )
))

# ── Time axis ────────────────────────────────────────────────────────────────
t_origin = minimum(fleet.period_start)
to_days(dt) = Dates.value(dt - t_origin) / (1000.0 * 60 * 60 * 24)

fleet.x  = to_days.(fleet.period_start)
spread.x = to_days.(spread.period_start)

total_days = maximum(fleet.x)

# Year ticks
year_ticks  = Float64[]
year_labels = String[]
for y in 2007:2026
    dt = DateTime(y, 1, 1)
    d  = to_days(dt)
    if d >= 0 && d <= total_days
        push!(year_ticks, d)
        push!(year_labels, string(y))
    end
end

# ── Colors ───────────────────────────────────────────────────────────────────
const LINE_COLOR = RGBf(0.15, 0.15, 0.15)
const BAND_COLOR = RGBAf(0.55, 0.55, 0.55, 0.20)
const INC_COLOR  = RGBAf(0.78, 0.28, 0.06, 0.80)   # warm orange
const DEC_COLOR  = RGBAf(0.08, 0.38, 0.75, 0.80)   # cool blue
const REGIME_BG  = RGBAf(0.82, 0.15, 0.08, 0.04)   # very faint red

# ── Figure ───────────────────────────────────────────────────────────────────
println("Creating figure...")
fig = Figure(size = (1100, 480), figure_padding = (50, 25, 30, 15))

ax = Axis(fig[1, 1],
    title      = "GPS Special Message Rotation Rate (2007–2026)",
    titlesize  = 22,
    ylabel     = "Unique messages / satellite / week",
    ylabelsize = 17,
)
ax.xticks = (year_ticks, year_labels)
xlims!(ax, -total_days * 0.01, total_days * 1.005)
ylims!(ax, 0, 12)

# ── Regime background shading ────────────────────────────────────────────────
# Era boundaries (CUSUM coordinated change points): pre-2011 slow regime,
# 2012–2022 fast regime, post-2022 modern slow regime. The days/msg labels
# are computed below as 7 / mean(uniq_msgs/sat/wk) per era; chart-metric,
# not right-censored, unlike the per-(message, prn) duration in OTAD Test 4.
regime_b1 = to_days(DateTime(2011, 5, 26))
regime_b2 = to_days(DateTime(2022, 5, 30))

days_per_msg(rows) = round(7.0 / mean(rows.mean_unique_per_prn); digits = 1)
era_pre    = days_per_msg(fleet[fleet.period_start .< DateTime(2011, 5, 26), :])
era_fast   = days_per_msg(fleet[DateTime(2011, 5, 26) .<= fleet.period_start .< DateTime(2022, 5, 30), :])
era_modern = days_per_msg(fleet[fleet.period_start .>= DateTime(2022, 5, 30), :])
final_year = year(maximum(fleet.period_start))
era_final  = days_per_msg(fleet[year.(fleet.period_start) .== final_year, :])

label_y = 11.2
text!(ax, regime_b1 / 2, label_y;
    text = "Slow regime\n~$(era_pre) days/msg",
    fontsize = 14, align = (:center, :top), color = :gray45)
text!(ax, (regime_b1 + regime_b2) / 2, label_y;
    text = "Fast regime\n~$(era_fast) days/msg",
    fontsize = 14, align = (:center, :top), color = :gray45)
text!(ax, (regime_b2 + total_days) / 2, label_y;
    text = "Modern slow regime\n$(era_modern) → $(era_final) days/msg",
    fontsize = 14, align = (:center, :top), color = :gray45)

# Regime boundary line 1 (2011)
vlines!(ax, [regime_b1];
    color = RGBAf(0.82, 0.15, 0.08, 0.50), linewidth = 1.5, linestyle = :dash)
text!(ax, regime_b1 + total_days * 0.005, label_y;
    text = "Fleet sentinel flash\n26 May 2011",
    fontsize = 14, align = (:left, :top),
    color = RGBAf(0.82, 0.15, 0.08, 0.80))

# Regime boundary line 2 (2022)
vlines!(ax, [regime_b2];
    color = RGBAf(0.08, 0.38, 0.75, 0.50), linewidth = 1.5, linestyle = :dash)
text!(ax, regime_b2 - total_days * 0.005, label_y;
    text = "Regime change\nMay 2022",
    fontsize = 14, align = (:right, :top),
    color = RGBAf(0.08, 0.38, 0.75, 0.80))

# ── ±σ band ──────────────────────────────────────────────────────────────────
lo = max.(0.0, spread.mu .- spread.sigma)
hi = spread.mu .+ spread.sigma
band!(ax, spread.x, Float64.(lo), Float64.(hi); color = BAND_COLOR)

# ── Main line ────────────────────────────────────────────────────────────────
lines!(ax, fleet.x, Float64.(fleet.mean_unique_per_prn);
    color = LINE_COLOR, linewidth = 1.0)

# ── Coordinated change-point ticks ───────────────────────────────────────────
for row in eachrow(cp_all)
    x = to_days(row.detected_at)
    color = row.direction == "increase" ? INC_COLOR : DEC_COLOR
    vlines!(ax, [x]; ymin = 0.0, ymax = 0.04, color = color, linewidth = 1.5)
end

# ── Annotation ───────────────────────────────────────────────────────────────
text!(ax, total_days * 0.99, 0.5;
    text     = "Line: fleet mean  ·  Band: ±σ across satellites  ·  Bottom ticks: coordinated change points (orange ↑, blue ↓)",
    fontsize = 13,
    align    = (:right, :bottom),
    color    = :gray45)

# ── Save ─────────────────────────────────────────────────────────────────────
println("Saving...")
png_path = joinpath(OUT_DIR, "rotation_rate.png")
pdf_path = joinpath(OUT_DIR, "rotation_rate.pdf")
svg_path = joinpath(OUT_DIR, "rotation_rate.svg")
save(png_path, fig; px_per_unit = parse(Float64, get(ENV, "PNG_PX_PER_UNIT", "3")))
save(pdf_path, fig)
save(svg_path, fig)

png_kb = round(filesize(png_path) / 1024; digits=1)
pdf_kb = round(filesize(pdf_path) / 1024; digits=1)
svg_kb = round(filesize(svg_path) / 1024; digits=1)
println("\nDone!")
println("  $png_path  ($png_kb KB)")
println("  $pdf_path  ($pdf_kb KB)")
println("  $svg_path  ($svg_kb KB)")
