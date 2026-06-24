#!/usr/bin/env julia
#
# Sentinel–NANU Correlation Analysis for GPS Special Messages
#
# Identifies sentinel observation windows per PRN, correlates them with NANUs
# (Notice Advisory to Navstar Users), and generates a markdown report.
#
# Sentinel messages are those with entropy = 0:
#   - all-¬ (0xAA)   — the dominant sentinel, persisted 10+ years
#   - all-NUL (0x00)  — null bytes
#   - all-space (0x20) — ASCII spaces
#
# Usage:
#   julia --project analyze_sentinel_nanu.jl [messages.duckdb] [oa_dir]
#
# Output:
#   - Populates sentinel_nanu_correlations table in the DB
#   - Writes analysis_output/sentinel_nanu_report.md

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
const REPORT_FILE = joinpath(OUTPUT_DIR, "sentinel_nanu.md")

# Correlation window (days) for matching sentinel events to NANUs
const SENTINEL_WINDOW_DAYS = 14

# Permutation test
const N_PERMUTATIONS = 1000

# Lifecycle NANU types (satellite commissioning / decommissioning)
const LIFECYCLE_NANU_TYPES = Set(["DECOM", "LAUNCH", "USABINIT", "UNUSUFN", "UNUSABLE"])

# Fleet flash detection: minimum PRNs entering sentinel on same day
const FLEET_FLASH_THRESHOLD = 10

# ── Helpers ───────────────────────────────────────────────────────────────────

fmt_date(dt::DateTime) = Dates.format(dt, "yyyy-mm-dd")
fmt_pct(x) = @sprintf("%.1f%%", 100.0 * x)
mean(x) = sum(x) / length(x)

"""
    classify_sentinel(ascii_message::AbstractString) -> String

Classify a zero-entropy message into one of: "all_aa", "all_nul", "all_space".
Falls back to "unknown" if unrecognized.
"""
function classify_sentinel(ascii_message::AbstractString)::String
    # '¬' is U+00AC, '' is U+FFFD (replacement character used for NUL)
    if all(c -> c == '\u00ac', ascii_message)
        return "all_aa"
    elseif all(c -> c == '\ufffd' || c == '\0', ascii_message)
        return "all_nul"
    elseif all(c -> c == ' ', ascii_message)
        return "all_space"
    else
        return "unknown"
    end
end

"""Human-readable sentinel names."""
function sentinel_display_name(sentinel_type::String)::String
    sentinel_type == "all_aa"    && return "all-¬ (0xAA)"
    sentinel_type == "all_nul"   && return "all-NUL (0x00)"
    sentinel_type == "all_space" && return "all-space (0x20)"
    return sentinel_type
end

# ── Stage 1: Identify Sentinel Observation Windows ───────────────────────────

"""
    get_sentinel_observations(db::DuckDB.DB) -> DataFrame

Query all sentinel observations (entropy = 0) from special_messages.
Returns columns: datetime, prn, ascii_message, entropy.
"""
function get_sentinel_observations(db::DuckDB.DB)::DataFrame
    df = DataFrame(DBInterface.execute(db, """
        SELECT datetime, prn, ascii_message, entropy
        FROM special_messages
        WHERE entropy = 0
        ORDER BY prn, datetime
    """))
    return df
end

"""
    compute_sentinel_windows(sentinel_obs::DataFrame) -> DataFrame

For each sentinel × PRN combination, compute the observation window:
first_seen, last_seen, obs_count, sentinel_type.
"""
function compute_sentinel_windows(sentinel_obs::DataFrame)::DataFrame
    windows = DataFrame(
        prn = Int[],
        sentinel_type = String[],
        first_seen = DateTime[],
        last_seen = DateTime[],
        obs_count = Int[],
        duration_days = Float64[],
    )

    for grp in groupby(sentinel_obs, [:prn, :ascii_message])
        prn = grp.prn[1]
        msg = grp.ascii_message[1]
        stype = classify_sentinel(msg)
        first_dt = minimum(grp.datetime)
        last_dt = maximum(grp.datetime)
        dur = Dates.value(last_dt - first_dt) / (24 * 3600 * 1000)

        push!(windows, (
            prn = prn,
            sentinel_type = stype,
            first_seen = first_dt,
            last_seen = last_dt,
            obs_count = nrow(grp),
            duration_days = dur,
        ))
    end

    sort!(windows, [:sentinel_type, :prn])
    return windows
end

"""
    detect_sentinel_transitions(db::DuckDB.DB) -> DataFrame

Detect enter/exit sentinel events by finding transitions where entropy changes
between 0 and non-zero. Returns columns: prn, sentinel_type, event_type
("enter"/"exit"), event_date.
"""
function detect_sentinel_transitions(db::DuckDB.DB)::DataFrame
    # Get all messages ordered by PRN and time, with entropy info
    # Use a window query to get previous/next entropy values
    transitions_df = DataFrame(DBInterface.execute(db, """
        WITH ordered AS (
            SELECT
                prn, datetime, ascii_message, entropy,
                LAG(entropy) OVER (PARTITION BY prn ORDER BY datetime) as prev_entropy,
                LAG(ascii_message) OVER (PARTITION BY prn ORDER BY datetime) as prev_message,
                LEAD(entropy) OVER (PARTITION BY prn ORDER BY datetime) as next_entropy
            FROM (
                SELECT DISTINCT ON (prn, datetime)
                    prn, datetime, ascii_message, entropy
                FROM special_messages
                ORDER BY prn, datetime
            )
        )
        SELECT prn, datetime, ascii_message, entropy, prev_entropy, next_entropy
        FROM ordered
        WHERE
            -- Enter sentinel: previous was non-zero (or NULL = first obs), current is 0
            (entropy = 0 AND (prev_entropy IS NULL OR prev_entropy > 0))
            OR
            -- Exit sentinel: current is 0, next is non-zero (or NULL = last obs doesn't count)
            (entropy = 0 AND next_entropy IS NOT NULL AND next_entropy > 0)
        ORDER BY prn, datetime
    """))

    events = DataFrame(
        prn = Int[],
        sentinel_type = String[],
        event_type = String[],
        event_date = DateTime[],
    )

    for row in eachrow(transitions_df)
        stype = classify_sentinel(row.ascii_message)

        if row.entropy == 0 && (ismissing(row.prev_entropy) || row.prev_entropy > 0)
            push!(events, (prn=row.prn, sentinel_type=stype, event_type="enter", event_date=row.datetime))
        end
        if row.entropy == 0 && !ismissing(row.next_entropy) && row.next_entropy > 0
            push!(events, (prn=row.prn, sentinel_type=stype, event_type="exit", event_date=row.datetime))
        end
    end

    sort!(events, [:event_date, :prn])
    return events
end

"""
    detect_fleet_flashes(events::DataFrame) -> DataFrame

Identify fleet-wide coordinated sentinel events: days when ≥ FLEET_FLASH_THRESHOLD
PRNs enter the same sentinel type.

Returns: event_date (Date), sentinel_type, prn_count, prns (vector).
"""
function detect_fleet_flashes(events::DataFrame)::DataFrame
    enter_events = filter(r -> r.event_type == "enter", events)
    isempty(enter_events) && return DataFrame(
        event_date=Date[], sentinel_type=String[], prn_count=Int[], prns=Vector{Int}[])

    # Group by date (not datetime) and sentinel type
    enter_events[!, :date] = Date.(enter_events.event_date)

    flashes = DataFrame(
        event_date = Date[],
        sentinel_type = String[],
        prn_count = Int[],
        prns = Vector{Int}[],
    )

    for grp in groupby(enter_events, [:date, :sentinel_type])
        if nrow(grp) >= FLEET_FLASH_THRESHOLD
            push!(flashes, (
                event_date = grp.date[1],
                sentinel_type = grp.sentinel_type[1],
                prn_count = nrow(grp),
                prns = sort(unique(grp.prn)),
            ))
        end
    end

    sort!(flashes, :event_date)
    return flashes
end

# ── Stage 2: Match Sentinel Events to NANUs ──────────────────────────────────

"""
    correlate_sentinel_events(events::DataFrame, nanu_df::DataFrame;
                               window_days::Int=SENTINEL_WINDOW_DAYS) -> DataFrame

For each sentinel enter/exit event, find NANUs within ±window_days where:
- NANU PRN matches sentinel PRN, or
- NANU PRN is NULL (fleet-wide GENERAL/LEAPSEC)

Returns the correlation table ready for DB storage.
"""
function correlate_sentinel_events(events::DataFrame, nanu_df::DataFrame;
                                    window_days::Int=SENTINEL_WINDOW_DAYS)::DataFrame
    rows = NamedTuple{(:prn, :sentinel_type, :event_type, :event_date,
                        :nanu_id, :nanu_type, :nanu_prn, :time_offset_days),
                       Tuple{Int, String, String, DateTime,
                             String, String, Union{Int,Missing}, Float64}}[]

    for ev in eachrow(events)
        for nanu in eachrow(nanu_df)
            offset_days = Dates.value(ev.event_date - nanu.msg_datetime) / (24 * 3600 * 1000)
            abs(offset_days) > window_days && continue

            # PRN matching
            nanu_prn = ismissing(nanu.prn) ? nothing : nanu.prn
            prn_matches = false
            if isnothing(nanu_prn)
                prn_matches = true  # fleet-wide NANU
            elseif nanu_prn == ev.prn
                prn_matches = true  # direct match
            end
            prn_matches || continue

            push!(rows, (
                prn = ev.prn,
                sentinel_type = ev.sentinel_type,
                event_type = ev.event_type,
                event_date = ev.event_date,
                nanu_id = nanu.nanu_id,
                nanu_type = nanu.nanu_type,
                nanu_prn = isnothing(nanu_prn) ? missing : nanu_prn,
                time_offset_days = offset_days,
            ))
        end
    end

    return DataFrame(rows)
end

# ── Stage 3: Statistical Assessment ──────────────────────────────────────────

"""
    compute_lifecycle_match_rate(events::DataFrame, corr_df::DataFrame) -> Float64

Fraction of sentinel events that have ≥1 matching lifecycle NANU
(DECOM, LAUNCH, USABINIT, UNUSUFN, UNUSABLE).
"""
function compute_lifecycle_match_rate(events::DataFrame, corr_df::DataFrame)::Float64
    nrow(events) == 0 && return 0.0

    lifecycle_corrs = filter(r -> r.nanu_type in LIFECYCLE_NANU_TYPES, corr_df)
    isempty(lifecycle_corrs) && return 0.0

    matched_keys = Set(zip(lifecycle_corrs.prn, lifecycle_corrs.event_type, lifecycle_corrs.event_date))
    event_keys = Set(zip(events.prn, events.event_type, events.event_date))

    return length(intersect(matched_keys, event_keys)) / length(event_keys)
end

"""
    permutation_test(events, nanu_df; n_perms, window_days) -> (observed_rate, p_value, null_rates)

Shuffle NANU dates to estimate the null distribution of lifecycle match rates.
"""
function permutation_test(events::DataFrame, nanu_df::DataFrame;
                          n_perms::Int=N_PERMUTATIONS,
                          window_days::Int=SENTINEL_WINDOW_DAYS)
    observed_corr = correlate_sentinel_events(events, nanu_df; window_days)
    observed_rate = compute_lifecycle_match_rate(events, observed_corr)

    nanu_dates = nanu_df.msg_datetime
    null_rates = Float64[]
    rng = MersenneTwister(42)

    for _ in 1:n_perms
        shuffled_nanu = copy(nanu_df)
        shuffled_nanu.msg_datetime = shuffle(rng, copy(nanu_dates))
        shuffled_corr = correlate_sentinel_events(events, shuffled_nanu; window_days)
        push!(null_rates, compute_lifecycle_match_rate(events, shuffled_corr))
    end

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

    # ── Step 1: Ensure NANU tables exist ─────────────────────────────────
    println("Creating tables…")
    create_nanu_tables!(db)
    create_sentinel_nanu_table!(db)

    # ── Step 2: Parse and save NANU records ──────────────────────────────
    println("Parsing OA files from $oa_dir…")
    nanu_records = parse_all_oa_files(oa_dir; verbose=true)
    println("  → $(length(nanu_records)) unique NANUs")
    save_nanu_records!(db, nanu_records)

    # ── Step 3: Identify sentinel observations ───────────────────────────
    println("Querying sentinel observations (entropy = 0)…")
    sentinel_obs = get_sentinel_observations(db)
    println("  → $(nrow(sentinel_obs)) sentinel observations")

    if isempty(sentinel_obs)
        println("No sentinel observations found.")
        close(db)
        return
    end

    # ── Step 4: Compute sentinel windows per PRN ─────────────────────────
    println("Computing sentinel observation windows…")
    windows = compute_sentinel_windows(sentinel_obs)
    println("  → $(nrow(windows)) sentinel × PRN combinations")

    for stype in unique(windows.sentinel_type)
        sub = filter(r -> r.sentinel_type == stype, windows)
        println("    $(sentinel_display_name(stype)): $(nrow(sub)) PRNs, $(sum(sub.obs_count)) observations")
    end

    # ── Step 5: Detect sentinel enter/exit transitions ───────────────────
    println("Detecting sentinel enter/exit transitions…")
    events = detect_sentinel_transitions(db)
    n_enter = count(r -> r.event_type == "enter", eachrow(events))
    n_exit  = count(r -> r.event_type == "exit", eachrow(events))
    println("  → $(nrow(events)) transition events ($n_enter enter, $n_exit exit)")

    # ── Step 6: Detect fleet flashes ─────────────────────────────────────
    println("Detecting fleet-wide sentinel flashes…")
    flashes = detect_fleet_flashes(events)
    if !isempty(flashes)
        for row in eachrow(flashes)
            println("  → $(row.event_date): $(row.prn_count) PRNs entered $(sentinel_display_name(row.sentinel_type))")
        end
    else
        println("  → No fleet flashes detected (threshold: $FLEET_FLASH_THRESHOLD PRNs)")
    end

    # ── Step 7: Load NANU records ────────────────────────────────────────
    nanu_df = get_nanu_records(db)
    println("  → $(nrow(nanu_df)) NANUs in database")

    # ── Step 8: Correlate sentinel events with NANUs ─────────────────────
    println("Correlating sentinel events with NANUs (±$(SENTINEL_WINDOW_DAYS) days)…")
    corr_df = correlate_sentinel_events(events, nanu_df)
    println("  → $(nrow(corr_df)) (sentinel event, NANU) pairs")

    lifecycle_corrs = filter(r -> r.nanu_type in LIFECYCLE_NANU_TYPES, corr_df)
    println("  → $(nrow(lifecycle_corrs)) pairs with lifecycle NANUs")

    # ── Step 9: Save correlations to database ────────────────────────────
    println("Saving sentinel-NANU correlations to database…")
    save_sentinel_nanu_correlations!(db, corr_df)

    # ── Step 10: Permutation test ────────────────────────────────────────
    println("Running permutation test ($N_PERMUTATIONS trials)…")
    (observed_rate, p_value, null_rates) = permutation_test(events, nanu_df)
    println("  → Observed lifecycle match rate: $(fmt_pct(observed_rate))")
    println("  → p-value: $(@sprintf("%.4f", p_value))")
    println("  → Mean null rate: $(fmt_pct(mean(null_rates)))")

    # ── Step 11: Identify unexplained events ─────────────────────────────
    event_keys_with_nanu = Set(zip(corr_df.prn, corr_df.event_type, corr_df.event_date))
    unexplained = filter(r -> !((r.prn, r.event_type, r.event_date) in event_keys_with_nanu), events)
    println("  → $(nrow(unexplained)) sentinel events with no matching NANU")

    # ── Step 12: Generate report ─────────────────────────────────────────
    println("Generating report → $REPORT_FILE")
    mkpath(OUTPUT_DIR)
    write_report(windows, events, flashes, corr_df, nanu_df,
                 observed_rate, p_value, null_rates, unexplained,
                 db_path, oa_dir)

    close(db)
    println("Done.")
end

# ── Report Generation ─────────────────────────────────────────────────────────

function write_report(windows, events, flashes, corr_df, nanu_df,
                      observed_rate, p_value, null_rates, unexplained,
                      db_path, oa_dir)
    open(REPORT_FILE, "w") do io
        ts = Dates.format(now(UTC), dateformat"yyyy-mm-ddTHH:MM:SS") * "Z"
        script = basename(@__FILE__)
        println(io, "<!-- AUTO-GENERATED by $script on $ts from $db_path — do not edit by hand -->")
        println(io)
        println(io, "# Sentinel–NANU Correlation Analysis")
        println(io)

        # ── Section 1: Summary ──────────────────────────────────────────
        println(io, "## 1. Summary")
        println(io)
        println(io, "- **OA files parsed from**: $oa_dir")
        println(io, "- **Total unique NANUs**: $(nrow(nanu_df))")

        n_enter = count(r -> r.event_type == "enter", eachrow(events))
        n_exit  = count(r -> r.event_type == "exit", eachrow(events))
        println(io, "- **Sentinel transition events**: $(nrow(events)) ($n_enter enter, $n_exit exit)")
        println(io, "- **Sentinel × PRN windows**: $(nrow(windows))")

        lifecycle_corrs = filter(r -> r.nanu_type in LIFECYCLE_NANU_TYPES, corr_df)
        println(io, "- **Correlated (sentinel, NANU) pairs**: $(nrow(corr_df)) total, $(nrow(lifecycle_corrs)) lifecycle")
        println(io, "- **Lifecycle match rate**: $(fmt_pct(observed_rate))")
        println(io, "- **Expected rate under null**: $(fmt_pct(mean(null_rates)))")
        println(io, "- **p-value (one-sided)**: $(@sprintf("%.4f", p_value))")

        sig = p_value < 0.05 ? "**statistically significant** (p < 0.05)" :
              "**not statistically significant** (p ≥ 0.05)"
        println(io, "- **Assessment**: Lifecycle correlation is $sig")
        println(io, "- **Correlation window**: ±$(SENTINEL_WINDOW_DAYS) days")
        println(io)

        # ── Section 2: Sentinel Observation Windows ─────────────────────
        println(io, "## 2. Sentinel Observation Windows")
        println(io)
        println(io, "| PRN | Sentinel Type | First Seen | Last Seen | Duration (days) | Observations |")
        println(io, "|---|---|---|---|---|---|")
        for row in eachrow(windows)
            println(io, "| $(row.prn) | $(sentinel_display_name(row.sentinel_type)) | $(fmt_date(row.first_seen)) | $(fmt_date(row.last_seen)) | $(@sprintf("%.1f", row.duration_days)) | $(row.obs_count) |")
        end
        println(io)

        # Summary by sentinel type
        println(io, "### By Sentinel Type")
        println(io)
        println(io, "| Sentinel | PRN Count | Total Observations | Earliest | Latest |")
        println(io, "|---|---|---|---|---|")
        for stype in sort(unique(windows.sentinel_type))
            sub = filter(r -> r.sentinel_type == stype, windows)
            println(io, "| $(sentinel_display_name(stype)) | $(nrow(sub)) | $(sum(sub.obs_count)) | $(fmt_date(minimum(sub.first_seen))) | $(fmt_date(maximum(sub.last_seen))) |")
        end
        println(io)

        # ── Section 3: Fleet Flash (2011-05-26) ────────────────────────
        println(io, "## 3. Fleet-Wide Sentinel Flashes")
        println(io)

        if isempty(flashes)
            println(io, "*No fleet-wide sentinel flashes detected (threshold: ≥$(FLEET_FLASH_THRESHOLD) PRNs on same day).*")
        else
            for flash_row in eachrow(flashes)
                println(io, "### $(flash_row.event_date) — $(sentinel_display_name(flash_row.sentinel_type))")
                println(io)
                println(io, "**$(flash_row.prn_count) PRNs** entered $(sentinel_display_name(flash_row.sentinel_type)) on this day.")
                println(io)
                println(io, "PRNs: $(join(flash_row.prns, ", "))")
                println(io)

                # Duration for each PRN in this flash
                flash_events_enter = filter(r ->
                    r.event_type == "enter" &&
                    r.sentinel_type == flash_row.sentinel_type &&
                    Date(r.event_date) == flash_row.event_date,
                    events)

                flash_events_exit = filter(r ->
                    r.event_type == "exit" &&
                    r.sentinel_type == flash_row.sentinel_type,
                    events)

                println(io, "| PRN | Enter Time | Exit Time | Duration |")
                println(io, "|---|---|---|---|")
                for prn in flash_row.prns
                    enter_row = filter(r -> r.prn == prn, flash_events_enter)
                    exit_row = filter(r -> r.prn == prn && r.event_date > flash_events_enter[1, :event_date], flash_events_exit)
                    enter_str = isempty(enter_row) ? "—" : Dates.format(enter_row[1, :event_date], "yyyy-mm-dd HH:MM")
                    if !isempty(exit_row)
                        exit_dt = exit_row[1, :event_date]
                        exit_str = Dates.format(exit_dt, "yyyy-mm-dd HH:MM")
                        dur_hours = Dates.value(exit_dt - enter_row[1, :event_date]) / (3600 * 1000)
                        dur_str = dur_hours < 24 ? @sprintf("%.1f hours", dur_hours) : @sprintf("%.1f days", dur_hours / 24)
                    else
                        exit_str = "—"
                        dur_str = "ongoing / no exit detected"
                    end
                    println(io, "| $prn | $enter_str | $exit_str | $dur_str |")
                end
                println(io)

                # Nearby NANUs for the flash
                flash_date_dt = DateTime(flash_row.event_date)
                nearby = filter(r -> abs(Dates.value(r.msg_datetime - flash_date_dt) / (24 * 3600 * 1000)) <= SENTINEL_WINDOW_DAYS, nanu_df)
                if !isempty(nearby)
                    println(io, "**Nearby NANUs (±$(SENTINEL_WINDOW_DAYS) days):**")
                    println(io)
                    println(io, "| NANU ID | Type | PRN | Date | Offset (days) |")
                    println(io, "|---|---|---|---|---|")
                    for nanu_row in eachrow(nearby)
                        offset = Dates.value(flash_date_dt - nanu_row.msg_datetime) / (24 * 3600 * 1000)
                        prn_str = ismissing(nanu_row.prn) ? "—" : string(nanu_row.prn)
                        println(io, "| $(nanu_row.nanu_id) | $(nanu_row.nanu_type) | $prn_str | $(fmt_date(nanu_row.msg_datetime)) | $(@sprintf("%.1f", offset)) |")
                    end
                else
                    println(io, "*No NANUs found within ±$(SENTINEL_WINDOW_DAYS) days of this fleet flash.*")
                end
                println(io)
            end
        end

        # ── Section 4: Lifecycle Correlations ──────────────────────────
        println(io, "## 4. Lifecycle Correlations")
        println(io)
        println(io, "Sentinel events matched to lifecycle NANUs (DECOM, LAUNCH, USABINIT, UNUSUFN, UNUSABLE):")
        println(io)

        lifecycle_corrs = filter(r -> r.nanu_type in LIFECYCLE_NANU_TYPES, corr_df)

        if isempty(lifecycle_corrs)
            println(io, "*No lifecycle correlations found.*")
        else
            sort!(lifecycle_corrs, [:event_date, :prn])
            println(io, "| PRN | Sentinel | Event | Date | NANU ID | NANU Type | NANU PRN | Offset (days) |")
            println(io, "|---|---|---|---|---|---|---|---|")
            for row in eachrow(lifecycle_corrs)
                nanu_prn_str = ismissing(row.nanu_prn) ? "—" : string(row.nanu_prn)
                println(io, "| $(row.prn) | $(sentinel_display_name(row.sentinel_type)) | $(row.event_type) | $(fmt_date(row.event_date)) | $(row.nanu_id) | $(row.nanu_type) | $nanu_prn_str | $(@sprintf("%.1f", row.time_offset_days)) |")
            end
        end
        println(io)

        # ── Section 5: Unexplained Events ──────────────────────────────
        println(io, "## 5. Unexplained Sentinel Events")
        println(io)
        println(io, "Sentinel transitions with no matching NANU within ±$(SENTINEL_WINDOW_DAYS) days:")
        println(io)

        if isempty(unexplained)
            println(io, "*All sentinel events have at least one matching NANU.*")
        else
            println(io, "**Total unexplained**: $(nrow(unexplained)) of $(nrow(events)) sentinel events")
            println(io)

            # Show enter events grouped by date to highlight coordinated unexplained
            unexplained_enter = filter(r -> r.event_type == "enter", unexplained)
            unexplained_exit  = filter(r -> r.event_type == "exit", unexplained)

            if !isempty(unexplained_enter)
                println(io, "### Unexplained Enter Events")
                println(io)
                println(io, "| PRN | Sentinel | Date |")
                println(io, "|---|---|---|")
                sort!(unexplained_enter, [:event_date, :prn])
                for row in eachrow(unexplained_enter)
                    println(io, "| $(row.prn) | $(sentinel_display_name(row.sentinel_type)) | $(fmt_date(row.event_date)) |")
                end
                println(io)
            end

            if !isempty(unexplained_exit)
                println(io, "### Unexplained Exit Events")
                println(io)
                println(io, "| PRN | Sentinel | Date |")
                println(io, "|---|---|---|")
                sort!(unexplained_exit, [:event_date, :prn])
                for row in eachrow(unexplained_exit)
                    println(io, "| $(row.prn) | $(sentinel_display_name(row.sentinel_type)) | $(fmt_date(row.event_date)) |")
                end
                println(io)
            end
        end

        # ── Section 6: All Correlations ────────────────────────────────
        println(io, "## 6. All Correlations")
        println(io)

        if isempty(corr_df)
            println(io, "*No correlations to display.*")
        else
            sorted_corr = sort(corr_df, [:event_date, :prn])
            top_n = min(100, nrow(sorted_corr))

            if nrow(sorted_corr) > top_n
                println(io, "First $top_n of $(nrow(sorted_corr)) correlated pairs (chronological):")
            else
                println(io, "All $(nrow(sorted_corr)) correlated pairs (chronological):")
            end
            println(io)
            println(io, "| PRN | Sentinel | Event | Date | NANU ID | NANU Type | NANU PRN | Offset (days) |")
            println(io, "|---|---|---|---|---|---|---|---|")
            for row in eachrow(sorted_corr[1:top_n, :])
                nanu_prn_str = ismissing(row.nanu_prn) ? "—" : string(row.nanu_prn)
                println(io, "| $(row.prn) | $(sentinel_display_name(row.sentinel_type)) | $(row.event_type) | $(fmt_date(row.event_date)) | $(row.nanu_id) | $(row.nanu_type) | $nanu_prn_str | $(@sprintf("%.1f", row.time_offset_days)) |")
            end
            if nrow(sorted_corr) > top_n
                println(io, "| *…$(nrow(sorted_corr) - top_n) more rows not shown* | | | | | | | |")
            end
        end
        println(io)

        # ── Parameters ────────────────────────────────────────────────
        println(io, "---")
        println(io)
        println(io, "**Correlation window**: ±$(SENTINEL_WINDOW_DAYS) days.")
        println(io, "**Lifecycle NANU types**: $(join(sort(collect(LIFECYCLE_NANU_TYPES)), ", ")).")
        println(io, "**Fleet flash threshold**: ≥$(FLEET_FLASH_THRESHOLD) PRNs entering sentinel on same day.")
        println(io, "**Permutation test**: $N_PERMUTATIONS trials with shuffled NANU dates.")
    end
end

main()
