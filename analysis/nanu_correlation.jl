#!/usr/bin/env julia
#
# NANU Correlation Analysis for GPS Special Messages
#
# Correlates CUSUM-detected behavioral change points with NANUs (Notice
# Advisory to Navstar Users) from GPS Operational Advisory files to determine
# whether observed message regime changes coincide with documented GPS
# operational events.
#
# Usage:
#   julia --project analyze_nanu_correlation.jl [messages.duckdb] [oa_dir]
#
# Output:
#   - Populates nanu_records and change_point_nanu_correlations tables in the DB
#   - Writes analysis_output/nanu_correlation_report.md

include(joinpath(@__DIR__, "..", "src", "GPSSpecialMessages.jl"))
using .GPSSpecialMessages

using DuckDB
using DataFrames
using Dates
using Printf
using Random

# ── Constants ─────────────────────────────────────────────────────────────────

const DEFAULT_DB = "data/messages.duckdb"
const DEFAULT_OA_DIR = "data/ops_advisories"
const OUTPUT_DIR = get(ENV, "REPORTS_DIR", joinpath(@__DIR__, "reports"))
const REPORT_FILE = joinpath(OUTPUT_DIR, "nanu_correlation.md")

# Correlation windows (days)
const WEEKLY_WINDOW_DAYS = 7
const DAILY_WINDOW_DAYS  = 3

# Effect-size filter: keep only CPs above this percentile of |Cohen's d|
const EFFECT_SIZE_PERCENTILE = 0.75

# Permutation test
const N_PERMUTATIONS = 1000

# Number of weeks before/after a CP used to estimate pre/post means
const EFFECT_WINDOW_WEEKS = 8

# ── Helpers ───────────────────────────────────────────────────────────────────

fmt_date(dt::DateTime) = Dates.format(dt, "yyyy-mm-dd")
fmt_pct(x) = @sprintf("%.1f%%", 100.0 * x)

# ── Effect-Size Computation ───────────────────────────────────────────────────

"""
    compute_effect_sizes(cp_df::DataFrame, metrics_df::DataFrame) -> Vector{Float64}

For each change point, compute Cohen's d: the standardized mean difference
between the metric values in the window before vs after the change point.

Uses `EFFECT_WINDOW_WEEKS` weeks on each side.  Returns |d| (absolute value)
so that both increases and decreases are treated symmetrically.  Returns 0.0
when there are insufficient data points on either side.
"""
function compute_effect_sizes(cp_df::DataFrame, metrics_df::DataFrame)::Vector{Float64}
    effect_sizes = Float64[]

    for cp in eachrow(cp_df)
        d = _cohen_d_for_cp(cp, metrics_df)
        push!(effect_sizes, d)
    end

    return effect_sizes
end

function _cohen_d_for_cp(cp, metrics_df::DataFrame)::Float64
    gran = cp.granularity
    prn  = cp.prn
    metric = cp.metric
    dt   = cp.detected_at

    # Filter to matching granularity + PRN
    sub = filter(r -> r.granularity == gran && r.prn == prn, metrics_df)
    isempty(sub) && return 0.0

    # Extract the metric column
    hasproperty(sub, Symbol(metric)) || return 0.0
    col = sub[!, Symbol(metric)]
    times = sub.period_start

    window = Day(EFFECT_WINDOW_WEEKS * 7)

    # Pre: [dt - window, dt)
    pre_mask = (times .>= dt - window) .& (times .< dt)
    # Post: [dt, dt + window)
    post_mask = (times .>= dt) .& (times .< dt + window)

    pre_vals  = Float64[Float64(v) for (v, m) in zip(col, pre_mask) if m && !ismissing(v)]
    post_vals = Float64[Float64(v) for (v, m) in zip(col, post_mask) if m && !ismissing(v)]

    length(pre_vals) < 2 && return 0.0
    length(post_vals) < 2 && return 0.0

    mu_pre  = sum(pre_vals) / length(pre_vals)
    mu_post = sum(post_vals) / length(post_vals)

    var_pre  = sum((x - mu_pre)^2 for x in pre_vals) / (length(pre_vals) - 1)
    var_post = sum((x - mu_post)^2 for x in post_vals) / (length(post_vals) - 1)

    # Pooled standard deviation
    n1, n2 = length(pre_vals), length(post_vals)
    sp = sqrt(((n1 - 1) * var_pre + (n2 - 1) * var_post) / (n1 + n2 - 2))

    sp < 1e-12 && return 0.0

    return abs(mu_post - mu_pre) / sp
end

"""
    filter_by_effect_size(cp_df::DataFrame, effect_sizes::Vector{Float64};
                          percentile::Float64=EFFECT_SIZE_PERCENTILE) -> DataFrame

Keep only the change points whose |Cohen's d| is at or above the given percentile.
"""
function filter_by_effect_size(cp_df::DataFrame, effect_sizes::Vector{Float64};
                               percentile::Float64=EFFECT_SIZE_PERCENTILE)::DataFrame
    @assert length(effect_sizes) == nrow(cp_df)

    sorted_vals = sort(effect_sizes)
    idx = max(1, ceil(Int, percentile * length(sorted_vals)))
    threshold = sorted_vals[idx]

    mask = effect_sizes .>= threshold
    return cp_df[mask, :]
end

# ── Correlation Logic ─────────────────────────────────────────────────────────

"""
    correlate_change_points(cp_df::DataFrame, nanu_df::DataFrame) -> DataFrame

For each change point, find all NANUs within the time window where PRN matches.

PRN matching rules:
- NANU PRN = CP PRN (direct match)
- NANU PRN is NULL (GENERAL/LEAPSEC — affects whole fleet)
- CP PRN = 0 (fleet-wide aggregate — any NANU matches)
"""
function correlate_change_points(cp_df::DataFrame, nanu_df::DataFrame)::DataFrame
    rows = NamedTuple{(:cp_detected_at, :cp_granularity, :cp_prn, :cp_metric,
                        :nanu_id, :nanu_type, :nanu_prn, :time_offset_days, :prn_match),
                       Tuple{DateTime, String, Int, String,
                             String, String, Union{Int,Missing}, Float64, Bool}}[]

    for cp_row in eachrow(cp_df)
        window_days = cp_row.granularity == "weekly" ? WEEKLY_WINDOW_DAYS : DAILY_WINDOW_DAYS

        for nanu_row in eachrow(nanu_df)
            offset_days = Dates.value(cp_row.detected_at - nanu_row.msg_datetime) / (24 * 3600 * 1000)

            abs(offset_days) > window_days && continue

            # PRN matching
            nanu_prn = ismissing(nanu_row.prn) ? nothing : nanu_row.prn
            cp_prn = cp_row.prn

            prn_matches = false
            if cp_prn == 0
                # Fleet-wide CP: any NANU matches
                prn_matches = true
            elseif isnothing(nanu_prn)
                # GENERAL/LEAPSEC: affects all satellites
                prn_matches = true
            elseif nanu_prn == cp_prn
                # Direct PRN match
                prn_matches = true
            end

            prn_matches || continue

            push!(rows, (
                cp_detected_at = cp_row.detected_at,
                cp_granularity = cp_row.granularity,
                cp_prn         = cp_prn,
                cp_metric      = cp_row.metric,
                nanu_id        = nanu_row.nanu_id,
                nanu_type      = nanu_row.nanu_type,
                nanu_prn       = isnothing(nanu_prn) ? missing : nanu_prn,
                time_offset_days = offset_days,
                prn_match      = !isnothing(nanu_prn) && nanu_prn == cp_prn,
            ))
        end
    end

    return DataFrame(rows)
end

"""
    compute_correlation_rate(cp_df::DataFrame, corr_df::DataFrame) -> Float64

Fraction of change points that have at least one matching NANU.
"""
function compute_correlation_rate(cp_df::DataFrame, corr_df::DataFrame)::Float64
    nrow(cp_df) == 0 && return 0.0

    # Count unique change points (by detected_at + prn + metric)
    cp_keys = Set(zip(cp_df.detected_at, cp_df.prn, cp_df.metric))
    if isempty(corr_df)
        return 0.0
    end
    matched_keys = Set(zip(corr_df.cp_detected_at, corr_df.cp_prn, corr_df.cp_metric))

    return length(matched_keys) / length(cp_keys)
end

"""
    permutation_test(cp_df, nanu_df; n_perms) -> (observed_rate, p_value, null_rates)

Shuffle NANU dates `n_perms` times to estimate the null distribution of
correlation rates. Returns observed rate, one-sided p-value, and the null rates.
"""
function permutation_test(cp_df::DataFrame, nanu_df::DataFrame;
                          n_perms::Int=N_PERMUTATIONS)
    # Observed correlation
    observed_corr = correlate_change_points(cp_df, nanu_df)
    observed_rate = compute_correlation_rate(cp_df, observed_corr)

    # Null distribution: shuffle NANU msg_datetimes
    nanu_dates = nanu_df.msg_datetime
    null_rates = Float64[]

    rng = MersenneTwister(42)  # Reproducible

    for _ in 1:n_perms
        shuffled_nanu = copy(nanu_df)
        shuffled_nanu.msg_datetime = shuffle(rng, copy(nanu_dates))
        shuffled_corr = correlate_change_points(cp_df, shuffled_nanu)
        push!(null_rates, compute_correlation_rate(cp_df, shuffled_corr))
    end

    # One-sided p-value: fraction of null rates >= observed
    p_value = count(r -> r >= observed_rate, null_rates) / n_perms

    return (observed_rate, p_value, null_rates)
end

# ── Main ──────────────────────────────────────────────────────────────────────

function main()
    db_path = length(ARGS) >= 1 ? ARGS[1] : DEFAULT_DB
    oa_dir  = length(ARGS) >= 2 ? ARGS[2] : DEFAULT_OA_DIR

    isfile(db_path) || error("Database not found: $db_path")
    isdir(oa_dir)   || error("OA directory not found: $oa_dir")

    println("Opening database: $db_path")
    db = DuckDB.DB(db_path)

    # ── Step 1: Create tables ─────────────────────────────────────────────
    println("Creating NANU tables…")
    create_nanu_tables!(db)

    # ── Step 2: Parse OA files ────────────────────────────────────────────
    println("Parsing OA files from $oa_dir…")
    nanu_records = parse_all_oa_files(oa_dir; verbose=true)
    println("  → $(length(nanu_records)) unique NANUs")

    # ── Step 3: Save NANUs to database ────────────────────────────────────
    println("Saving NANU records to database…")
    save_nanu_records!(db, nanu_records)

    # ── Step 4: Load change points ────────────────────────────────────────
    println("Loading behavioral change points…")
    cp_df = get_behavioral_change_points(db)
    println("  → $(nrow(cp_df)) change points")

    if isempty(cp_df)
        println("No change points found. Run analyze_behavioral_changes.jl first.")
        close(db)
        return
    end

    # ── Step 5: Load behavioral metrics for effect-size computation ───────
    println("Loading behavioral metrics…")
    metrics_df = DataFrame(DBInterface.execute(db, """
        SELECT * FROM behavioral_metrics ORDER BY period_start, granularity, prn
    """))
    println("  → $(nrow(metrics_df)) metric rows")

    # ── Step 6: Compute effect sizes (Cohen's d) ─────────────────────────
    println("Computing effect sizes (±$(EFFECT_WINDOW_WEEKS)-week window)…")
    effect_sizes = compute_effect_sizes(cp_df, metrics_df)
    nonzero = count(d -> d > 0, effect_sizes)
    println("  → $(nonzero) / $(length(effect_sizes)) CPs with computable effect size")

    sorted_d = sort(filter(d -> d > 0, effect_sizes))
    if !isempty(sorted_d)
        p25_idx = max(1, ceil(Int, 0.25 * length(sorted_d)))
        p50_idx = max(1, ceil(Int, 0.50 * length(sorted_d)))
        p75_idx = max(1, ceil(Int, 0.75 * length(sorted_d)))
        @printf("  → |d| percentiles: p25=%.2f  p50=%.2f  p75=%.2f  max=%.2f\n",
                sorted_d[p25_idx], sorted_d[p50_idx], sorted_d[p75_idx], sorted_d[end])
    end

    # ── Step 7: Filter to strongest CPs ───────────────────────────────────
    strong_cp_df = filter_by_effect_size(cp_df, effect_sizes)
    println("  → $(nrow(strong_cp_df)) CPs above $(Int(EFFECT_SIZE_PERCENTILE*100))th percentile of |d|")

    # ── Step 8: Load NANU records as DataFrame ────────────────────────────
    nanu_df = get_nanu_records(db)
    println("  → $(nrow(nanu_df)) NANUs in database")

    # ── Step 9: Correlate (all CPs — for database storage) ────────────────
    println("Correlating all change points with NANUs…")
    corr_all_df = correlate_change_points(cp_df, nanu_df)
    println("  → $(nrow(corr_all_df)) (change_point, NANU) pairs (all CPs)")

    # ── Step 10: Save correlations ────────────────────────────────────────
    println("Saving correlations to database…")
    save_nanu_correlations!(db, corr_all_df)

    # ── Step 11: Correlate (strong CPs only) ──────────────────────────────
    println("Correlating strongest change points with NANUs…")
    corr_df = correlate_change_points(strong_cp_df, nanu_df)
    println("  → $(nrow(corr_df)) (change_point, NANU) pairs (strong CPs)")

    # ── Step 12: Statistical assessment ───────────────────────────────────
    println("Running permutation test on strong CPs ($N_PERMUTATIONS trials)…")
    (observed_rate, p_value, null_rates) = permutation_test(strong_cp_df, nanu_df)
    println("  → Observed correlation rate: $(fmt_pct(observed_rate))")
    println("  → p-value: $(@sprintf("%.4f", p_value))")
    println("  → Mean null rate: $(fmt_pct(mean(null_rates)))")

    # Also compute all-CP rate for comparison
    all_rate = compute_correlation_rate(cp_df, corr_all_df)

    # ── Step 13: Generate report ──────────────────────────────────────────
    println("Generating report → $REPORT_FILE")
    mkpath(OUTPUT_DIR)
    write_report(nanu_records, cp_df, strong_cp_df, corr_df, nanu_df,
                 observed_rate, p_value, null_rates, all_rate, effect_sizes,
                 db_path, oa_dir)

    close(db)
    println("Done.")
end

# Simple mean helper
mean(x) = sum(x) / length(x)

# ── Report Generation ─────────────────────────────────────────────────────────

function write_report(nanu_records, all_cp_df, cp_df, corr_df, nanu_df,
                      observed_rate, p_value, null_rates, all_rate, effect_sizes,
                      db_path, oa_dir)
    open(REPORT_FILE, "w") do io
        ts = Dates.format(now(UTC), dateformat"yyyy-mm-ddTHH:MM:SS") * "Z"
        script = basename(@__FILE__)
        println(io, "<!-- AUTO-GENERATED by $script on $ts from $db_path — do not edit by hand -->")
        println(io)
        println(io, "# NANU Correlation Analysis — GPS Special Messages")
        println(io)
        println(io, "Analysis restricted to the **strongest $(Int((1 - EFFECT_SIZE_PERCENTILE)*100))%** of change points by effect size (Cohen's d).")
        println(io)

        # ── Section 1: Summary ────────────────────────────────────────────
        println(io, "## 1. Summary")
        println(io)
        println(io, "- **OA files parsed from**: $oa_dir")
        println(io, "- **Total unique NANUs**: $(length(nanu_records))")
        println(io, "- **Total change points (all)**: $(nrow(all_cp_df))")

        # Effect size stats
        nonzero_d = filter(d -> d > 0, effect_sizes)
        if !isempty(nonzero_d)
            sorted_d = sort(nonzero_d)
            p75_idx = max(1, ceil(Int, EFFECT_SIZE_PERCENTILE * length(sorted_d)))
            threshold_d = sorted_d[p75_idx]
            println(io, "- **Effect-size threshold** (p$(Int(EFFECT_SIZE_PERCENTILE*100)) of |d|): $(@sprintf("%.2f", threshold_d))")
        end
        println(io, "- **Strong change points (above threshold)**: $(nrow(cp_df))")
        println(io, "- **Correlated (CP, NANU) pairs**: $(nrow(corr_df))")

        # Count unique CPs that have at least one match
        if !isempty(corr_df)
            matched_cps = length(unique(zip(corr_df.cp_detected_at, corr_df.cp_prn, corr_df.cp_metric)))
        else
            matched_cps = 0
        end
        total_cps = nrow(cp_df)
        println(io, "- **Strong CPs with ≥1 matching NANU**: $matched_cps / $total_cps ($(fmt_pct(observed_rate)))")
        println(io, "- **All CPs correlation rate (for comparison)**: $(fmt_pct(all_rate))")
        println(io, "- **Expected rate under null (random dates)**: $(fmt_pct(mean(null_rates)))")
        println(io, "- **p-value (one-sided)**: $(@sprintf("%.4f", p_value))")

        sig = p_value < 0.05 ? "**statistically significant** (p < 0.05)" :
              "**not statistically significant** (p ≥ 0.05)"
        println(io, "- **Assessment**: Correlation rate is $sig")
        println(io)

        # ── Effect-size distribution ──────────────────────────────────────
        println(io, "### Effect-Size Distribution (|Cohen's d|)")
        println(io)
        if !isempty(nonzero_d)
            sorted_d = sort(nonzero_d)
            percentiles = [0.10, 0.25, 0.50, 0.75, 0.90, 0.95]
            println(io, "| Percentile | |d| |")
            println(io, "|---|---|")
            for p in percentiles
                idx = max(1, ceil(Int, p * length(sorted_d)))
                println(io, "| p$(Int(p*100)) | $(@sprintf("%.2f", sorted_d[idx])) |")
            end
            println(io, "| max | $(@sprintf("%.2f", sorted_d[end])) |")
            println(io)
            println(io, "CPs with zero effect size (insufficient data): $(count(d -> d == 0, effect_sizes)) of $(length(effect_sizes))")
        end
        println(io)

        # ── Section 2: Correlation by NANU type ───────────────────────────
        println(io, "## 2. Correlation by NANU Type")
        println(io)

        if isempty(corr_df)
            println(io, "*No correlations found.*")
        else
            by_type = combine(groupby(corr_df, :nanu_type), nrow => :pair_count,
                              :cp_detected_at => (x -> length(unique(x))) => :unique_cps)
            sort!(by_type, :pair_count, rev=true)

            # Also show total NANUs of each type for context
            nanu_type_counts = combine(groupby(nanu_df, :nanu_type), nrow => :total)

            println(io, "| NANU Type | Correlated Pairs | Unique CPs | Total NANUs of Type |")
            println(io, "|---|---|---|---|")
            for row in eachrow(by_type)
                total_of_type = 0
                match_row = filter(r -> r.nanu_type == row.nanu_type, nanu_type_counts)
                if nrow(match_row) > 0
                    total_of_type = match_row[1, :total]
                end
                println(io, "| $(row.nanu_type) | $(row.pair_count) | $(row.unique_cps) | $total_of_type |")
            end
        end
        println(io)

        # ── Section 3: Correlation by metric ──────────────────────────────
        println(io, "## 3. Correlation by Behavioral Metric")
        println(io)

        if isempty(corr_df)
            println(io, "*No correlations found.*")
        else
            # For each metric, compute rate of CPs that have a match
            metrics = unique(cp_df.metric)
            sort!(metrics)

            println(io, "| Metric | Total CPs | CPs with NANU | Rate |")
            println(io, "|---|---|---|---|")
            for metric in metrics
                metric_cps = filter(r -> r.metric == metric, cp_df)
                metric_corrs = filter(r -> r.cp_metric == metric, corr_df)
                matched = length(unique(zip(metric_corrs.cp_detected_at, metric_corrs.cp_prn)))
                total = nrow(metric_cps)
                rate = total > 0 ? matched / total : 0.0
                println(io, "| $metric | $total | $matched | $(fmt_pct(rate)) |")
            end
        end
        println(io)

        # ── Section 4: Unexplained change points ─────────────────────────
        println(io, "## 4. Unexplained Change Points")
        println(io)
        println(io, "Change points with no matching NANU within the correlation window:")
        println(io)

        if isempty(corr_df)
            unexplained = cp_df
        else
            matched_keys = Set(zip(corr_df.cp_detected_at, corr_df.cp_prn, corr_df.cp_metric))
            unexplained = filter(r -> !((r.detected_at, r.prn, r.metric) in matched_keys), cp_df)
        end

        if isempty(unexplained)
            println(io, "*All change points have at least one matching NANU.*")
        else
            # Show coordinated ones first, then sample of non-coordinated
            coord_unexplained = filter(r -> r.is_coordinated, unexplained)
            if !isempty(coord_unexplained)
                sort!(coord_unexplained, :detected_at)
                dedup = combine(
                    groupby(coord_unexplained, [:detected_at, :metric, :direction]),
                    :coordinated_prn_count => maximum => :prn_count,
                    :granularity => first => :granularity,
                )
                sort!(dedup, :detected_at)

                println(io, "### Coordinated unexplained events")
                println(io)
                println(io, "| Date | Metric | Direction | PRNs |")
                println(io, "|---|---|---|---|")
                for row in eachrow(dedup)
                    println(io, "| $(fmt_date(row.detected_at)) | $(row.metric) | $(row.direction) | $(row.prn_count) |")
                end
                println(io)
            end

            non_coord = filter(r -> !r.is_coordinated, unexplained)
            println(io, "**Total unexplained**: $(nrow(unexplained)) of $(nrow(cp_df)) change points " *
                        "($(nrow(coord_unexplained)) coordinated, $(nrow(non_coord)) non-coordinated)")
        end
        println(io)

        # ── Section 5: Coordinated events with NANUs ─────────────────────
        println(io, "## 5. Coordinated Events and Matching NANUs")
        println(io)

        coord_cps = filter(r -> r.is_coordinated, cp_df)
        if isempty(coord_cps)
            println(io, "*No coordinated events detected.*")
        else
            # De-duplicate coordinated events
            coord_dedup = combine(
                groupby(coord_cps, [:detected_at, :metric, :direction]),
                :coordinated_prn_count => maximum => :prn_count,
                :granularity => first => :granularity,
            )
            sort!(coord_dedup, :detected_at)

            println(io, "| Date | Metric | Direction | PRNs | Matching NANUs |")
            println(io, "|---|---|---|---|---|")
            for row in eachrow(coord_dedup)
                # Find matching NANUs for any CP in this coordinated event
                event_corrs = filter(r ->
                    r.cp_metric == row.metric &&
                    abs(Dates.value(r.cp_detected_at - row.detected_at)) < 1000,  # same timestamp
                    corr_df)

                if isempty(event_corrs)
                    nanu_str = "None"
                else
                    nanu_ids = unique(event_corrs.nanu_id)
                    nanu_strs = String[]
                    for nid in nanu_ids[1:min(3, length(nanu_ids))]
                        nanu_row = filter(r -> r.nanu_id == nid, nanu_df)
                        if nrow(nanu_row) > 0
                            prn_str = ismissing(nanu_row[1, :prn]) ? "—" : string(nanu_row[1, :prn])
                            push!(nanu_strs, "$(nid) ($(nanu_row[1, :nanu_type]), PRN $prn_str)")
                        end
                    end
                    if length(nanu_ids) > 3
                        push!(nanu_strs, "+$(length(nanu_ids) - 3) more")
                    end
                    nanu_str = join(nanu_strs, "; ")
                end

                println(io, "| $(fmt_date(row.detected_at)) | $(row.metric) | $(row.direction) | $(row.prn_count) | $nanu_str |")
            end
        end
        println(io)

        # ── Section 6: Timeline ───────────────────────────────────────────
        println(io, "## 6. Correlation Timeline")
        println(io)

        if isempty(corr_df)
            println(io, "*No correlations to display.*")
        else
            sorted_corr = sort(corr_df, [:cp_detected_at, :cp_prn])
            top_n = min(50, nrow(sorted_corr))

            println(io, "First $top_n correlated pairs (chronological):")
            println(io)
            println(io, "| CP Date | CP PRN | CP Metric | NANU ID | NANU Type | NANU PRN | Offset (days) |")
            println(io, "|---|---|---|---|---|---|---|")
            for row in eachrow(sorted_corr[1:top_n, :])
                cp_prn_str = row.cp_prn == 0 ? "Fleet" : string(row.cp_prn)
                nanu_prn_str = ismissing(row.nanu_prn) ? "—" : string(row.nanu_prn)
                offset_str = @sprintf("%.1f", row.time_offset_days)
                println(io, "| $(fmt_date(row.cp_detected_at)) | $cp_prn_str | $(row.cp_metric) | $(row.nanu_id) | $(row.nanu_type) | $nanu_prn_str | $offset_str |")
            end
            if nrow(sorted_corr) > top_n
                println(io, "| *…$(nrow(sorted_corr) - top_n) more rows not shown* | | | | | | |")
            end
        end
        println(io)

        # ── Parameters ────────────────────────────────────────────────────
        println(io, "---")
        println(io)
        println(io, "**Correlation windows**: weekly CPs ±$(WEEKLY_WINDOW_DAYS) days, daily CPs ±$(DAILY_WINDOW_DAYS) days.")
        println(io, "**Effect-size filter**: top $(Int((1 - EFFECT_SIZE_PERCENTILE)*100))% by |Cohen's d| (±$(EFFECT_WINDOW_WEEKS)-week pre/post window).")
        println(io, "**Permutation test**: $N_PERMUTATIONS trials with shuffled NANU dates.")
        println(io)
        println(io, "**Methodological note**: The permutation test p-value applies to the effect-size-filtered subset of change points, not the full set. This is a conditional test by design — we test whether *strong* behavioral changes (those above the $(Int(EFFECT_SIZE_PERCENTILE*100))th percentile of |Cohen's d|) coincide with NANUs more often than expected by chance. The effect-size threshold is computed from the same data, so the filtering is data-dependent. For comparison, the all-CPs correlation rate is also reported above.")
    end
end

main()
