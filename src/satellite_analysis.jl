# Satellite-based analysis for GPS special messages
# Analyzes correlations between PRN (satellite) and message content

using DuckDB
using DataFrames

"""
    PRNMessageStats

Statistics about which messages a particular PRN broadcasts.
"""
struct PRNMessageStats
    prn::Int
    unique_messages::Int
    total_observations::Int
    message_hashes::Vector{String}
    first_seen::DateTime
    last_seen::DateTime
end

"""
    MessageExclusivity

Information about messages that appear on a limited number of satellites.
"""
struct MessageExclusivity
    message_hash::String
    ascii_message::String
    prn_count::Int
    prns::Vector{Int}
    total_observations::Int
    first_seen::DateTime
    last_seen::DateTime
end

"""
    PRNOverlapResult

Result of analyzing message overlap between two satellites.
"""
struct PRNOverlapResult
    prn1::Int
    prn2::Int
    shared_messages::Int
    prn1_only::Int
    prn2_only::Int
    jaccard_index::Float64
end

"""
    get_messages_by_prn(db::DuckDB.DB) -> Dict{Int, PRNMessageStats}

Map each PRN to statistics about the messages it broadcasts.

Returns a dictionary mapping PRN (1-32) to PRNMessageStats containing:
- Number of unique messages broadcast by that satellite
- Total observation count
- List of message hashes
- Time range of observations

# Example
```julia
db = DuckDB.DB("messages.duckdb")
prn_stats = get_messages_by_prn(db)
for (prn, stats) in sort(collect(prn_stats))
    println("PRN \$prn: \$(stats.unique_messages) unique messages")
end
```
"""
function get_messages_by_prn(db::DuckDB.DB)::Dict{Int, PRNMessageStats}
    query = """
    SELECT
        prn,
        COUNT(DISTINCT message_hash) as unique_messages,
        COUNT(*) as total_observations,
        LIST(DISTINCT message_hash) as message_hashes,
        MIN(datetime) as first_seen,
        MAX(datetime) as last_seen
    FROM special_messages
    GROUP BY prn
    ORDER BY prn
    """

    result = DBInterface.execute(db, query)

    prn_stats = Dict{Int, PRNMessageStats}()
    for row in result
        prn_stats[row.prn] = PRNMessageStats(
            row.prn,
            row.unique_messages,
            row.total_observations,
            collect(row.message_hashes),
            row.first_seen,
            row.last_seen
        )
    end

    return prn_stats
end

"""
    get_prn_exclusivity(db::DuckDB.DB; max_prns::Int=3) -> Vector{MessageExclusivity}

Find messages that appear on a limited number of satellites.

Messages appearing on only 1-3 satellites might indicate:
- Geographic targeting (different satellites cover different regions)
- Satellite-specific test messages
- Upload errors or anomalies

Returns sorted by PRN count (most exclusive first).

# Arguments
- `db`: Database connection
- `max_prns`: Maximum number of PRNs for a message to be considered "exclusive" (default: 3)

# Example
```julia
db = DuckDB.DB("messages.duckdb")
exclusive = get_prn_exclusivity(db; max_prns=1)  # Single-satellite messages
for msg in exclusive
    println("'\$(msg.ascii_message)' only on PRN(s): \$(msg.prns)")
end
```
"""
function get_prn_exclusivity(db::DuckDB.DB; max_prns::Int=3)::Vector{MessageExclusivity}
    query = """
    SELECT
        message_hash,
        ANY_VALUE(ascii_message) as ascii_message,
        COUNT(DISTINCT prn) as prn_count,
        LIST(DISTINCT prn ORDER BY prn) as prns,
        COUNT(*) as total_observations,
        MIN(datetime) as first_seen,
        MAX(datetime) as last_seen
    FROM special_messages
    GROUP BY message_hash
    HAVING COUNT(DISTINCT prn) <= ?
    ORDER BY prn_count ASC, total_observations DESC
    """

    stmt = DBInterface.prepare(db, query)
    result = DBInterface.execute(stmt, [max_prns])

    exclusives = MessageExclusivity[]
    for row in result
        push!(exclusives, MessageExclusivity(
            row.message_hash,
            row.ascii_message,
            row.prn_count,
            collect(row.prns),
            row.total_observations,
            row.first_seen,
            row.last_seen
        ))
    end

    return exclusives
end

"""
    analyze_prn_message_overlap(db::DuckDB.DB) -> Matrix{Float64}

Compute a 32x32 Jaccard similarity matrix showing message overlap between satellite pairs.

The Jaccard index measures the similarity of message sets:
- 1.0 = identical message sets (both PRNs broadcast exactly the same messages)
- 0.0 = no overlap (no shared messages)

High similarity between satellites might indicate:
- Global message distribution (all satellites get same messages)
- Satellites in same orbital plane sharing messages

Low similarity might indicate:
- Geographic targeting
- Different upload schedules

# Example
```julia
db = DuckDB.DB("messages.duckdb")
overlap = analyze_prn_message_overlap(db)
# Find most dissimilar pair
min_overlap = 1.0
min_pair = (0, 0)
for i in 1:32, j in (i+1):32
    if overlap[i,j] < min_overlap && overlap[i,j] > 0
        min_overlap = overlap[i,j]
        min_pair = (i, j)
    end
end
println("Most dissimilar: PRN \$(min_pair[1]) and PRN \$(min_pair[2]) = \$min_overlap")
```
"""
function analyze_prn_message_overlap(db::DuckDB.DB)::Matrix{Float64}
    # Get message sets for each PRN
    prn_stats = get_messages_by_prn(db)

    # Initialize 32x32 matrix
    overlap_matrix = zeros(Float64, 32, 32)

    # Compute Jaccard similarity for each pair
    for i in 1:32
        for j in i:32
            if i == j
                overlap_matrix[i, j] = 1.0
            elseif haskey(prn_stats, i) && haskey(prn_stats, j)
                set_i = Set(prn_stats[i].message_hashes)
                set_j = Set(prn_stats[j].message_hashes)

                intersection = length(intersect(set_i, set_j))
                union_size = length(union(set_i, set_j))

                if union_size > 0
                    jaccard = intersection / union_size
                    overlap_matrix[i, j] = jaccard
                    overlap_matrix[j, i] = jaccard
                end
            end
        end
    end

    return overlap_matrix
end

"""
    get_prn_overlap_details(db::DuckDB.DB) -> Vector{PRNOverlapResult}

Get detailed overlap statistics for all PRN pairs.

Returns a vector of PRNOverlapResult sorted by Jaccard index (lowest first),
which highlights the most dissimilar satellite pairs.

# Example
```julia
db = DuckDB.DB("messages.duckdb")
overlaps = get_prn_overlap_details(db)
for o in overlaps[1:10]  # 10 most dissimilar pairs
    println("PRN \$(o.prn1) vs PRN \$(o.prn2): Jaccard=\$(round(o.jaccard_index, digits=3))")
    println("  Shared: \$(o.shared_messages), PRN\$(o.prn1)-only: \$(o.prn1_only), PRN\$(o.prn2)-only: \$(o.prn2_only)")
end
```
"""
function get_prn_overlap_details(db::DuckDB.DB)::Vector{PRNOverlapResult}
    prn_stats = get_messages_by_prn(db)

    results = PRNOverlapResult[]

    for i in 1:32
        for j in (i+1):32
            if haskey(prn_stats, i) && haskey(prn_stats, j)
                set_i = Set(prn_stats[i].message_hashes)
                set_j = Set(prn_stats[j].message_hashes)

                shared = length(intersect(set_i, set_j))
                only_i = length(setdiff(set_i, set_j))
                only_j = length(setdiff(set_j, set_i))
                union_size = shared + only_i + only_j

                jaccard = union_size > 0 ? shared / union_size : 0.0

                push!(results, PRNOverlapResult(i, j, shared, only_i, only_j, jaccard))
            end
        end
    end

    # Sort by Jaccard (lowest first to highlight dissimilar pairs)
    sort!(results, by = r -> r.jaccard_index)

    return results
end

"""
    find_duplicate_timestamps(db::DuckDB.DB) -> DataFrame

Find cases where the same PRN at the same timestamp has different messages.

This should be rare or impossible if data is from a single receiver,
but could indicate:
- Data from multiple receivers seeing different satellites
- Data errors or processing issues
- Interesting anomalies worth investigating

# Example
```julia
db = DuckDB.DB("messages.duckdb")
duplicates = find_duplicate_timestamps(db)
if nrow(duplicates) > 0
    println("Found \$(nrow(duplicates)) duplicate timestamp cases")
end
```
"""
function find_duplicate_timestamps(db::DuckDB.DB)::DataFrame
    query = """
    SELECT
        datetime,
        prn,
        COUNT(DISTINCT message_hash) as distinct_messages,
        LIST(DISTINCT message_hash) as message_hashes,
        LIST(DISTINCT ascii_message) as ascii_messages,
        COUNT(*) as total_rows
    FROM special_messages
    GROUP BY datetime, prn
    HAVING COUNT(DISTINCT message_hash) > 1
    ORDER BY datetime
    """

    result = DBInterface.execute(db, query)
    return DataFrame(result)
end

"""
    compute_message_rarity(db::DuckDB.DB) -> DataFrame

Compute rarity metrics for each unique message.

Returns a DataFrame with:
- message_hash, ascii_message
- observation_count: total times message was observed
- prn_count: number of different satellites that broadcast it
- day_count: number of different days it appeared
- rarity_score: composite score (lower = rarer)

Rare messages (appearing infrequently or on few satellites) might be:
- Geographically restricted
- Test messages
- Error states

# Example
```julia
db = DuckDB.DB("messages.duckdb")
rarity = compute_message_rarity(db)
rare_msgs = filter(row -> row.rarity_score < 10, rarity)
println("Found \$(nrow(rare_msgs)) rare messages")
```
"""
function compute_message_rarity(db::DuckDB.DB)::DataFrame
    query = """
    SELECT
        message_hash,
        ANY_VALUE(ascii_message) as ascii_message,
        COUNT(*) as observation_count,
        COUNT(DISTINCT prn) as prn_count,
        COUNT(DISTINCT (year || '-' || day_of_year)) as day_count,
        MIN(datetime) as first_seen,
        MAX(datetime) as last_seen,
        -- Rarity score: geometric mean of counts (lower = rarer)
        POWER(COUNT(*) * COUNT(DISTINCT prn) * COUNT(DISTINCT (year || '-' || day_of_year)), 1.0/3) as rarity_score
    FROM special_messages
    GROUP BY message_hash
    ORDER BY rarity_score ASC
    """

    result = DBInterface.execute(db, query)
    return DataFrame(result)
end

"""
    correlate_rarity_with_prn(db::DuckDB.DB) -> DataFrame

Analyze whether rare messages are concentrated on specific satellites.

Returns statistics per PRN showing:
- How many rare messages (< 100 observations) it broadcasts
- How many common messages (>= 100 observations) it broadcasts
- Ratio of rare to common

If geographic targeting exists, certain satellites might have
disproportionately more rare messages.

# Example
```julia
db = DuckDB.DB("messages.duckdb")
prn_rarity = correlate_rarity_with_prn(db)
# PRNs with unusually high rare message ratio might indicate targeting
```
"""
function correlate_rarity_with_prn(db::DuckDB.DB)::DataFrame
    query = """
    WITH message_counts AS (
        SELECT
            message_hash,
            COUNT(*) as total_count
        FROM special_messages
        GROUP BY message_hash
    ),
    prn_messages AS (
        SELECT DISTINCT prn, message_hash
        FROM special_messages
    )
    SELECT
        pm.prn,
        COUNT(*) as total_unique_messages,
        SUM(CASE WHEN mc.total_count < 100 THEN 1 ELSE 0 END) as rare_messages,
        SUM(CASE WHEN mc.total_count >= 100 THEN 1 ELSE 0 END) as common_messages,
        SUM(CASE WHEN mc.total_count < 100 THEN 1 ELSE 0 END) * 1.0 / COUNT(*) as rare_ratio
    FROM prn_messages pm
    JOIN message_counts mc ON pm.message_hash = mc.message_hash
    GROUP BY pm.prn
    ORDER BY rare_ratio DESC
    """

    result = DBInterface.execute(db, query)
    return DataFrame(result)
end

