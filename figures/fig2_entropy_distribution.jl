#!/usr/bin/env julia
#
# Plot: Marginal entropy distribution of GPS special messages vs. random baseline
#
# The random baseline samples uniformly from the 47 byte values actually observed
# in GPS special messages (not all 256), giving a tighter comparison that isolates
# structural patterns beyond the restricted alphabet.
#
# Usage:
#   julia --project plot_entropy_distribution.jl [analysis_output/out.txt] [messages.duckdb]
#
# Set HIGHLIGHT_TEXT=0 to render TEXT-prefixed messages with the same colour and
# stroke as ordinary messages in the rug plot (default: highlight in green).

include(joinpath(@__DIR__, "..", "src", "ppm_model.jl"))
using .PPMEntropy
using CairoMakie
using DuckDB
using Statistics
using Random

const RANDOM_SMOOTHING = 1000
const GPS_ALPHABET_SIZE = 45
const HIGHLIGHT_TEXT = lowercase(get(ENV, "HIGHLIGHT_TEXT", "1")) ∉ ("0", "false", "no")

function parse_output(filepath)
    m_bits = Float64[]
    texts = String[]
    for line in readlines(filepath)
        m = match(r"^(\d{4}-\d{2}-\d{2})\s+(\d+)\s+([\d.]+)", line)
        m === nothing && continue
        push!(m_bits, parse(Float64, m[3]))
        i2 = findlast('|', line)
        i1 = i2 === nothing ? nothing : findprev('|', line, prevind(line, i2))
        push!(texts, (i1 !== nothing && i2 !== nothing) ? line[nextind(line, i1):prevind(line, i2)] : "")
    end
    (; m_bits, texts)
end

function categorize(texts)
    map(texts) do t
        HIGHLIGHT_TEXT && startswith(t, "TEXT") && return :text
        :normal
    end
end

function get_alphabet(db_path)
    db = DuckDB.DB(db_path; readonly=true)
    result = DBInterface.execute(db, "SELECT DISTINCT raw_bytes FROM special_messages")
    alphabet = Set{UInt8}()
    for row in result
        for b in Vector{UInt8}(row.raw_bytes)
            push!(alphabet, b)
        end
    end
    DBInterface.close!(db)
    sort(collect(alphabet))
end

function simulate_random(n, len, order, alphabet, seed)
    rng = Xoshiro(seed)
    msgs = [rand(rng, alphabet, len) for _ in 1:n]
    model = PPMModel(order)
    for m in msgs
        PPMEntropy.update!(model, m)
    end
    scores = Vector{Float64}(undef, n)
    for i in 1:n
        PPMEntropy.update!(model, msgs[i]; delta=-1)
        scores[i] = score_sequence(model, msgs[i])
        PPMEntropy.update!(model, msgs[i]; delta=+1)
    end
    scores
end

function main()
    infile = length(ARGS) >= 1 ? ARGS[1] : joinpath(@__DIR__, "..", "analysis", "reports", "marginal_entropy_ppm.md")
    db_path = length(ARGS) >= 2 ? ARGS[2] : "data/messages.duckdb"
    if !isfile(infile)
        println(stderr, "Error: '$infile' not found")
        exit(1)
    end
    if !isfile(db_path)
        println(stderr, "Error: Database '$db_path' not found")
        exit(1)
    end
    outdir = joinpath(@__DIR__, "output")
    mkpath(outdir)

    println(stderr, "Parsing entropy values...")
    data = parse_output(infile)
    actual = data.m_bits
    cats = categorize(data.texts)
    n = length(actual)
    println(stderr, "  $n messages parsed")

    n_alpha = GPS_ALPHABET_SIZE
    alphabet = collect(UInt8, 1:GPS_ALPHABET_SIZE)

    println(stderr, "Simulating random baseline (n=$n ⨉ $RANDOM_SMOOTHING, PPM-D order 8, $n_alpha-symbol alphabet)...")
    
    random = Vector{Float64}(undef, n*RANDOM_SMOOTHING)
    for i in 0:RANDOM_SMOOTHING-1
        random[i*n+1:(i+1)*n] = simulate_random(n, 22, 8, alphabet, 42+i)
        (i+1) % 100 == 0 && println(stderr, "  Simulating: $(i+1) / $RANDOM_SMOOTHING")
    end
    println(stderr, "  Done.")

    # Separate extreme outliers (outliers at ~410 bits)
    cutoff = 200.0
    actual_main = filter(x -> x <= cutoff, actual)
    n_extreme = count(x -> x > cutoff, actual)
    extreme_min = n_extreme > 0 ? minimum(filter(x -> x > cutoff, actual)) : 0.0
    extreme_max = n_extreme > 0 ? maximum(filter(x -> x > cutoff, actual)) : 0.0

    μa = mean(actual)       # stats over all messages (including outliers)
    σa = std(actual)
    μr = mean(random)
    σr = std(random)

    # Colors (muted, print-friendly)
    blue  = RGBf(0.176, 0.306, 0.525)
    red   = RGBf(0.690, 0.188, 0.133)
    green = RGBf(0.133, 0.545, 0.271)
    amber = RGBf(0.800, 0.522, 0.000)
    dk    = RGBf(0.25, 0.25, 0.25)
    md    = RGBf(0.50, 0.50, 0.50)
    lt    = RGBf(0.78, 0.78, 0.78)

    # Axis range: accommodate both distributions with padding
    all_vals = vcat(actual_main, random)
    xlo = floor(minimum(all_vals) / 5) * 5 - 5
    xhi = ceil(maximum(all_vals) / 5) * 5 + 5
    bins = collect(range(xlo, xhi, step=0.5))

    # Compute peak densities for annotation placement
    function peak_density(data, edges)
        bw = edges[2] - edges[1]
        counts = zeros(length(edges) - 1)
        for x in data
            i = clamp(searchsortedlast(edges, x), 1, length(counts))
            counts[i] += 1
        end
        maximum(counts) / (length(data) * bw)
    end
    peak_a = peak_density(actual_main, bins)
    peak_r = peak_density(random, bins)
    y_max = max(peak_a, peak_r) * 1.45

    # Bits-per-byte tick positions (whole numbers that fall within x range)
    bpb_ticks_val = Float64[]
    bpb_ticks_lab = String[]
    for bpb in 4.0:0.5:9.0
        bits = bpb * 22
        if xlo <= bits <= xhi
            push!(bpb_ticks_val, bits)
            push!(bpb_ticks_lab, isinteger(bpb) ? string(Int(bpb), ".0") : string(bpb))
        end
    end

    # ── Figure ──
    fig = Figure(size=(880, 500), backgroundcolor=:white)

    # Main axis
    ax = Axis(fig[1, 1],
        ylabel="Probability density",
        topspinevisible=false,
        rightspinevisible=false,
        xgridvisible=false,
        ygridvisible=false,
        leftspinecolor=md,
        bottomspinecolor=md,
        xtickcolor=md, ytickcolor=md,
        ylabelcolor=dk,
        xticklabelcolor=md, yticklabelcolor=md,
        ylabelsize=17,
        xticklabelsize=15, yticklabelsize=15,
        limits=(xlo, xhi, 0, y_max),
    )

    # Secondary x-axis: bits per byte
    ax_top = Axis(fig[1, 1],
        xaxisposition=:top,
        xlabel="Bits per byte",
        xlabelsize=15, xlabelcolor=lt,
        xticklabelsize=14, xticklabelcolor=lt,
        xticks=(bpb_ticks_val, bpb_ticks_lab),
        topspinecolor=lt, xtickcolor=lt,
        leftspinevisible=false, rightspinevisible=false,
        bottomspinevisible=false,
        yticklabelsvisible=false, yticksvisible=false, ylabelvisible=false,
        xgridvisible=false, ygridvisible=false,
        limits=(xlo, xhi, 0, y_max),
    )

    # Histograms
    density!(ax, random,
        color=(red, 0.10), strokecolor=(red, 0.35), strokewidth=0.5)
    hist!(ax, actual_main, bins=bins, normalization=:pdf,
        color=(blue, 0.22), strokecolor=(blue, 0.65), strokewidth=0.5)
    #hist!(ax, random, bins=bins, normalization=:pdf,
    #    color=(red, 0.20), strokecolor=(red, 0.65), strokewidth=0.5)


    # Mean indicator lines
    vlines!(ax, [μa], color=(blue, 0.4), linewidth=0.8, linestyle=:dot)
    vlines!(ax, [μr], color=(red, 0.4), linewidth=0.8, linestyle=:dot)

    # Direct labels on distributions
    text!(ax, μa - 2, peak_a + y_max * 0.06,
        text="GPS messages (n=$n)\nμ = $(round(μa, digits=1)) bits, σ = $(round(σa, digits=1))",
        fontsize=14, color=blue, align=(:center, :bottom))

    # Position random label to avoid histogram overlap
    random_label_x = μr < xhi - 15 ? μr : μr - 3
    text!(ax, random_label_x + 2, peak_r + y_max * 0.12,
        text="Random baseline (n=$n, $n_alpha-symbol alphabet)\nμ = $(round(μr, digits=1)) bits, σ = $(round(σr, digits=1))",
        fontsize=14, color=red, align=(:center, :bottom))

    # Gap bracket between means (only if distributions are separated)
    if abs(μr - μa) > 3 * max(σa, σr)
        y_br = y_max * 0.06
        δ = y_max * 0.02
        gap = round(μr - μa, digits=1)
        lines!(ax, [μa, μr], [y_br, y_br], color=dk, linewidth=0.7)
        lines!(ax, [μa, μa], [y_br - δ, y_br + δ], color=dk, linewidth=0.7)
        lines!(ax, [μr, μr], [y_br - δ, y_br + δ], color=dk, linewidth=0.7)
        text!(ax, (μa + μr) / 2, y_br + δ * 1.5,
            text="≈$gap bits",
            fontsize=14, color=dk, align=(:center, :bottom))
    end

    # Outlier annotation
    if n_extreme > 0
        text!(ax, xhi - 1, y_max * 0.97,
            text="$n_extreme outliers off-scale →",
            fontsize=13, color=amber, align=(:right, :top))
    end

    # ── Rug plot ──
    ax_rug = Axis(fig[2, 1], height=25,
        xlabel="Marginal entropy (bits)",
        xlabelsize=17, xlabelcolor=dk,
        xticklabelsize=15, xtickcolor=md, xticklabelcolor=md,
        topspinevisible=false, rightspinevisible=false,
        leftspinevisible=false,
        bottomspinecolor=md,
        xgridvisible=false, ygridvisible=false,
        yticklabelsvisible=false, yticksvisible=false, ylabelvisible=false,
        limits=(xlo, xhi, 0, 1),
    )
    linkxaxes!(ax, ax_rug)
    hidexdecorations!(ax, label=true, ticklabels=true, ticks=true, minorticks=true)

    # Batch rug marks by category
    for (cat, col, lw, m) in [(:normal, (blue, 0.9), 0.3, 0.2),
                            (:text, (green, 0.9), 1.2, 0.05),
                            (:outlier, (amber, 0.9), 1.2, 0.05)]
        xs = [x for (x, c) in zip(actual, cats) if c == cat && x <= cutoff]
        isempty(xs) && continue
        segs = [Point2f(x, m) => Point2f(x, 1 - m) for x in xs]
        linesegments!(ax_rug, segs, color=col, linewidth=lw)
    end

    # # Minimal rug legend
    # for (label, col, xfrac) in [("normal", blue, 0.88),
    #                              ("TEXT", green, 0.93),
    #                              ("outlier", amber, 0.98)]
    #     text!(ax_rug, xlo + (xhi - xlo) * xfrac, 0.5,
    #         text=label, fontsize=7, color=col, align=(:center, :center))
    # end

    rowgap!(fig.layout, 0)
    rowsize!(fig.layout, 2, 25)

    # Save
    outpath = joinpath(outdir, "entropy_distribution.png")
    save(outpath, fig, px_per_unit=parse(Float64, get(ENV, "PNG_PX_PER_UNIT", "3")))
    save(joinpath(outdir, "entropy_distribution.pdf"), fig)
    save(joinpath(outdir, "entropy_distribution.svg"), fig)
    println(stderr, "Saved: $outpath")
    println(outpath)
end

main()
