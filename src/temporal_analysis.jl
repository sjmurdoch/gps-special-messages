# Temporal pattern analysis for GPS special messages

using DuckDB
using Dates
using DataFrames

"""
    MessageTransition

Represents a transition from one special message to another.
"""
struct MessageTransition
    from_hash::String
    to_hash::String
    from_message::String
    to_message::String
    transition_time::DateTime
    prn::Int
    duration_hours::Float64
end

"""
    MessageDuration

Represents the duration a specific message was active.
"""
struct MessageDuration
    message_hash::String
    ascii_message::String
    first_seen::DateTime
    last_seen::DateTime
    duration_days::Float64
    prn::Int
    num_observations::Int
end

"""
    DayOfWeekPattern

Statistics for messages appearing on specific days of the week.
"""
struct DayOfWeekPattern
    day_of_week::Int  # 1=Monday, 7=Sunday
    message_count::Int
    unique_messages::Int
    most_common_hash::String
end

"""
    get_message_transitions(db::DuckDB.DB; prn::Union{Int,Nothing}=nothing,
                           start_date::Union{DateTime,Nothing}=nothing,
                           end_date::Union{DateTime,Nothing}=nothing) -> Vector{MessageTransition}

Extract all message transitions from the database.
Optionally filter by PRN and date range.

A transition occurs when a satellite switches from broadcasting one message to another.
The duration_hours field indicates how long the previous message was active.

# Example
```julia
db = DuckDB.DB("messages.db")
transitions = get_message_transitions(db; prn=5, start_date=DateTime(2022, 5, 1))
for t in transitions
    println("PRN \$(t.prn): '\$(t.from_message)' -> '\$(t.to_message)' at \$(t.transition_time)")
end
```
"""
function get_message_transitions(db::DuckDB.DB;
                                prn::Union{Int,Nothing}=nothing,
                                start_date::Union{DateTime,Nothing}=nothing,
                                end_date::Union{DateTime,Nothing}=nothing)::Vector{MessageTransition}

    # Build WHERE clause based on filters
    where_clauses = String[]
    params = Any[]

    if !isnothing(prn)
        push!(where_clauses, "prn = ?")
        push!(params, prn)
    end

    if !isnothing(start_date)
        push!(where_clauses, "transition_time >= ?")
        push!(params, start_date)
    end

    if !isnothing(end_date)
        push!(where_clauses, "transition_time <= ?")
        push!(params, end_date)
    end

    # Build complete WHERE clause
    if !isempty(where_clauses)
        push!(where_clauses, "to_hash IS NOT NULL")
        where_sql = "WHERE " * join(where_clauses, " AND ")
    else
        where_sql = "WHERE to_hash IS NOT NULL"
    end

    # Query using the message_transitions view
    query = """
    SELECT
        prn,
        from_hash,
        from_message,
        to_hash,
        to_message,
        transition_time,
        duration_hours
    FROM message_transitions
    $where_sql
    ORDER BY transition_time
    """

    result = if isempty(params)
        DBInterface.execute(db, query)
    else
        stmt = DBInterface.prepare(db, query)
        DBInterface.execute(stmt, params)
    end

    transitions = MessageTransition[]
    for row in result
        push!(transitions, MessageTransition(
            row.from_hash,
            row.to_hash,
            row.from_message,
            row.to_message,
            row.transition_time,
            row.prn,
            row.duration_hours
        ))
    end

    return transitions
end

"""
    compute_message_durations(db::DuckDB.DB;
                             min_duration_hours::Float64=0.0) -> Vector{MessageDuration}

Compute the duration each unique message was active.
Returns sorted by duration (longest first).

# Example
```julia
db = DuckDB.DB("messages.db")
durations = compute_message_durations(db; min_duration_hours=24.0)
for d in durations[1:10]  # Top 10 longest
    println("\$(d.ascii_message): \$(d.duration_days) days (PRN \$(d.prn))")
end
```
"""
function compute_message_durations(db::DuckDB.DB;
                                  min_duration_hours::Float64=0.0)::Vector{MessageDuration}

    query = """
    SELECT
        message_hash,
        ascii_message,
        first_seen,
        last_seen,
        duration_hours,
        prn,
        num_observations
    FROM message_durations
    WHERE duration_hours >= ?
    ORDER BY duration_hours DESC
    """

    stmt = DBInterface.prepare(db, query)
    result = DBInterface.execute(stmt, [min_duration_hours])

    durations = MessageDuration[]
    for row in result
        push!(durations, MessageDuration(
            row.message_hash,
            row.ascii_message,
            row.first_seen,
            row.last_seen,
            row.duration_hours / 24.0,  # Convert to days
            row.prn,
            row.num_observations
        ))
    end

    return durations
end

"""
    analyze_day_of_week_patterns(db::DuckDB.DB;
                                 year::Union{Int,Nothing}=nothing) -> Vector{DayOfWeekPattern}

Analyze patterns in which messages appear on different days of the week.
Returns statistics for each day of the week (1=Monday, 7=Sunday).

# Example
```julia
db = DuckDB.DB("messages.db")
patterns = analyze_day_of_week_patterns(db; year=2022)
for p in patterns
    day_name = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"][p.day_of_week]
    println("\$day_name: \$(p.message_count) messages, \$(p.unique_messages) unique")
end
```
"""
function analyze_day_of_week_patterns(db::DuckDB.DB;
                                     year::Union{Int,Nothing}=nothing)::Vector{DayOfWeekPattern}

    where_sql = isnothing(year) ? "" : "WHERE year = ?"
    params = isnothing(year) ? Any[] : Any[year]

    query = """
    SELECT
        DAYOFWEEK(datetime) as day_of_week,
        COUNT(*) as message_count,
        COUNT(DISTINCT message_hash) as unique_messages,
        MODE(message_hash) as most_common_hash
    FROM special_messages
    $where_sql
    GROUP BY DAYOFWEEK(datetime)
    ORDER BY day_of_week
    """

    result = if isempty(params)
        DBInterface.execute(db, query)
    else
        stmt = DBInterface.prepare(db, query)
        DBInterface.execute(stmt, params)
    end

    patterns = DayOfWeekPattern[]
    for row in result
        push!(patterns, DayOfWeekPattern(
            row.day_of_week,
            row.message_count,
            row.unique_messages,
            row.most_common_hash
        ))
    end

    return patterns
end

"""
    detect_change_points(db::DuckDB.DB; prn::Int) -> Vector{DateTime}

Detect significant change points in message rotation patterns for a satellite.
Uses statistical methods to identify when rotation behavior changes.

This function identifies dates where the distribution of message durations changes significantly.
For example, it should detect the May 29, 2022 regime change from 1-day to mixed 1/7-day durations.

# Example
```julia
db = DuckDB.DB("messages.db")
for prn in 1:32
    changepoints = detect_change_points(db; prn=prn)
    if !isempty(changepoints)
        println("PRN \$prn change points: \$changepoints")
    end
end
```
"""
function detect_change_points(db::DuckDB.DB; prn::Int)::Vector{DateTime}
    # Get duration distribution over time
    query = """
    SELECT
        DATE_TRUNC('week', transition_time) as week,
        AVG(duration_hours) as avg_duration,
        STDDEV(duration_hours) as std_duration,
        COUNT(*) as num_transitions
    FROM message_transitions
    WHERE prn = ? AND to_hash IS NOT NULL
    GROUP BY DATE_TRUNC('week', transition_time)
    ORDER BY week
    """

    stmt = DBInterface.prepare(db, query)
    result = DBInterface.execute(stmt, [prn])

    weeks = DateTime[]
    avg_durations = Float64[]

    for row in result
        if !ismissing(row.avg_duration) && row.num_transitions >= 2
            push!(weeks, row.week)
            push!(avg_durations, row.avg_duration)
        end
    end

    if length(avg_durations) < 10
        return DateTime[]  # Not enough data
    end

    # Detect change points using simple threshold on moving average difference
    changepoints = DateTime[]
    window_size = 4  # 4 weeks

    for i in (window_size + 1):(length(avg_durations) - window_size)
        before_avg = sum(avg_durations[(i-window_size):(i-1)]) / window_size
        after_avg = sum(avg_durations[i:(i+window_size-1)]) / window_size

        # Detect significant change (>50% difference)
        if abs(after_avg - before_avg) / before_avg > 0.5
            push!(changepoints, weeks[i])
        end
    end

    # Remove duplicates within 8 weeks of each other
    unique_changepoints = DateTime[]
    for cp in changepoints
        if isempty(unique_changepoints) ||
           Dates.value(cp - unique_changepoints[end]) / (7 * 24 * 3600 * 1000) > 8
            push!(unique_changepoints, cp)
        end
    end

    return unique_changepoints
end

"""
    get_messages_by_date_range(db::DuckDB.DB, start_date::DateTime,
                               end_date::DateTime; prn::Union{Int,Nothing}=nothing) -> DataFrame

Query messages within a specific date range.
Returns a DataFrame with all message fields.

# Example
```julia
db = DuckDB.DB("messages.db")
df = get_messages_by_date_range(db, DateTime(2022, 5, 1), DateTime(2022, 6, 1); prn=5)
println("Found \$(nrow(df)) messages")
```
"""
function get_messages_by_date_range(db::DuckDB.DB, start_date::DateTime,
                                   end_date::DateTime;
                                   prn::Union{Int,Nothing}=nothing)::DataFrame

    where_clauses = ["datetime >= ?", "datetime <= ?"]
    params = Any[start_date, end_date]

    if !isnothing(prn)
        push!(where_clauses, "prn = ?")
        push!(params, prn)
    end

    where_sql = join(where_clauses, " AND ")

    query = """
    SELECT *
    FROM special_messages
    WHERE $where_sql
    ORDER BY datetime
    """

    stmt = DBInterface.prepare(db, query)
    result = DBInterface.execute(stmt, params)

    return DataFrame(result)
end

"""
    TimeOfDayPattern

Statistics about when message transitions occur during the day.
"""
struct TimeOfDayPattern
    hour::Int  # 0-23
    transition_count::Int
    avg_duration_hours::Float64
    unique_messages::Int
end

"""
    PeriodicityResult

Result of periodicity analysis showing detected patterns.
"""
struct PeriodicityResult
    prn::Int
    dominant_period_hours::Float64
    period_strength::Float64  # 0-1, higher = stronger periodicity
    secondary_period_hours::Union{Float64, Nothing}
    secondary_strength::Union{Float64, Nothing}
    pattern_type::Symbol  # :orbital (≈12h), :solar (≈24h), :weekly (≈168h), :irregular
end

"""
    TransitionCorrelation

Measures how synchronized message transitions are between two satellites.
"""
struct TransitionCorrelation
    prn1::Int
    prn2::Int
    correlation::Float64  # -1 to 1
    avg_lag_hours::Float64  # Average time difference
    synchronized_count::Int  # Transitions within 1 hour of each other
end

"""
    analyze_time_of_day_patterns(db::DuckDB.DB;
                                 prn::Union{Int,Nothing}=nothing,
                                 year::Union{Int,Nothing}=nothing) -> Vector{TimeOfDayPattern}

Analyze when message transitions occur during the day (hour of day distribution).

This reveals operational patterns:
- 12-hour patterns suggest orbital-position-based targeting
- 24-hour patterns suggest operational scheduling
- Uniform distribution suggests random/no targeting

# Arguments
- `db`: Database connection
- `prn`: Optional PRN filter
- `year`: Optional year filter

# Example
```julia
db = DuckDB.DB("messages.duckdb")
patterns = analyze_time_of_day_patterns(db; prn=5)
for p in patterns
    bar = repeat("█", div(p.transition_count, 10))
    println("Hour \$(lpad(p.hour, 2)): \$bar (\$(p.transition_count))")
end
```
"""
function analyze_time_of_day_patterns(db::DuckDB.DB;
                                      prn::Union{Int,Nothing}=nothing,
                                      year::Union{Int,Nothing}=nothing)::Vector{TimeOfDayPattern}
    where_clauses = ["to_hash IS NOT NULL"]
    params = Any[]

    if !isnothing(prn)
        push!(where_clauses, "prn = ?")
        push!(params, prn)
    end

    if !isnothing(year)
        push!(where_clauses, "EXTRACT(YEAR FROM transition_time) = ?")
        push!(params, year)
    end

    where_sql = "WHERE " * join(where_clauses, " AND ")

    query = """
    SELECT
        EXTRACT(HOUR FROM transition_time)::INTEGER as hour,
        COUNT(*) as transition_count,
        AVG(duration_hours) as avg_duration_hours,
        COUNT(DISTINCT from_hash) as unique_messages
    FROM message_transitions
    $where_sql
    GROUP BY EXTRACT(HOUR FROM transition_time)::INTEGER
    ORDER BY hour
    """

    result = if isempty(params)
        DBInterface.execute(db, query)
    else
        stmt = DBInterface.prepare(db, query)
        DBInterface.execute(stmt, params)
    end

    patterns = TimeOfDayPattern[]
    for row in result
        push!(patterns, TimeOfDayPattern(
            row.hour,
            row.transition_count,
            ismissing(row.avg_duration_hours) ? 0.0 : row.avg_duration_hours,
            row.unique_messages
        ))
    end

    return patterns
end

"""
    detect_periodic_patterns(db::DuckDB.DB; prn::Int) -> PeriodicityResult

Detect periodic patterns in message rotation for a specific satellite.

Analyzes the distribution of message durations to identify:
- :orbital patterns (≈12 hours) - suggests geographic targeting
- :solar patterns (≈24 hours) - suggests operational scheduling
- :weekly patterns (≈168 hours) - suggests weekly maintenance cycles
- :irregular - no clear pattern

Uses autocorrelation analysis on the message transition time series.

# Example
```julia
db = DuckDB.DB("messages.duckdb")
result = detect_periodic_patterns(db; prn=5)
println("PRN 5 pattern: \$(result.pattern_type)")
println("Dominant period: \$(result.dominant_period_hours) hours")
println("Strength: \$(result.period_strength)")
```
"""
function detect_periodic_patterns(db::DuckDB.DB; prn::Int)::PeriodicityResult
    # Get all message durations for this PRN
    query = """
    SELECT
        duration_hours,
        transition_time
    FROM message_transitions
    WHERE prn = ? AND to_hash IS NOT NULL AND duration_hours IS NOT NULL
    ORDER BY transition_time
    """

    stmt = DBInterface.prepare(db, query)
    result = DBInterface.execute(stmt, [prn])

    durations = Float64[]
    for row in result
        if !ismissing(row.duration_hours)
            push!(durations, row.duration_hours)
        end
    end

    if length(durations) < 20
        return PeriodicityResult(prn, 0.0, 0.0, nothing, nothing, :irregular)
    end

    # Analyze duration distribution to detect common periods
    # Round durations to nearest hour for binning
    rounded = round.(durations)

    # Count occurrences of each duration
    duration_counts = Dict{Float64, Int}()
    for d in rounded
        duration_counts[d] = get(duration_counts, d, 0) + 1
    end

    # Find most common durations
    sorted_durations = sort(collect(duration_counts), by=x->x[2], rev=true)

    if isempty(sorted_durations)
        return PeriodicityResult(prn, 0.0, 0.0, nothing, nothing, :irregular)
    end

    dominant_duration = sorted_durations[1][1]
    dominant_count = sorted_durations[1][2]
    dominant_strength = dominant_count / length(durations)

    secondary_duration = length(sorted_durations) > 1 ? sorted_durations[2][1] : nothing
    secondary_strength = length(sorted_durations) > 1 ? sorted_durations[2][2] / length(durations) : nothing

    # Classify the pattern type
    pattern_type = :irregular
    if dominant_strength > 0.3
        if 10 <= dominant_duration <= 14
            pattern_type = :orbital
        elseif 22 <= dominant_duration <= 26
            pattern_type = :solar
        elseif 160 <= dominant_duration <= 176
            pattern_type = :weekly
        end
    end

    return PeriodicityResult(
        prn,
        dominant_duration,
        dominant_strength,
        secondary_duration,
        secondary_strength,
        pattern_type
    )
end

"""
    correlate_transitions_across_prns(db::DuckDB.DB;
                                      tolerance_hours::Float64=1.0) -> Vector{TransitionCorrelation}

Analyze how synchronized message transitions are between different satellites.

If satellites change messages at similar times, it suggests:
- Coordinated uploads by ground control
- Possible geographic targeting (satellites over same region change together)

Returns correlation scores for all PRN pairs with sufficient data.

# Arguments
- `db`: Database connection
- `tolerance_hours`: Time window to consider transitions "synchronized" (default: 1 hour)

# Example
```julia
db = DuckDB.DB("messages.duckdb")
correlations = correlate_transitions_across_prns(db)
# Find most synchronized pairs
sync_pairs = filter(c -> c.correlation > 0.5, correlations)
for c in sync_pairs
    println("PRN \$(c.prn1) <-> PRN \$(c.prn2): correlation=\$(round(c.correlation, digits=2))")
end
```
"""
function correlate_transitions_across_prns(db::DuckDB.DB;
                                           tolerance_hours::Float64=1.0)::Vector{TransitionCorrelation}
    # Get transition times for each PRN, binned by day
    query = """
    WITH daily_transitions AS (
        SELECT
            prn,
            DATE_TRUNC('day', transition_time) as day,
            COUNT(*) as num_transitions
        FROM message_transitions
        WHERE to_hash IS NOT NULL
        GROUP BY prn, DATE_TRUNC('day', transition_time)
    )
    SELECT
        a.prn as prn1,
        b.prn as prn2,
        COUNT(*) as shared_days,
        AVG(a.num_transitions) as avg_trans_a,
        AVG(b.num_transitions) as avg_trans_b,
        CORR(a.num_transitions, b.num_transitions) as correlation
    FROM daily_transitions a
    JOIN daily_transitions b ON a.day = b.day AND a.prn < b.prn
    GROUP BY a.prn, b.prn
    HAVING COUNT(*) >= 30  -- Require at least 30 shared days
    ORDER BY correlation DESC NULLS LAST
    """

    result = DBInterface.execute(db, query)

    correlations = TransitionCorrelation[]
    for row in result
        corr_val = ismissing(row.correlation) ? 0.0 : row.correlation
        push!(correlations, TransitionCorrelation(
            row.prn1,
            row.prn2,
            corr_val,
            0.0,  # avg_lag not computed in this simplified version
            row.shared_days
        ))
    end

    return correlations
end

"""
    analyze_orbital_correlation(db::DuckDB.DB;
                                year::Union{Int,Nothing}=nothing) -> DataFrame

Analyze if message changes correlate with satellite orbital position.

GPS satellites complete 2 orbits per day (~11h 58m period). If messages change
at consistent orbital phases, it suggests geographic targeting.

Returns statistics on message transition timing relative to the 12-hour orbital period.

# Example
```julia
db = DuckDB.DB("messages.duckdb")
orbital = analyze_orbital_correlation(db; year=2023)
```
"""
function analyze_orbital_correlation(db::DuckDB.DB;
                                    year::Union{Int,Nothing}=nothing)::DataFrame
    where_sql = isnothing(year) ? "" : "AND EXTRACT(YEAR FROM transition_time) = ?"
    params = isnothing(year) ? Any[] : Any[year]

    # Analyze transitions binned by time-of-day in 30-minute intervals
    # and look for 12-hour periodicity
    query = """
    SELECT
        prn,
        (EXTRACT(HOUR FROM transition_time) * 2 +
         FLOOR(EXTRACT(MINUTE FROM transition_time) / 30))::INTEGER as half_hour_bin,
        COUNT(*) as transition_count
    FROM message_transitions
    WHERE to_hash IS NOT NULL $where_sql
    GROUP BY prn, half_hour_bin
    ORDER BY prn, half_hour_bin
    """

    result = if isempty(params)
        DBInterface.execute(db, query)
    else
        stmt = DBInterface.prepare(db, query)
        DBInterface.execute(stmt, params)
    end

    return DataFrame(result)
end

"""
    BehavioralMetric

A single row of behavioral metrics for one (period_start, granularity, prn) combination.
"""
struct BehavioralMetric
    period_start::DateTime
    granularity::String            # "daily" or "weekly"
    prn::Int                       # 0 = fleet-wide aggregate
    observation_count::Union{Int,Missing}
    transition_count::Union{Int,Missing}
    unique_message_count::Union{Int,Missing}
    mean_entropy::Union{Float64,Missing}
    sentinel_fraction::Union{Float64,Missing}
    text_fraction::Union{Float64,Missing}
    active_prn_count::Union{Int,Missing}
    mean_duration_hours::Union{Float64,Missing}   # avg hours per message before next transition (weekly only)
end

"""
    BehavioralChangePoint

A detected CUSUM change point with supporting metadata.
"""
struct BehavioralChangePoint
    detected_at::DateTime
    granularity::String
    prn::Int
    metric::String
    direction::String             # "increase" or "decrease"
    cusum_statistic::Float64
    is_coordinated::Bool
    coordinated_prn_count::Int
end

# ── Known sentinel message hashes (all-spaces, all-NUL, all-¬) ──────────────

"""Return true if the ascii_message is a known sentinel value."""
function _is_sentinel(msg::AbstractString)::Bool
    # Undo sanitize_ascii_message: '\ufffd' is used for NUL (0x00)
    stripped = replace(msg, '\ufffd' => '\0')
    
    if all(c -> c == ' ',    stripped) return true end
    if all(c -> c == '\0',   stripped) return true end
    
    # Check if all chars in stripped match the sentinel char '¬' (U+00AC)
    if all(c -> c == '\u00ac', stripped) return true end
    
    # After sanitization NUL appears as replacement character
    if all(c -> c == '\ufffd', msg) return true end
    
    return false
end

"""Return true if the ascii_message is TEXT-prefixed."""
function _is_text_prefixed(msg::AbstractString)::Bool
    return startswith(msg, "TEXT")
end

# ── CUSUM change-point detection ─────────────────────────────────────────────

"""
    cusum_detect(series::AbstractVector, valid_mask::AbstractVector{Bool};
                 slack::Float64=0.5, threshold::Float64=5.0,
                 reference_fraction::Float64=0.2) -> Vector{Int}

Two-sided CUSUM (Cumulative Sum Control Chart) change-point detector with
onset estimation.

Applied to a time series of Float64 values (may include `missing`).  The
function estimates the in-control mean μ and standard deviation σ from the
first `reference_fraction` of *valid* observations, then scans the rest for
points where the cumulative sum exceeds `threshold`.

Formally:
    S_high[0] = 0,  S_low[0] = 0
    S_high[t] = max(0, S_high[t-1] + (x[t] - μ)/σ - slack)
    S_low[t]  = max(0, S_low[t-1]  - (x[t] - μ)/σ - slack)
    Change point if S_high[t] > threshold or S_low[t] > threshold

**Onset estimation**: When a threshold crossing is detected at index k, the
function backtracks to find the index where the accumulating statistic first
rose above zero in the current run.  This reported onset index is where the
change actually began, rather than where enough evidence accumulated.

After a change point is detected the statistics are reset to allow multiple
detections.  Returns the 1-based indices into `series` at the estimated onset.
Returns an empty vector if fewer than 8 valid observations exist.

# Arguments
- `series`: Time-ordered values (may be a `Vector{Union{Float64,Missing}}`)
- `valid_mask`: Boolean mask indicating which elements to use
- `slack`: Allowance parameter k (default 0.5, half a standard deviation)
- `threshold`: Detection threshold h (default 5.0, standard industrial value)
- `reference_fraction`: Fraction of valid observations used as reference period
"""
function cusum_detect(series::AbstractVector,
                      valid_mask::AbstractVector{Bool};
                      slack::Float64=0.5,
                      threshold::Float64=5.0,
                      reference_fraction::Float64=0.2,
                      min_reference::Int=8)::Vector{Int}

    n = length(series)
    @assert length(valid_mask) == n "series and valid_mask must have the same length"

    # Collect valid values and their indices
    valid_indices = Int[]
    valid_values  = Float64[]
    for i in 1:n
        if valid_mask[i] && !ismissing(series[i])
            push!(valid_indices, i)
            push!(valid_values, Float64(series[i]))
        end
    end

    m = length(valid_values)
    m < min_reference && return Int[]    # Not enough data

    # Estimate μ and σ from the reference (burn-in) period
    ref_end = max(1, round(Int, m * reference_fraction))
    μ, σ = _estimate_reference(valid_values, 1, ref_end)

    # Run two-sided CUSUM with onset tracking and adaptive reference.
    # After each detection, re-estimate μ and σ from data following the
    # change point so that a sustained regime shift triggers only once.
    change_points = Int[]
    s_high = 0.0
    s_low  = 0.0
    onset_high = 1   # valid-space index where S_high last became > 0
    onset_low  = 1   # valid-space index where S_low  last became > 0

    for k in 1:m
        z = (valid_values[k] - μ) / σ

        prev_high = s_high
        prev_low  = s_low
        s_high = max(0.0, s_high + z - slack)
        s_low  = max(0.0, s_low  - z - slack)

        # Track where each accumulation run begins
        if prev_high == 0.0 && s_high > 0.0
            onset_high = k
        end
        if prev_low == 0.0 && s_low > 0.0
            onset_low = k
        end

        if s_high > threshold || s_low > threshold
            # Report the onset index, not the detection index
            onset_k = s_high > threshold ? onset_high : onset_low
            push!(change_points, valid_indices[onset_k])

            # Re-estimate reference from data after the onset point.
            # This makes the new regime the baseline, so CUSUM won't
            # keep firing for the same sustained shift.
            new_ref_len = max(min_reference, round(Int, (m - onset_k) * reference_fraction))
            new_ref_end = min(m, onset_k + new_ref_len)
            if new_ref_end - onset_k >= min_reference
                μ, σ = _estimate_reference(valid_values, onset_k + 1, new_ref_end)
            end

            # Reset CUSUM state
            s_high = 0.0
            s_low  = 0.0
            onset_high = k + 1
            onset_low  = k + 1
        end
    end

    return change_points
end

"""
    _estimate_reference(values, from, to) -> (μ, σ)

Compute mean and standard deviation from `values[from:to]`.
Returns σ = 1.0 as fallback when fewer than 2 values or zero variance.
"""
function _estimate_reference(values::Vector{Float64}, from::Int, to::Int)
    n = to - from + 1
    n < 1 && return (0.0, 1.0)
    μ = sum(values[from:to]) / n
    σ = if n >= 2
        sqrt(sum((values[i] - μ)^2 for i in from:to) / (n - 1))
    else
        0.0
    end
    σ <= 0.0 && (σ = 1.0)
    return (μ, σ)
end

# ── Behavioral metric computation ────────────────────────────────────────────

"""
    compute_behavioral_metrics(db::DuckDB.DB;
                               granularities::Vector{Symbol}=[:daily, :weekly]) -> DataFrame

Compute per-PRN and fleet-wide behavioral metrics at daily and/or weekly
granularity.  Returns a DataFrame whose columns match the `behavioral_metrics`
table schema:

| Column               | Type    | Notes                              |
|----------------------|---------|------------------------------------|
| period_start         | DateTime| Start of the aggregation period    |
| granularity          | String  | "daily" or "weekly"                |
| prn                  | Int     | 1-32 per satellite, 0 = aggregate  |
| observation_count    | Int     | Raw observations                   |
| transition_count     | Int     | Weekly only (# message changes)    |
| unique_message_count | Int     | Weekly only                        |
| mean_entropy         | Float64 | Average Shannon entropy (kept; not used in CUSUM) |
| sentinel_fraction    | Float64 | Fraction that are sentinel values  |
| text_fraction        | Float64 | Fraction that are TEXT-prefixed    |
| active_prn_count     | Int     | Fleet aggregate only               |
| mean_duration_hours  | Float64 | Weekly only: mean hours per message before next transition |

# Arguments
- `db`: Open DuckDB connection (read-only is fine)
- `granularities`: Which time scales to compute (default both)
"""
function compute_behavioral_metrics(db::DuckDB.DB;
                                    granularities::Vector{Symbol}=[:daily, :weekly])::DataFrame

    rows = BehavioralMetric[]

    for gran in granularities
        gran_str = String(gran)
        trunc_expr = gran == :daily ? "day" : "week"

        # ── Per-PRN metrics ─────────────────────────────────────────────
        # Pull all message hashes per period/prn and aggregate sentinel/text
        # fractions in Julia (DuckDB can't call Julia functions).
        raw_result = DBInterface.execute(db, """
            SELECT
                DATE_TRUNC('$trunc_expr', datetime) AS period_start,
                prn,
                message_hash,
                ascii_message,
                entropy,
                COUNT(*) AS obs_count
            FROM special_messages
            GROUP BY DATE_TRUNC('$trunc_expr', datetime), prn, message_hash, ascii_message, entropy
            ORDER BY period_start, prn
        """)

        # Accumulate into a dict keyed by (period_start, prn)
        period_prn_data = Dict{Tuple{DateTime,Int}, NamedTuple}()

        for row in raw_result
            # DuckDB may return Date instead of DateTime; normalise to DateTime
            # so Dict{Tuple{DateTime,Int}} key lookup works correctly.
            key = (DateTime(row.period_start), Int(row.prn))
            msg = string(row.ascii_message)
            obs = Int(row.obs_count)
            ent = ismissing(row.entropy) ? 0.0 : Float64(row.entropy)
            is_sent = _is_sentinel(msg) ? obs : 0
            is_txt  = _is_text_prefixed(msg) ? obs : 0

            if haskey(period_prn_data, key)
                prev = period_prn_data[key]
                period_prn_data[key] = (
                    observation_count    = prev.observation_count + obs,
                    unique_message_count = prev.unique_message_count + 1,
                    entropy_sum          = prev.entropy_sum + ent * obs,
                    sentinel_count       = prev.sentinel_count + is_sent,
                    text_count           = prev.text_count + is_txt,
                )
            else
                period_prn_data[key] = (
                    observation_count    = obs,
                    unique_message_count = 1,
                    entropy_sum          = ent * obs,
                    sentinel_count       = is_sent,
                    text_count           = is_txt,
                )
            end
        end

        # ── Weekly transition counts and mean message duration (per PRN) ─
        transition_counts    = Dict{Tuple{DateTime,Int}, Int}()
        duration_per_prn     = Dict{Tuple{DateTime,Int}, Float64}()
        fleet_mean_dur       = Dict{DateTime, Float64}()
        if gran == :weekly
            trans_result = DBInterface.execute(db, """
                WITH real_changes AS (
                    SELECT prn, transition_time,
                        EXTRACT(EPOCH FROM (
                            LEAD(transition_time) OVER (PARTITION BY prn ORDER BY transition_time)
                            - transition_time
                        )) / 3600.0 AS msg_duration_hours
                    FROM message_transitions
                    WHERE to_hash IS NOT NULL
                      AND from_hash != to_hash
                )
                SELECT
                    DATE_TRUNC('week', transition_time) AS week_start,
                    prn,
                    COUNT(*) AS trans_count,
                    AVG(msg_duration_hours) AS mean_dur_hours
                FROM real_changes
                GROUP BY DATE_TRUNC('week', transition_time), prn
            """)
            for row in trans_result
                key = (DateTime(row.week_start), Int(row.prn))
                transition_counts[key] = Int(row.trans_count)
                if !ismissing(row.mean_dur_hours) && row.mean_dur_hours > 0
                    duration_per_prn[key] = Float64(row.mean_dur_hours)
                end
            end

            # Fleet-level mean duration (all PRNs combined for each week)
            fleet_dur_result = DBInterface.execute(db, """
                WITH real_changes AS (
                    SELECT prn, transition_time,
                        EXTRACT(EPOCH FROM (
                            LEAD(transition_time) OVER (PARTITION BY prn ORDER BY transition_time)
                            - transition_time
                        )) / 3600.0 AS msg_duration_hours
                    FROM message_transitions
                    WHERE to_hash IS NOT NULL
                      AND from_hash != to_hash
                )
                SELECT
                    DATE_TRUNC('week', transition_time) AS week_start,
                    AVG(msg_duration_hours) AS mean_dur_hours
                FROM real_changes
                WHERE msg_duration_hours IS NOT NULL AND msg_duration_hours > 0
                GROUP BY DATE_TRUNC('week', transition_time)
            """)
            for row in fleet_dur_result
                if !ismissing(row.mean_dur_hours)
                    fleet_mean_dur[DateTime(row.week_start)] = Float64(row.mean_dur_hours)
                end
            end
        end

        # Emit per-PRN rows
        for (key, d) in period_prn_data
            (period_start, prn) = key
            tc  = get(transition_counts, key, missing)
            mdh = get(duration_per_prn,  key, missing)
            umc = d.unique_message_count
            obs = d.observation_count
            push!(rows, BehavioralMetric(
                period_start,
                gran_str,
                prn,
                obs,
                gran == :weekly ? tc : missing,
                gran == :weekly ? umc : missing,
                obs > 0 ? d.entropy_sum / obs : missing,
                obs > 0 ? d.sentinel_count / obs : missing,
                obs > 0 ? d.text_count / obs : missing,
                missing,                              # active_prn_count — fleet aggregate only
                gran == :weekly ? mdh : missing,      # mean_duration_hours — weekly only
            ))
        end

        # Zero-fill: emit observation_count=0 rows for weeks a PRN was
        # absent within its active range.  This makes genuine transmission
        # gaps (e.g. PRN 23 summer 2020) visible to the CUSUM on
        # observation_count, while fleet-wide outages will be flagged as
        # coordinated events and can be filtered separately.
        if gran == :weekly
            all_weeks = sort(unique(ps for (ps, _) in keys(period_prn_data)))
            prn_first = Dict{Int, DateTime}()
            prn_last  = Dict{Int, DateTime}()
            for (ps, prn) in keys(period_prn_data)
                prn_first[prn] = min(get(prn_first, prn, ps), ps)
                prn_last[prn]  = max(get(prn_last,  prn, ps), ps)
            end
            for (prn, first_w) in prn_first
                last_w = prn_last[prn]
                for week in all_weeks
                    week < first_w && continue
                    week > last_w  && continue
                    haskey(period_prn_data, (week, prn)) && continue
                    push!(rows, BehavioralMetric(
                        week, gran_str, prn, 0,
                        missing, missing, missing, missing, missing,
                        missing, missing,
                    ))
                end
            end
        end

        # ── Fleet-wide aggregate (PRN = 0) ───────────────────────────────
        fleet_data = Dict{DateTime, NamedTuple}()
        fleet_prns  = Dict{DateTime, Set{Int}}()

        for (key, d) in period_prn_data
            (period_start, prn) = key
            if haskey(fleet_data, period_start)
                prev = fleet_data[period_start]
                fleet_data[period_start] = (
                    observation_count    = prev.observation_count + d.observation_count,
                    unique_message_count = prev.unique_message_count + d.unique_message_count,
                    entropy_sum          = prev.entropy_sum + d.entropy_sum,
                    sentinel_count       = prev.sentinel_count + d.sentinel_count,
                    text_count           = prev.text_count + d.text_count,
                )
                push!(fleet_prns[period_start], prn)
            else
                fleet_data[period_start] = d
                fleet_prns[period_start] = Set{Int}([prn])
            end
        end

        fleet_trans = Dict{DateTime, Int}()
        if gran == :weekly
            for ((ps, _), tc) in transition_counts
                fleet_trans[ps] = get(fleet_trans, ps, 0) + (ismissing(tc) ? 0 : tc)
            end
        end

        for (period_start, d) in fleet_data
            obs      = d.observation_count
            active   = length(fleet_prns[period_start])
            fleet_tc = get(fleet_trans,    period_start, missing)
            fleet_md = get(fleet_mean_dur, period_start, missing)
            push!(rows, BehavioralMetric(
                period_start,
                gran_str,
                0,   # PRN = 0 → fleet-wide
                obs,
                gran == :weekly ? fleet_tc : missing,
                gran == :weekly ? d.unique_message_count : missing,
                obs > 0 ? d.entropy_sum / obs : missing,
                obs > 0 ? d.sentinel_count / obs : missing,
                obs > 0 ? d.text_count / obs : missing,
                active,
                gran == :weekly ? fleet_md : missing,   # mean_duration_hours
            ))
        end
    end

    # Convert to DataFrame
    if isempty(rows)
        return DataFrame(
            period_start         = DateTime[],
            granularity          = String[],
            prn                  = Int[],
            observation_count    = Union{Int,Missing}[],
            transition_count     = Union{Int,Missing}[],
            unique_message_count = Union{Int,Missing}[],
            mean_entropy         = Union{Float64,Missing}[],
            sentinel_fraction    = Union{Float64,Missing}[],
            text_fraction        = Union{Float64,Missing}[],
            active_prn_count     = Union{Int,Missing}[],
            mean_duration_hours  = Union{Float64,Missing}[],
        )
    end

    DataFrame(
        period_start         = [r.period_start         for r in rows],
        granularity          = [r.granularity          for r in rows],
        prn                  = [r.prn                  for r in rows],
        observation_count    = [r.observation_count    for r in rows],
        transition_count     = [r.transition_count     for r in rows],
        unique_message_count = [r.unique_message_count for r in rows],
        mean_entropy         = [r.mean_entropy         for r in rows],
        sentinel_fraction    = [r.sentinel_fraction    for r in rows],
        text_fraction        = [r.text_fraction        for r in rows],
        active_prn_count     = [r.active_prn_count     for r in rows],
        mean_duration_hours  = [r.mean_duration_hours  for r in rows],
    )
end

# ── CUSUM-based behavioral change-point detection ────────────────────────────

# Metrics passed to CUSUM.
#   Excluded: mean_entropy — messages are random by design, entropy is noise.
#   observation_count is included to detect genuine per-PRN transmission gaps
#   (zero-fill rows are added for missing weeks within each PRN's active range,
#   so fleet-wide outages appear as coordinated events and can be filtered).
const _BEHAVIORAL_METRICS = ["sentinel_fraction", "text_fraction",
                              "observation_count",
                              "transition_count", "unique_message_count",
                              "mean_duration_hours"]

"""
    detect_behavioral_change_points(metrics_df::DataFrame;
                                    slack::Float64=0.5,
                                    threshold::Float64=5.0,
                                    coordinated_min_prns::Int=8,
                                    coordinated_window_days::Int=3) -> DataFrame

Apply CUSUM change-point detection to each (prn, granularity, metric) time
series in `metrics_df` (as produced by `compute_behavioral_metrics`).

Also scans for *coordinated* events: dates where ≥ `coordinated_min_prns`
individual satellites signal a change in the same metric within a
±`coordinated_window_days` window.

Returns a DataFrame matching the `behavioral_change_points` table schema.

# Arguments
- `metrics_df`: Output of `compute_behavioral_metrics`
- `slack`: CUSUM slack parameter k (default 0.5)
- `threshold`: CUSUM detection threshold h (default 5.0)
- `coordinated_min_prns`: Minimum PRN count to call an event coordinated
- `coordinated_window_days`: Half-width of window for grouping per-PRN detections
"""
function detect_behavioral_change_points(metrics_df::DataFrame;
                                         slack::Float64=0.5,
                                         threshold::Float64=5.0,
                                         coordinated_min_prns::Int=8,
                                         coordinated_window_days::Int=3)::DataFrame

    all_cps = BehavioralChangePoint[]

    granularities = unique(metrics_df.granularity)
    all_prns      = unique(metrics_df.prn)

    # ── Build fleet mean-per-PRN observation count lookup ─────────────
    # For each (granularity, period_start), compute the fleet mean obs
    # per active PRN.  Used to normalise per-PRN observation_count so
    # that receiver-network growth is factored out and genuine per-PRN
    # transmission gaps produce large z-scores.
    fleet_mean_obs = Dict{Tuple{String,DateTime}, Float64}()
    fleet_sub = filter(r -> r.prn == 0, metrics_df)
    for row in eachrow(fleet_sub)
        obs = row.observation_count
        active = row.active_prn_count
        if !ismissing(obs) && !ismissing(active) && active > 0
            fleet_mean_obs[(row.granularity, row.period_start)] = Float64(obs) / Float64(active)
        end
    end

    # Collect (metric, granularity) → list of (prn, detected_at) for coordination check
    detection_index = Dict{Tuple{String,String}, Vector{Tuple{Int,DateTime}}}()

    for gran in granularities
        for prn in all_prns
            sub = filter(r -> r.granularity == gran && r.prn == prn, metrics_df)
            isempty(sub) && continue
            sort!(sub, :period_start)

            for metric in _BEHAVIORAL_METRICS
                # Skip metrics that aren't meaningful at daily granularity:
                # - transition_count, unique_message_count: only computed weekly
                # - observation_count: daily values oscillate with data-collection
                #   cadence (biweekly pattern), producing false change points
                if gran == "daily" && metric in ("transition_count", "unique_message_count",
                                                  "observation_count")
                    continue
                end

                col = getproperty(sub, Symbol(metric))

                # Normalise observation_count for individual PRNs:
                # divide by fleet mean per PRN to remove network-growth trend.
                # Result is a ratio: ~1 = normal coverage, ~0 = offline.
                if metric == "observation_count" && prn != 0
                    normed = Union{Float64,Missing}[]
                    for (i, v) in enumerate(col)
                        if ismissing(v)
                            push!(normed, missing)
                        else
                            fmo = get(fleet_mean_obs, (gran, sub.period_start[i]), nothing)
                            if fmo !== nothing && fmo > 0
                                push!(normed, Float64(v) / fmo)
                            else
                                push!(normed, missing)
                            end
                        end
                    end
                    series_float = normed
                else
                    series_float = [ismissing(v) ? missing : Float64(v) for v in col]
                end

                valid_mask = [!ismissing(v) && !isnan(Float64(v)) for v in series_float]
                sum(valid_mask) < 8 && continue

                indices = cusum_detect(series_float, valid_mask;
                                       slack=slack, threshold=threshold)

                for idx in indices
                    # Direction uses the (possibly normalised) series value at onset
                    val = Float64(series_float[idx])
                    # Determine direction from reference mean
                    ref_end = max(1, round(Int, sum(valid_mask) * 0.2))
                    ref_vals = [Float64(v) for (v, m) in zip(series_float, valid_mask) if m][1:ref_end]
                    ref_mu   = sum(ref_vals) / length(ref_vals)
                    direction = val >= ref_mu ? "increase" : "decrease"

                    dt = sub.period_start[idx]

                    key = (metric, gran)
                    if !haskey(detection_index, key)
                        detection_index[key] = Tuple{Int,DateTime}[]
                    end
                    push!(detection_index[key], (prn, dt))

                    push!(all_cps, BehavioralChangePoint(
                        dt, gran, prn, metric, direction,
                        threshold,  # We use the threshold as the representative statistic
                        false, 0    # Coordination filled in below
                    ))
                end
            end
        end
    end

    # ── Coordination pass ────────────────────────────────────────────────
    # For each detection, count how many other PRNs signalled the same metric
    # within ±coordinated_window_days
    window_ms = coordinated_window_days * 24 * 3600 * 1000  # milliseconds

    updated_cps = BehavioralChangePoint[]
    for cp in all_cps
        key = (cp.metric, cp.granularity)
        others = get(detection_index, key, Tuple{Int,DateTime}[])
        nearby_prns = Set{Int}()
        for (other_prn, other_dt) in others
            other_prn == cp.prn && continue
            other_prn == 0 && continue   # Skip fleet aggregate for coordination count
            if abs(Dates.value(other_dt - cp.detected_at)) <= window_ms
                push!(nearby_prns, other_prn)
            end
        end
        n_coord = length(nearby_prns)
        is_coord = cp.prn != 0 && n_coord + 1 >= coordinated_min_prns

        push!(updated_cps, BehavioralChangePoint(
            cp.detected_at, cp.granularity, cp.prn, cp.metric, cp.direction,
            cp.cusum_statistic, is_coord, n_coord + (cp.prn != 0 ? 1 : 0)
        ))
    end

    # Convert to DataFrame
    if isempty(updated_cps)
        return DataFrame(
            detected_at            = DateTime[],
            granularity            = String[],
            prn                    = Int[],
            metric                 = String[],
            direction              = String[],
            cusum_statistic        = Float64[],
            is_coordinated         = Bool[],
            coordinated_prn_count  = Int[],
        )
    end

    DataFrame(
        detected_at            = [c.detected_at           for c in updated_cps],
        granularity            = [c.granularity            for c in updated_cps],
        prn                    = [c.prn                    for c in updated_cps],
        metric                 = [c.metric                 for c in updated_cps],
        direction              = [c.direction              for c in updated_cps],
        cusum_statistic        = [c.cusum_statistic        for c in updated_cps],
        is_coordinated         = [c.is_coordinated         for c in updated_cps],
        coordinated_prn_count  = [c.coordinated_prn_count for c in updated_cps],
    )
end

"""
    get_duration_distribution(db::DuckDB.DB;
                             year::Union{Int,Nothing}=nothing,
                             prn::Union{Int,Nothing}=nothing) -> NamedTuple

Compute distribution statistics for message durations.
Returns percentiles, mean, median, and mode.

# Example
```julia
db = DuckDB.DB("messages.db")
dist = get_duration_distribution(db; year=2022)
println("Mean duration: \$(dist.mean_hours) hours")
println("Median duration: \$(dist.median_hours) hours")
println("90th percentile: \$(dist.p90_hours) hours")
```
"""
function get_duration_distribution(db::DuckDB.DB;
                                  year::Union{Int,Nothing}=nothing,
                                  prn::Union{Int,Nothing}=nothing)

    where_clauses = String[]
    params = Any[]

    if !isnothing(year)
        push!(where_clauses, "EXTRACT(YEAR FROM transition_time) = ?")
        push!(params, year)
    end

    if !isnothing(prn)
        push!(where_clauses, "prn = ?")
        push!(params, prn)
    end

    # Build complete WHERE clause
    if !isempty(where_clauses)
        push!(where_clauses, "to_hash IS NOT NULL")
        push!(where_clauses, "duration_hours IS NOT NULL")
        where_sql = "WHERE " * join(where_clauses, " AND ")
    else
        where_sql = "WHERE to_hash IS NOT NULL AND duration_hours IS NOT NULL"
    end

    query = """
    SELECT
        AVG(duration_hours) as mean_hours,
        MEDIAN(duration_hours) as median_hours,
        MODE(duration_hours) as mode_hours,
        STDDEV(duration_hours) as std_hours,
        MIN(duration_hours) as min_hours,
        MAX(duration_hours) as max_hours,
        PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY duration_hours) as p25_hours,
        PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY duration_hours) as p50_hours,
        PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY duration_hours) as p75_hours,
        PERCENTILE_CONT(0.90) WITHIN GROUP (ORDER BY duration_hours) as p90_hours,
        PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY duration_hours) as p95_hours,
        PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY duration_hours) as p99_hours,
        COUNT(*) as num_transitions
    FROM message_transitions
    $where_sql
    """

    result = if isempty(params)
        DBInterface.execute(db, query)
    else
        stmt = DBInterface.prepare(db, query)
        DBInterface.execute(stmt, params)
    end

    row = first(result)

    return (
        mean_hours = ismissing(row.mean_hours) ? 0.0 : row.mean_hours,
        median_hours = ismissing(row.median_hours) ? 0.0 : row.median_hours,
        mode_hours = ismissing(row.mode_hours) ? 0.0 : row.mode_hours,
        std_hours = ismissing(row.std_hours) ? 0.0 : row.std_hours,
        min_hours = ismissing(row.min_hours) ? 0.0 : row.min_hours,
        max_hours = ismissing(row.max_hours) ? 0.0 : row.max_hours,
        p25_hours = ismissing(row.p25_hours) ? 0.0 : row.p25_hours,
        p50_hours = ismissing(row.p50_hours) ? 0.0 : row.p50_hours,
        p75_hours = ismissing(row.p75_hours) ? 0.0 : row.p75_hours,
        p90_hours = ismissing(row.p90_hours) ? 0.0 : row.p90_hours,
        p95_hours = ismissing(row.p95_hours) ? 0.0 : row.p95_hours,
        p99_hours = ismissing(row.p99_hours) ? 0.0 : row.p99_hours,
        num_transitions = row.num_transitions
    )
end
