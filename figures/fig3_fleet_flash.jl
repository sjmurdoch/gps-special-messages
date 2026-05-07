#!/usr/bin/env julia
#
# Plot: The 2011-05-26 fleet-wide sentinel flash
#
# A 48-hour timeline (one row per PRN) showing the all-¬ (0xAC) sentinel
# entering and exiting across 31 satellites within hours.  Normal messages
# are shown in muted tones; sentinel periods are highlighted.
#
# Usage:
#   julia --project plot_fleet_flash.jl [messages.duckdb]

using DuckDB, DataFrames, Dates
using CairoMakie
using Colors

const DB_PATH = length(ARGS) >= 1 ? ARGS[1] : "data/messages.duckdb"
const OUT_DIR = joinpath(@__DIR__, "output")
mkpath(OUT_DIR)

# ── Query observations around the flash ──────────────────────────────────────
println("Loading data from $DB_PATH...")
db = DuckDB.DB(DB_PATH; readonly=true)

# 48-hour window centred on 2011-05-26
obs = DBInterface.execute(db, """
    SELECT prn, datetime, ascii_message, entropy
    FROM special_messages
    WHERE datetime >= '2011-05-25 00:00:00'
      AND datetime <  '2011-05-28 00:00:00'
    ORDER BY prn, datetime
""") |> DataFrame
println("Loaded $(nrow(obs)) observations in flash window")

close(db)

# ── Classify each observation ────────────────────────────────────────────────
obs.is_sentinel = obs.entropy .== 0.0

# ── Build per-PRN segments ───────────────────────────────────────────────────
# Group consecutive observations with same sentinel status into segments.
segments = DataFrame(
    prn        = Int[],
    t_start    = DateTime[],
    t_end      = DateTime[],
    is_sentinel = Bool[],
    message    = String[],
)

for prn in 1:32
    sub = filter(r -> r.prn == prn, obs)
    isempty(sub) && continue
    sort!(sub, :datetime)

    cur_sentinel = sub.is_sentinel[1]
    cur_msg      = sub.ascii_message[1]
    seg_start    = sub.datetime[1]
    seg_end      = sub.datetime[1]

    for i in 2:nrow(sub)
        if sub.is_sentinel[i] == cur_sentinel && sub.ascii_message[i] == cur_msg
            seg_end = sub.datetime[i]
        else
            push!(segments, (prn, seg_start, seg_end, cur_sentinel, cur_msg))
            cur_sentinel = sub.is_sentinel[i]
            cur_msg      = sub.ascii_message[i]
            seg_start    = sub.datetime[i]
            seg_end      = sub.datetime[i]
        end
    end
    push!(segments, (prn, seg_start, seg_end, cur_sentinel, cur_msg))
end
println("Built $(nrow(segments)) segments across $(length(unique(segments.prn))) PRNs")

# ── Time axis: hours since 2011-05-25 00:00 ─────────────────────────────────
const T_ORIGIN = DateTime(2011, 5, 25, 0, 0, 0)
to_hours(dt) = Dates.value(dt - T_ORIGIN) / (1000.0 * 60 * 60)

segments.x1 = to_hours.(segments.t_start)
segments.x2 = to_hours.(segments.t_end)

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

# ── Colors ───────────────────────────────────────────────────────────────────
const SENTINEL_COLOR = RGBAf(0.82, 0.15, 0.08, 0.90)   # Strong red
const NORMAL_COLOR   = RGBAf(0.55, 0.55, 0.55, 0.50)   # Muted gray
const FLASH_BAND     = RGBAf(0.82, 0.15, 0.08, 0.06)   # Very light red bg

# ── Figure ───────────────────────────────────────────────────────────────────
println("Creating figure...")
fig = Figure(size = (1000, 850), figure_padding = (55, 30, 35, 20))

ax = Axis(fig[1, 1],
    title     = "Fleet-Wide Sentinel Flash — 25–27 May 2011",
    titlesize = 22,
    xlabel    = "UTC time",
    ylabel    = "PRN",
    ylabelsize = 18,
    xlabelsize = 18,
)

ylims!(ax, -1.0, 34.5)
ax.yticks = (1:32, string.(1:32))

# X-axis: hours 0–72, labelled as dates and times
tick_hours  = Float64[0, 6, 12, 18, 24, 30, 36, 42, 48, 54, 60, 66, 72]
tick_labels = [Dates.format(T_ORIGIN + Hour(Int(h)), "u dd HH:MM") for h in tick_hours]
ax.xticks   = (tick_hours, tick_labels)
ax.xticklabelrotation = π/6
xlims!(ax, 0, 72)

# ── Background: highlight the flash day ──────────────────────────────────────
band!(ax, [24.0, 48.0], [0.5, 0.5], [32.5, 32.5]; color = FLASH_BAND)
vlines!(ax, [24.0, 48.0]; color = RGBAf(0.82, 0.15, 0.08, 0.20), linewidth = 0.8,
        linestyle = :dash)

# Day labels at top (moved up to avoid overlap with PRN 32 and cropping)
text!(ax, 12.0, 33.0; text = "25 May", fontsize = 14, align = (:center, :bottom),
      color = :gray50)
text!(ax, 36.0, 33.0; text = "26 May", fontsize = 16, align = (:center, :bottom),
      color = RGBAf(0.82, 0.15, 0.08, 0.80))
text!(ax, 60.0, 33.0; text = "27 May", fontsize = 14, align = (:center, :bottom),
      color = :gray50)

# ── PRN 1: Indicate as having no data ─────────────────────────────────────────
text!(ax, 36.0, 1.0; text = "(No data for PRN 1)", fontsize = 13,
      align = (:center, :center), color = :gray60, font = :italic)

# ── Draw segments ────────────────────────────────────────────────────────────
# Sentinel segments: thick red bars
# Normal segments: thin gray bars
for row in eachrow(segments)
    color = row.is_sentinel ? SENTINEL_COLOR : NORMAL_COLOR
    lw    = row.is_sentinel ? 5.0 : 2.0
    y     = Float64(row.prn)
    linesegments!(ax, [Point2f(row.x1, y), Point2f(row.x2, y)];
                  color = color, linewidth = lw)
end

# ── Annotations ──────────────────────────────────────────────────────────────
# Count PRNs that entered sentinel on May 26
sentinel_26 = filter(r -> r.is_sentinel &&
    Date(r.t_start) == Date(2011, 5, 26), segments)
n_prns_flash = length(unique(sentinel_26.prn))

# Positioned well below PRN 1
text!(ax, 36.0, -0.5;
    text     = "31 of 32 satellites entered the all-¬ (0xAC) sentinel within hours — no corresponding NANU",
    fontsize = 14,
    align    = (:center, :bottom),
    color    = :gray35)

# ── Legend ────────────────────────────────────────────────────────────────────
Legend(fig[2, 1],
    [LineElement(color = SENTINEL_COLOR, linewidth = 5),
     LineElement(color = NORMAL_COLOR,   linewidth = 2)],
    ["All-¬ sentinel (0xAC)", "Normal message"],
    framevisible = false,
    labelsize = 15,
    padding = (8, 8, 4, 4),
    orientation = :horizontal,
)
rowgap!(fig.layout, 4)

# ── Save ─────────────────────────────────────────────────────────────────────
println("Saving...")
png_path = joinpath(OUT_DIR, "fleet_flash_2011.png")
pdf_path = joinpath(OUT_DIR, "fleet_flash_2011.pdf")
svg_path = joinpath(OUT_DIR, "fleet_flash_2011.svg")
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
