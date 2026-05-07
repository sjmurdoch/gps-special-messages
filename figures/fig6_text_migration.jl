#!/usr/bin/env julia
#
# Plot: TEXT-prefixed message migration timeline (2023–2026)
#
# A focused, single-panel chart of every TEXT-prefix broadcast event in the
# corpus.  Each (date, PRN, message) triple is one marker; marker size scales
# with daily observation count.  Annotated phases:
#   1. First TEXT message — PRN 8, 13 Dec 2023
#   2. Multi-PRN distributions — Mar 2024 (10 PRNs), Oct 2024 (4 PRNs)
#   3. Daily PRN 1 burst — Dec 2024 → Jan 2025
#   4. Daily PRN 21 bursts — Mar 2025, Jun 2025
#   5. Daily PRN 20 burst — Jul–Aug 2025
#
# Usage:
#   julia --project plot_text_migration.jl [messages.duckdb]

using DuckDB, DataFrames, Dates
using CairoMakie
using Colors

const DB_PATH = length(ARGS) >= 1 ? ARGS[1] : "data/messages.duckdb"
const OUT_DIR = joinpath(@__DIR__, "output")
mkpath(OUT_DIR)

# ── Load data ────────────────────────────────────────────────────────────────
println("Loading TEXT-prefixed messages from $DB_PATH...")
db = DuckDB.DB(DB_PATH; readonly=true)

df = DBInterface.execute(db, """
    SELECT DATE(datetime) AS day,
           prn,
           ascii_message,
           COUNT(*) AS obs
    FROM special_messages
    WHERE ascii_message LIKE 'TEXT%'
    GROUP BY day, prn, ascii_message
    ORDER BY day, prn
""") |> DataFrame

close(db)
println("Loaded $(nrow(df)) (day, PRN, message) triples")

# ── Tufte theme ──────────────────────────────────────────────────────────────
set_theme!(Theme(
    backgroundcolor = :white,
    fontsize        = 16,
    Axis = (
        backgroundcolor   = :transparent,
        xgridvisible      = false,
        ygridvisible      = true,
        ygridcolor        = RGBAf(0.85, 0.85, 0.85, 0.5),
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
t_lo = Date(2023, 10, 1)
t_hi = Date(2026, 2, 1)
to_days(d) = Dates.value(d - t_lo) / 1.0

df.x = to_days.(df.day)
total_days = to_days(t_hi)

# Month/year ticks
xticks_d = Date[]
xlabels  = String[]
for y in 2023:2026, m in 1:12
    d = Date(y, m, 1)
    if d >= t_lo && d <= t_hi
        push!(xticks_d, d)
        # Major label only at January, otherwise abbreviated month
        if m == 1
            push!(xlabels, string(y))
        elseif m in (4, 7, 10)
            push!(xlabels, lowercase(Dates.monthabbr(m)))
        else
            push!(xlabels, "")
        end
    end
end
xtick_pos = to_days.(xticks_d)

# ── PRN axis (filtered to active PRNs) ───────────────────────────────────────
active_prns = sort(unique(df.prn))
n_prn = length(active_prns)
prn_to_y = Dict(p => i for (i, p) in enumerate(active_prns))
df.y = [prn_to_y[p] for p in df.prn]

# ── Colours: group by broadcast phase ────────────────────────────────────────
# Phase 1: 2023-12-13 only (inception, PRN 8)
# Phase 2: 2024-03-18 / 2024-07-31 / 2024-10-10 (multi-PRN distributions)
# Phase 3: 2024-12-29 → 2025-01-13 (PRN 1 daily)
# Phase 4: 2025-03-19 → 2025-06-14 (PRN 21 daily)
# Phase 5: 2025-07-31 → 2025-08-02 (PRN 20 daily)
function classify_phase(day::Date, prn::Integer)
    if day == Date(2023, 12, 13)
        return :inception
    elseif day in (Date(2024, 3, 18), Date(2024, 7, 31), Date(2024, 10, 10))
        return :multiprn
    elseif day >= Date(2024, 12, 29) && day <= Date(2025, 1, 13) && prn == 1
        return :prn1
    elseif day >= Date(2025, 3, 19) && day <= Date(2025, 6, 14) && prn == 21
        return :prn21
    elseif day >= Date(2025, 7, 31) && day <= Date(2025, 8, 2) && prn == 20
        return :prn20
    else
        return :other
    end
end
df.phase = [classify_phase(r.day, r.prn) for r in eachrow(df)]

const PHASE_COLOURS = Dict(
    :inception => RGBAf(0.82, 0.15, 0.08, 0.95),  # warm red
    :multiprn  => RGBAf(0.05, 0.45, 0.65, 0.85),  # teal
    :prn1      => RGBAf(0.20, 0.20, 0.20, 0.90),  # dark gray
    :prn21     => RGBAf(0.55, 0.20, 0.55, 0.90),  # purple
    :prn20     => RGBAf(0.80, 0.45, 0.05, 0.90),  # amber
    :other     => RGBAf(0.40, 0.40, 0.40, 0.70),  # neutral gray
)

# ── Marker size: scale with obs count ────────────────────────────────────────
# Use sqrt for area scaling, normalised to the maximum obs/day actually present.
max_obs = maximum(df.obs)
marker_size(o) = 4.0 + 12.0 * sqrt(o / max_obs)
df.markersize = marker_size.(df.obs)

# ── Figure ───────────────────────────────────────────────────────────────────
println("Creating figure...")
fig = Figure(size = (1150, 540), figure_padding = (50, 25, 30, 20))

ax = Axis(fig[1, 1],
    title      = "TEXT-prefix migration: every broadcast event, December 2023 – August 2025",
    titlesize  = 21,
    ylabel     = "PRN",
    ylabelsize = 17,
)
ax.xticks = (xtick_pos, xlabels)
ax.yticks = (1:n_prn, string.(active_prns))
xlims!(ax, -total_days * 0.005, total_days * 1.005)
ylims!(ax, -2.0, n_prn + 1.0)  # extra headroom above and below for annotations / legend

# ── Plot points by phase, so legend can be built cleanly ─────────────────────
for ph in (:multiprn, :other, :prn1, :prn21, :prn20, :inception)
    sub = df[df.phase .== ph, :]
    isempty(sub) && continue
    scatter!(ax, sub.x, Float64.(sub.y);
        color = PHASE_COLOURS[ph],
        markersize = sub.markersize,
        strokewidth = 0,
    )
end

# ── Annotations ──────────────────────────────────────────────────────────────
function annotate!(ax, day, prn, txt; align = (:left, :bottom),
                   offset_x = 8, offset_y = 0.35, color = :gray25)
    x = to_days(day)
    y = prn_to_y[prn]
    text!(ax, x + offset_x, y + offset_y;
        text = txt, fontsize = 14, align = align, color = color)
end

# 1. First TEXT message
annotate!(ax, Date(2023, 12, 13), 8,
    "First TEXT message\nPRN 8 · 13 Dec 2023";
    align = (:left, :center), offset_x = 12, offset_y = 0.0,
    color = PHASE_COLOURS[:inception])

# 2. The 10-PRN distribution event of 2024-03-18
annotate!(ax, Date(2024, 3, 18), 17,
    "10-PRN distribution\n18 Mar 2024";
    align = (:left, :center), offset_x = -90, offset_y = -1.0,
    color = PHASE_COLOURS[:multiprn])

# 3. The 4-PRN distribution of 2024-10-10
annotate!(ax, Date(2024, 10, 10), 14,
    "4 PRNs\n10 Oct 2024";
    align = (:left, :center), offset_x = -50, offset_y = 1.5,
    color = PHASE_COLOURS[:multiprn])

# 4. PRN 1 daily burst — place ABOVE the markers (PRN 1 sits at y=1, lowest row)
annotate!(ax, Date(2025, 1, 5), 1,
    "Daily PRN 1\n29 Dec 2024 → 13 Jan 2025";
    align = (:center, :bottom), offset_x = 0, offset_y = 0.6,
    color = PHASE_COLOURS[:prn1])

# 5. PRN 21 daily bursts — between the two clusters
annotate!(ax, Date(2025, 4, 25), 21,
    "Daily PRN 21\nMar & Jun 2025";
    align = (:center, :bottom), offset_x = 0, offset_y = 0.6,
    color = PHASE_COLOURS[:prn21])

# 6. PRN 20 daily burst
annotate!(ax, Date(2025, 8, 1), 20,
    "Daily PRN 20\nJul–Aug 2025";
    align = (:left, :center), offset_x = 14, offset_y = 0.0,
    color = PHASE_COLOURS[:prn20])

# Marker-size key — placed in the headroom BELOW the PRN axis (y < 0).
# Each example dot is followed by its obs/day value so the encoding is legible.
key_x = to_days(Date(2024, 12, 20))
key_y = -1.35
text!(ax, key_x - 5, key_y;
    text = "Marker size (obs/day):",
    fontsize = 13, align = (:right, :center), color = :gray45)
pair_spacing = 38  # horizontal gap (in days) between successive (dot, label) pairs
# Largest example dot uses the actual max obs/day so it matches the largest data marker.
for (i, obs) in enumerate([1, 30, max_obs])
    sz = marker_size(obs)
    dot_x = key_x + (i-1) * pair_spacing
    scatter!(ax, [dot_x], [key_y];
        color = RGBAf(0.4, 0.4, 0.4, 0.7), markersize = sz, strokewidth = 0)
    text!(ax, dot_x + 6, key_y;
        text = string(obs), fontsize = 13, align = (:left, :center), color = :gray45)
end

# ── Footer note ──────────────────────────────────────────────────────────────
text!(ax, 0, -0.5;
    text = "Each marker is one (PRN, day) broadcast of one TEXT-prefixed message. " *
           "All 26 unique messages, 38 (PRN, day) combinations, 2,398 total observations.",
    fontsize = 13, align = (:left, :center), color = :gray45)

# ── Save ─────────────────────────────────────────────────────────────────────
println("Saving...")
png_path = joinpath(OUT_DIR, "text_migration.png")
pdf_path = joinpath(OUT_DIR, "text_migration.pdf")
svg_path = joinpath(OUT_DIR, "text_migration.svg")
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
