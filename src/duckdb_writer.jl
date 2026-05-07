# DuckDB operations for GPS special message storage

using DuckDB
using SHA
using Dates
using DataFrames

"""
    with_transaction(fn, db::DuckDB.DB)

Execute `fn()` inside a DuckDB transaction. Commits on success, rolls back on error.
"""
function with_transaction(fn, db::DuckDB.DB)
    DBInterface.execute(db, "BEGIN TRANSACTION")
    try
        fn()
        DBInterface.execute(db, "COMMIT")
    catch e
        DBInterface.execute(db, "ROLLBACK")
        rethrow(e)
    end
end

"""
    compute_message_hash(raw_bytes::Vector{UInt8}) -> String

Compute SHA256 hash of message bytes for deduplication.
Returns hex-encoded hash string.
"""
function compute_message_hash(raw_bytes::Vector{UInt8})::String
    hash_bytes = sha256(raw_bytes)
    return bytes2hex(hash_bytes)
end

"""
    create_database(db_path::String; replace::Bool=true) -> DuckDB.DB

Create a DuckDB database with the special_messages table schema.

If `replace=true` (default), drops existing table before creating new one.
Returns the database connection.
"""
function create_database(db_path::String; replace::Bool=true)::DuckDB.DB
    # Create or open database
    db = DuckDB.DB(db_path)

    # Drop table if replace mode
    if replace
        DBInterface.execute(db, "DROP TABLE IF EXISTS special_messages")
    end

    # Create table with comprehensive schema
    create_table_sql = """
    CREATE TABLE IF NOT EXISTS special_messages (
        -- Primary temporal identifiers
        datetime TIMESTAMP NOT NULL,
        year INTEGER NOT NULL,
        day_of_year INTEGER NOT NULL,
        seconds_of_day INTEGER NOT NULL,
        gps_week INTEGER NOT NULL,

        -- Satellite identifiers
        prn INTEGER NOT NULL,
        sv_id INTEGER NOT NULL,

        -- Message content
        ascii_message VARCHAR(22) NOT NULL,
        raw_bytes BLOB NOT NULL,
        message_hash VARCHAR(64) NOT NULL,

        -- Frame metadata
        alert_flag BOOLEAN NOT NULL,
        multiplicity INTEGER NOT NULL,

        -- File provenance
        source_file VARCHAR NOT NULL,

        -- Statistical analysis fields
        is_likely_text BOOLEAN NOT NULL,
        printable_chars INTEGER NOT NULL,
        null_bytes INTEGER NOT NULL,
        entropy DOUBLE,

        -- Primary key
        PRIMARY KEY (datetime, prn, message_hash)
    )
    """
    DBInterface.execute(db, create_table_sql)

    # Create indexes for efficient querying
    index_sqls = [
        "CREATE INDEX IF NOT EXISTS idx_datetime ON special_messages(datetime)",
        "CREATE INDEX IF NOT EXISTS idx_prn ON special_messages(prn)",
        "CREATE INDEX IF NOT EXISTS idx_message_hash ON special_messages(message_hash)",
        "CREATE INDEX IF NOT EXISTS idx_year_doy ON special_messages(year, day_of_year)",
        "CREATE INDEX IF NOT EXISTS idx_is_likely_text ON special_messages(is_likely_text)"
    ]

    for sql in index_sqls
        DBInterface.execute(db, sql)
    end

    # Create temporal analysis views
    create_temporal_views(db)

    # Create duplicate observations table for multi-receiver analysis
    create_duplicates_table(db)

    return db
end

"""
    create_duplicates_table(db::DuckDB.DB)

Create tables to track duplicate observations:
1. `duplicate_observations` - Conflicting duplicates (same datetime+prn, different message)
2. `identical_duplicates` - Identical duplicates (same datetime+prn+message, multiple occurrences)

Called automatically by create_database().
"""
function create_duplicates_table(db::DuckDB.DB)
    # Table to store conflicting observations (different messages at same time)
    duplicates_sql = """
    CREATE TABLE IF NOT EXISTS duplicate_observations (
        -- When and which satellite
        datetime TIMESTAMP NOT NULL,
        prn INTEGER NOT NULL,

        -- First observation (the one that was kept)
        existing_message_hash VARCHAR(64) NOT NULL,
        existing_ascii_message VARCHAR(22) NOT NULL,
        existing_source_file VARCHAR NOT NULL,

        -- Conflicting observation (the one that would have been ignored)
        new_message_hash VARCHAR(64) NOT NULL,
        new_ascii_message VARCHAR(22) NOT NULL,
        new_source_file VARCHAR NOT NULL,

        -- When this duplicate was detected
        detected_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,

        -- Primary key on the conflict pair
        PRIMARY KEY (datetime, prn, existing_message_hash, new_message_hash)
    )
    """
    DBInterface.execute(db, duplicates_sql)

    # Table to track identical duplicates (same datetime+prn+message appearing multiple times).
    #
    # Why duplicates exist: The GFZ archive contains both original and reprocessed versions
    # of some data (e.g., days 91-97 of 2008 have both "_A" and non-"_A" directories).
    # Analysis confirmed these are true duplicates - the entire 300-bit LNAV subframe is
    # byte-for-byte identical, not just the special message portion. The reprocessed versions
    # sometimes include additional earlier observations, but all overlapping data is identical.
    # See: identical_duplicates_analysis.md
    identical_sql = """
    CREATE TABLE IF NOT EXISTS identical_duplicates (
        -- The observation that was duplicated
        datetime TIMESTAMP NOT NULL,
        prn INTEGER NOT NULL,
        message_hash VARCHAR(64) NOT NULL,
        ascii_message VARCHAR(22) NOT NULL,

        -- How many times it appeared
        occurrence_count INTEGER NOT NULL DEFAULT 1,

        -- Source files where it appeared
        source_files VARCHAR[] NOT NULL,

        -- Primary key
        PRIMARY KEY (datetime, prn, message_hash)
    )
    """
    DBInterface.execute(db, identical_sql)

    # Index for efficient querying
    DBInterface.execute(db, """
        CREATE INDEX IF NOT EXISTS idx_dup_datetime ON duplicate_observations(datetime)
    """)
    DBInterface.execute(db, """
        CREATE INDEX IF NOT EXISTS idx_dup_prn ON duplicate_observations(prn)
    """)
    DBInterface.execute(db, """
        CREATE INDEX IF NOT EXISTS idx_identical_prn ON identical_duplicates(prn)
    """)
end

"""
    create_temporal_views(db::DuckDB.DB)

Create materialized views for temporal pattern analysis.
Called automatically by create_database().
"""
function create_temporal_views(db::DuckDB.DB)
    # View: Message durations per satellite
    duration_view_sql = """
    CREATE OR REPLACE VIEW message_durations AS
    SELECT
        message_hash,
        prn,
        MIN(datetime) as first_seen,
        MAX(datetime) as last_seen,
        EXTRACT(EPOCH FROM (MAX(datetime) - MIN(datetime)))/3600.0 as duration_hours,
        COUNT(*) as num_observations,
        ANY_VALUE(ascii_message) as ascii_message
    FROM special_messages
    GROUP BY message_hash, prn
    """
    DBInterface.execute(db, duration_view_sql)

    # View: Message transitions
    transition_view_sql = """
    CREATE OR REPLACE VIEW message_transitions AS
    SELECT
        prn,
        message_hash as from_hash,
        ascii_message as from_message,
        LEAD(message_hash) OVER (PARTITION BY prn ORDER BY datetime) as to_hash,
        LEAD(ascii_message) OVER (PARTITION BY prn ORDER BY datetime) as to_message,
        datetime as transition_time,
        LEAD(datetime) OVER (PARTITION BY prn ORDER BY datetime) as next_time,
        EXTRACT(EPOCH FROM (LEAD(datetime) OVER (PARTITION BY prn ORDER BY datetime) - datetime))/3600.0 as duration_hours
    FROM (
        SELECT DISTINCT ON (prn, datetime, message_hash)
            prn,
            datetime,
            message_hash,
            ascii_message
        FROM special_messages
        ORDER BY prn, datetime, message_hash
    ) AS distinct_messages
    """
    DBInterface.execute(db, transition_view_sql)

    # View: Day of week patterns
    dow_view_sql = """
    CREATE OR REPLACE VIEW day_of_week_patterns AS
    SELECT
        DAYOFWEEK(datetime) as day_of_week,
        year,
        COUNT(*) as message_count,
        COUNT(DISTINCT message_hash) as unique_messages,
        AVG(entropy) as avg_entropy
    FROM special_messages
    GROUP BY DAYOFWEEK(datetime), year
    """
    DBInterface.execute(db, dow_view_sql)
end

"""
    sanitize_ascii_message(msg::String) -> String

Sanitize message for database storage by replacing null bytes with the
Unicode replacement character (U+FFFD). DuckDB's C API cannot handle
embedded null bytes in VARCHAR fields.
"""
function sanitize_ascii_message(msg::String)::String
    return replace(msg, '\0' => '�')
end

"""
    insert_message!(db::DuckDB.DB, msg::DecodedSpecialMessage, meta::FileMetadata, multiplicity::Int32)

Insert a single special message into the database.
Records any duplicates to appropriate tables:
- Identical duplicates (same datetime+prn+message) -> identical_duplicates table, skip insertion
- Conflicting duplicates (same datetime+prn, different message) -> duplicate_observations table
"""
function insert_message!(db::DuckDB.DB, msg::DecodedSpecialMessage, meta::FileMetadata, multiplicity::Int32)
    # Compute message statistics
    stats = compute_message_stats(msg.raw_bytes)
    hash = compute_message_hash(msg.raw_bytes)
    sanitized_msg = sanitize_ascii_message(msg.ascii_message)

    # Check for duplicates - if identical duplicate found, skip insertion
    is_identical_dup = check_and_record_duplicate!(db, msg.datetime, msg.prn, hash, sanitized_msg, meta.source_file)
    if is_identical_dup
        return  # Already recorded in identical_duplicates table
    end

    # Prepare insert statement with conflict resolution
    # OR IGNORE is a fallback for any edge cases
    insert_sql = """
    INSERT OR IGNORE INTO special_messages VALUES (
        ?, ?, ?, ?, ?,
        ?, ?,
        ?, ?, ?,
        ?, ?,
        ?,
        ?, ?, ?, ?
    )
    """

    # Execute insert with parameters
    stmt = DBInterface.prepare(db, insert_sql)
    DBInterface.execute(stmt, [
        msg.datetime,
        meta.year,
        meta.day_of_year,
        msg.time,
        meta.gps_week,
        msg.prn,
        msg.sv_id,
        sanitized_msg,
        msg.raw_bytes,
        hash,
        msg.alert_flag,
        multiplicity,
        meta.source_file,
        stats.is_likely_text,
        stats.printable_chars,
        stats.null_bytes,
        stats.entropy
    ])
end

"""
    check_and_record_duplicate!(db::DuckDB.DB, datetime::DateTime, prn::Int,
                                new_hash::String, new_message::String, new_source::String) -> Bool

Check if a record exists for (datetime, prn) and handle duplicates:
1. If same hash exists (identical duplicate): record in identical_duplicates table, return true
2. If different hash exists (conflicting duplicate): record in duplicate_observations table, return false
3. If no record exists: return false

Returns true if an identical duplicate was found (caller should skip insertion).
"""
function check_and_record_duplicate!(db::DuckDB.DB, datetime::DateTime, prn::Int,
                                     new_hash::String, new_message::String, new_source::String)::Bool
    # First check for identical duplicate (same datetime+prn+hash)
    check_identical_sql = """
    SELECT source_file
    FROM special_messages
    WHERE datetime = ? AND prn = ? AND message_hash = ?
    LIMIT 1
    """

    stmt = DBInterface.prepare(db, check_identical_sql)
    result = DBInterface.execute(stmt, [datetime, prn, new_hash])

    for row in result
        # Found identical record - track in identical_duplicates
        # Use INSERT ... ON CONFLICT to increment count and append source file
        upsert_sql = """
        INSERT INTO identical_duplicates (datetime, prn, message_hash, ascii_message, occurrence_count, source_files)
        VALUES (?, ?, ?, ?, 2, [?, ?])
        ON CONFLICT (datetime, prn, message_hash) DO UPDATE SET
            occurrence_count = identical_duplicates.occurrence_count + 1,
            source_files = list_append(identical_duplicates.source_files, ?)
        """

        upsert_stmt = DBInterface.prepare(db, upsert_sql)
        DBInterface.execute(upsert_stmt, [
            datetime, prn, new_hash, new_message,
            row.source_file, new_source,  # Initial source files array
            new_source  # Append on conflict
        ])
        return true  # Signal that this is an identical duplicate - skip insertion
    end

    # Check for conflicting duplicate (same datetime+prn but different hash)
    check_conflict_sql = """
    SELECT message_hash, ascii_message, source_file
    FROM special_messages
    WHERE datetime = ? AND prn = ? AND message_hash != ?
    LIMIT 1
    """

    stmt2 = DBInterface.prepare(db, check_conflict_sql)
    result2 = DBInterface.execute(stmt2, [datetime, prn, new_hash])

    for row in result2
        # Found a conflicting record - record the duplicate
        insert_dup_sql = """
        INSERT OR IGNORE INTO duplicate_observations (
            datetime, prn,
            existing_message_hash, existing_ascii_message, existing_source_file,
            new_message_hash, new_ascii_message, new_source_file
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """

        dup_stmt = DBInterface.prepare(db, insert_dup_sql)
        DBInterface.execute(dup_stmt, [
            datetime, prn,
            row.message_hash, row.ascii_message, row.source_file,
            new_hash, new_message, new_source
        ])
        break  # Only need to record once per check
    end

    return false  # Not an identical duplicate - proceed with insertion
end

"""
    insert_messages!(db::DuckDB.DB, messages::Vector{DecodedSpecialMessage},
                     meta::FileMetadata, multiplicities::Vector{Int32};
                     track_duplicates::Bool=true)

Batch insert multiple special messages into the database.

Uses a single transaction for efficiency.
`multiplicities` should have the same length as `messages`.

If `track_duplicates=true` (default), checks for and records any observations where
the same (datetime, prn) has different message content - indicating multi-receiver data.
"""
function insert_messages!(db::DuckDB.DB,
                          messages::Vector{DecodedSpecialMessage},
                          meta::FileMetadata,
                          multiplicities::Vector{Int32};
                          track_duplicates::Bool=true)
    if isempty(messages)
        return
    end

    @assert length(messages) == length(multiplicities) "messages and multiplicities must have same length"

    # Prepare insert statement with conflict resolution
    # OR IGNORE skips duplicate primary keys (same datetime, prn, message_hash)
    insert_sql = """
    INSERT OR IGNORE INTO special_messages VALUES (
        ?, ?, ?, ?, ?,
        ?, ?,
        ?, ?, ?,
        ?, ?,
        ?,
        ?, ?, ?, ?
    )
    """

    with_transaction(db) do
        stmt = DBInterface.prepare(db, insert_sql)

        for (msg, mult) in zip(messages, multiplicities)
            # Compute message statistics
            stats = compute_message_stats(msg.raw_bytes)
            hash = compute_message_hash(msg.raw_bytes)
            sanitized_msg = sanitize_ascii_message(msg.ascii_message)

            # Check for duplicates before inserting - skip if identical duplicate
            if track_duplicates
                is_identical_dup = check_and_record_duplicate!(db, msg.datetime, msg.prn, hash, sanitized_msg, meta.source_file)
                if is_identical_dup
                    continue  # Skip insertion, already recorded in identical_duplicates
                end
            end

            # Execute insert
            DBInterface.execute(stmt, [
                msg.datetime,
                meta.year,
                meta.day_of_year,
                msg.time,
                meta.gps_week,
                msg.prn,
                msg.sv_id,
                sanitized_msg,
                msg.raw_bytes,
                hash,
                msg.alert_flag,
                mult,
                meta.source_file,
                stats.is_likely_text,
                stats.printable_chars,
                stats.null_bytes,
                stats.entropy
            ])
        end
    end
end

"""
    get_message_count(db::DuckDB.DB) -> Int

Get the total number of messages in the database.
"""
function get_message_count(db::DuckDB.DB)::Int
    result = DBInterface.execute(db, "SELECT COUNT(*) as count FROM special_messages")
    row = first(result)
    return row.count
end

"""
    get_unique_message_count(db::DuckDB.DB) -> Int

Get the count of unique messages (by message_hash) in the database.
"""
function get_unique_message_count(db::DuckDB.DB)::Int
    result = DBInterface.execute(db, "SELECT COUNT(DISTINCT message_hash) as count FROM special_messages")
    row = first(result)
    return row.count
end

"""
    get_duplicate_count(db::DuckDB.DB) -> Int

Get the total number of duplicate observations recorded.
"""
function get_duplicate_count(db::DuckDB.DB)::Int
    result = DBInterface.execute(db, "SELECT COUNT(*) as count FROM duplicate_observations")
    row = first(result)
    return row.count
end

"""
    get_duplicates(db::DuckDB.DB; prn::Union{Int,Nothing}=nothing,
                   limit::Int=100) -> DataFrame

Query duplicate observations from the database.

These are cases where the same (datetime, prn) had different message content,
indicating data from multiple receivers or processing anomalies.

# Arguments
- `db`: Database connection
- `prn`: Optional PRN filter
- `limit`: Maximum rows to return (default: 100)

# Example
```julia
db = DuckDB.DB("messages.duckdb")
dups = get_duplicates(db)
if nrow(dups) > 0
    println("Found \$(nrow(dups)) duplicate observations!")
    for row in eachrow(dups)
        println("  \$(row.datetime) PRN \$(row.prn):")
        println("    Existing: \$(row.existing_ascii_message)")
        println("    New:      \$(row.new_ascii_message)")
    end
end
```
"""
function get_duplicates(db::DuckDB.DB; prn::Union{Int,Nothing}=nothing, limit::Int=100)::DataFrame
    where_sql = isnothing(prn) ? "" : "WHERE prn = ?"
    params = isnothing(prn) ? Any[] : Any[prn]

    query = """
    SELECT
        datetime,
        prn,
        existing_message_hash,
        existing_ascii_message,
        existing_source_file,
        new_message_hash,
        new_ascii_message,
        new_source_file,
        detected_at
    FROM duplicate_observations
    $where_sql
    ORDER BY datetime
    LIMIT $limit
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
    get_duplicate_summary(db::DuckDB.DB) -> DataFrame

Get summary statistics about duplicate observations.

Returns counts grouped by PRN showing which satellites have the most duplicates.
High duplicate counts for certain PRNs might indicate geographic targeting
if the data comes from multiple receiver locations.
"""
function get_duplicate_summary(db::DuckDB.DB)::DataFrame
    query = """
    SELECT
        prn,
        COUNT(*) as duplicate_count,
        COUNT(DISTINCT datetime) as unique_timestamps,
        COUNT(DISTINCT existing_message_hash) as unique_existing_messages,
        COUNT(DISTINCT new_message_hash) as unique_new_messages,
        MIN(datetime) as first_duplicate,
        MAX(datetime) as last_duplicate
    FROM duplicate_observations
    GROUP BY prn
    ORDER BY duplicate_count DESC
    """

    result = DBInterface.execute(db, query)
    return DataFrame(result)
end

"""
    get_duplicate_source_pairs(db::DuckDB.DB) -> DataFrame

Analyze which source file pairs produce duplicates.

This helps identify which receiver stations (if identifiable from filenames)
are seeing different content at the same times.
"""
function get_duplicate_source_pairs(db::DuckDB.DB)::DataFrame
    query = """
    SELECT
        existing_source_file,
        new_source_file,
        COUNT(*) as duplicate_count,
        COUNT(DISTINCT prn) as affected_prns,
        MIN(datetime) as first_occurrence,
        MAX(datetime) as last_occurrence
    FROM duplicate_observations
    GROUP BY existing_source_file, new_source_file
    ORDER BY duplicate_count DESC
    LIMIT 50
    """

    result = DBInterface.execute(db, query)
    return DataFrame(result)
end

"""
    analyze_duplicate_messages(db::DuckDB.DB) -> DataFrame

Analyze the message content of duplicates to understand the differences.

Computes statistics about how different the conflicting messages are,
which can help distinguish between:
- Bit errors (small differences)
- Completely different messages (potential geographic targeting)
- Systematic patterns
"""
function analyze_duplicate_messages(db::DuckDB.DB)::DataFrame
    query = """
    SELECT
        existing_ascii_message,
        new_ascii_message,
        COUNT(*) as occurrence_count,
        COUNT(DISTINCT prn) as prn_count,
        LIST(DISTINCT prn ORDER BY prn) as prns
    FROM duplicate_observations
    GROUP BY existing_ascii_message, new_ascii_message
    ORDER BY occurrence_count DESC
    LIMIT 50
    """

    result = DBInterface.execute(db, query)
    return DataFrame(result)
end

"""
    get_identical_duplicate_count(db::DuckDB.DB) -> Int

Get the total number of identical duplicate observations recorded.
These are cases where the exact same (datetime, prn, message) appeared
multiple times across different source files.
"""
function get_identical_duplicate_count(db::DuckDB.DB)::Int
    result = DBInterface.execute(db, "SELECT COUNT(*) as count FROM identical_duplicates")
    row = first(result)
    return row.count
end

"""
    get_total_identical_occurrences(db::DuckDB.DB) -> Int

Get the total number of duplicate occurrences (sum of all occurrence_count - 1).
This represents how many insertions were skipped due to identical duplicates.
"""
function get_total_identical_occurrences(db::DuckDB.DB)::Int
    result = DBInterface.execute(db, """
        SELECT COALESCE(SUM(occurrence_count) - COUNT(*), 0) as total_skipped
        FROM identical_duplicates
    """)
    row = first(result)
    return row.total_skipped
end

"""
    get_identical_duplicates(db::DuckDB.DB; prn::Union{Int,Nothing}=nothing,
                              limit::Int=100) -> DataFrame

Query identical duplicate observations from the database.

These are cases where the exact same (datetime, prn, message) appeared
multiple times, typically from multiple source files.

# Arguments
- `db`: Database connection
- `prn`: Optional PRN filter
- `limit`: Maximum rows to return (default: 100)
"""
function get_identical_duplicates(db::DuckDB.DB; prn::Union{Int,Nothing}=nothing, limit::Int=100)::DataFrame
    where_sql = isnothing(prn) ? "" : "WHERE prn = ?"
    params = isnothing(prn) ? Any[] : Any[prn]

    query = """
    SELECT
        datetime,
        prn,
        message_hash,
        ascii_message,
        occurrence_count,
        source_files
    FROM identical_duplicates
    $where_sql
    ORDER BY occurrence_count DESC, datetime
    LIMIT $limit
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
    create_behavioral_tables!(db::DuckDB.DB)

Create `behavioral_metrics` and `behavioral_change_points` tables if they do
not already exist.  Safe to call on a database that already has these tables.
"""
function create_behavioral_tables!(db::DuckDB.DB)
    DBInterface.execute(db, """
    CREATE TABLE IF NOT EXISTS behavioral_metrics (
        period_start         TIMESTAMP NOT NULL,
        granularity          VARCHAR   NOT NULL,
        prn                  INTEGER   NOT NULL,
        observation_count    INTEGER,
        transition_count     INTEGER,
        unique_message_count INTEGER,
        mean_entropy         DOUBLE,
        sentinel_fraction    DOUBLE,
        text_fraction        DOUBLE,
        active_prn_count     INTEGER,
        mean_duration_hours  DOUBLE,
        PRIMARY KEY (period_start, granularity, prn)
    )
    """)
    # Migration: add mean_duration_hours for existing databases that pre-date this column
    try
        DBInterface.execute(db, "ALTER TABLE behavioral_metrics ADD COLUMN mean_duration_hours DOUBLE")
    catch; end

    DBInterface.execute(db, """
    CREATE TABLE IF NOT EXISTS behavioral_change_points (
        detected_at           TIMESTAMP NOT NULL,
        granularity           VARCHAR   NOT NULL,
        prn                   INTEGER   NOT NULL,
        metric                VARCHAR   NOT NULL,
        direction             VARCHAR   NOT NULL,
        cusum_statistic       DOUBLE    NOT NULL,
        is_coordinated        BOOLEAN   NOT NULL,
        coordinated_prn_count INTEGER
    )
    """)
end

"""
    save_behavioral_metrics!(db::DuckDB.DB, metrics_df::DataFrame)

Insert-or-replace all rows of `metrics_df` into the `behavioral_metrics` table.
Requires `create_behavioral_tables!` to have been called first.
"""
function save_behavioral_metrics!(db::DuckDB.DB, metrics_df::DataFrame;
                                  batch_size::Int=5_000)
    isempty(metrics_df) && return

    sql = """
    INSERT OR REPLACE INTO behavioral_metrics (
        period_start, granularity, prn,
        observation_count, transition_count, unique_message_count,
        mean_entropy, sentinel_fraction, text_fraction, active_prn_count,
        mean_duration_hours
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    """

    stmt = DBInterface.prepare(db, sql)
    n = nrow(metrics_df)
    i = 1
    while i <= n
        batch_end = min(i + batch_size - 1, n)
        with_transaction(db) do
            for row in eachrow(metrics_df[i:batch_end, :])
                DBInterface.execute(stmt, [
                    row.period_start,
                    row.granularity,
                    row.prn,
                    ismissing(row.observation_count)    ? missing : Int(row.observation_count),
                    ismissing(row.transition_count)     ? missing : Int(row.transition_count),
                    ismissing(row.unique_message_count) ? missing : Int(row.unique_message_count),
                    ismissing(row.mean_entropy)         ? missing : Float64(row.mean_entropy),
                    ismissing(row.sentinel_fraction)    ? missing : Float64(row.sentinel_fraction),
                    ismissing(row.text_fraction)        ? missing : Float64(row.text_fraction),
                    ismissing(row.active_prn_count)     ? missing : Int(row.active_prn_count),
                    ismissing(row.mean_duration_hours)  ? missing : Float64(row.mean_duration_hours),
                ])
            end
        end
        i = batch_end + 1
    end
end

"""
    save_behavioral_change_points!(db::DuckDB.DB, change_points_df::DataFrame)

Insert all rows of `change_points_df` into the `behavioral_change_points` table.
Clears existing rows first so re-runs are idempotent.
"""
function save_behavioral_change_points!(db::DuckDB.DB, change_points_df::DataFrame)
    DBInterface.execute(db, "DELETE FROM behavioral_change_points")
    isempty(change_points_df) && return

    sql = """
    INSERT INTO behavioral_change_points (
        detected_at, granularity, prn, metric, direction,
        cusum_statistic, is_coordinated, coordinated_prn_count
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    """

    with_transaction(db) do
        stmt = DBInterface.prepare(db, sql)
        for row in eachrow(change_points_df)
            DBInterface.execute(stmt, [
                row.detected_at,
                row.granularity,
                row.prn,
                row.metric,
                row.direction,
                Float64(row.cusum_statistic),
                Bool(row.is_coordinated),
                Int(row.coordinated_prn_count),
            ])
        end
    end
end

"""
    get_behavioral_change_points(db::DuckDB.DB;
                                 prn::Union{Int,Nothing}=nothing,
                                 metric::Union{String,Nothing}=nothing) -> DataFrame

Query detected behavioral change points from the database.

# Arguments
- `db`: Database connection
- `prn`: Optional PRN filter (0 = fleet aggregate)
- `metric`: Optional metric name filter
"""
function get_behavioral_change_points(db::DuckDB.DB;
                                      prn::Union{Int,Nothing}=nothing,
                                      metric::Union{String,Nothing}=nothing)::DataFrame
    where_clauses = String[]
    params = Any[]

    if !isnothing(prn)
        push!(where_clauses, "prn = ?")
        push!(params, prn)
    end
    if !isnothing(metric)
        push!(where_clauses, "metric = ?")
        push!(params, metric)
    end

    where_sql = isempty(where_clauses) ? "" : "WHERE " * join(where_clauses, " AND ")

    query = """
    SELECT
        detected_at, granularity, prn, metric, direction,
        cusum_statistic, is_coordinated, coordinated_prn_count
    FROM behavioral_change_points
    $where_sql
    ORDER BY detected_at, prn, metric
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
    create_nanu_tables!(db::DuckDB.DB)

Create `nanu_records` and `change_point_nanu_correlations` tables if they do
not already exist. Safe to call on a database that already has these tables.
"""
function create_nanu_tables!(db::DuckDB.DB)
    DBInterface.execute(db, """
    CREATE TABLE IF NOT EXISTS nanu_records (
        nanu_id         VARCHAR NOT NULL PRIMARY KEY,
        msg_datetime    TIMESTAMP NOT NULL,
        prn             INTEGER,
        nanu_type       VARCHAR NOT NULL,
        category        VARCHAR NOT NULL,
        event_start     TIMESTAMP,
        event_stop      TIMESTAMP,
        source_file     VARCHAR NOT NULL
    )
    """)

    DBInterface.execute(db, """
    CREATE INDEX IF NOT EXISTS idx_nanu_datetime ON nanu_records(msg_datetime)
    """)
    DBInterface.execute(db, """
    CREATE INDEX IF NOT EXISTS idx_nanu_prn ON nanu_records(prn)
    """)
    DBInterface.execute(db, """
    CREATE INDEX IF NOT EXISTS idx_nanu_type ON nanu_records(nanu_type)
    """)

    DBInterface.execute(db, """
    CREATE TABLE IF NOT EXISTS change_point_nanu_correlations (
        cp_detected_at    TIMESTAMP NOT NULL,
        cp_granularity    VARCHAR NOT NULL,
        cp_prn            INTEGER NOT NULL,
        cp_metric         VARCHAR NOT NULL,
        nanu_id           VARCHAR NOT NULL,
        nanu_type         VARCHAR NOT NULL,
        nanu_prn          INTEGER,
        time_offset_days  DOUBLE NOT NULL,
        prn_match         BOOLEAN NOT NULL,
        FOREIGN KEY (nanu_id) REFERENCES nanu_records(nanu_id)
    )
    """)

    DBInterface.execute(db, """
    CREATE INDEX IF NOT EXISTS idx_corr_cp ON change_point_nanu_correlations(cp_detected_at, cp_prn)
    """)
end

"""
    save_nanu_records!(db::DuckDB.DB, records::Vector{NANURecord})

Insert NANU records into the `nanu_records` table; rows whose `nanu_id`
already exists are left untouched.

DuckDB enforces foreign-key constraints on `UPDATE` as well as `DELETE`, so
neither `INSERT OR REPLACE` nor `INSERT … ON CONFLICT DO UPDATE` works on an
already-populated DB when sibling tables (`change_point_nanu_correlations`,
`sentinel_nanu_correlations`) hold FK references. This implementation uses
`INSERT … ON CONFLICT DO NOTHING`, which is correct because the records come
from a deterministic parse of the OA archive — re-running the same parse
produces the same set of `nanu_id`s and the same metadata, so a no-op on
conflict is semantically equivalent to a refresh. Both `nanu_correlation.jl`
and `sentinel_nanu.jl` can therefore call this function without coordination.

If the OA archive is updated and existing NANU IDs need to take new metadata
(rare in practice — NANUs are immutable once issued), wipe the table first:
this is what `analysis/run_all.sh` Step 0 does.
"""
function save_nanu_records!(db::DuckDB.DB, records::Vector{NANURecord})
    isempty(records) && return

    sql = """
    INSERT INTO nanu_records (
        nanu_id, msg_datetime, prn, nanu_type, category,
        event_start, event_stop, source_file
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT (nanu_id) DO NOTHING
    """

    with_transaction(db) do
        stmt = DBInterface.prepare(db, sql)
        for rec in records
            DBInterface.execute(stmt, [
                rec.nanu_id,
                rec.msg_datetime,
                isnothing(rec.prn) ? missing : rec.prn,
                rec.nanu_type,
                String(rec.category),
                isnothing(rec.event_start) ? missing : rec.event_start,
                isnothing(rec.event_stop) ? missing : rec.event_stop,
                rec.source_file,
            ])
        end
    end
end

"""
    save_nanu_correlations!(db::DuckDB.DB, correlations_df::DataFrame)

Delete existing correlations and bulk-insert new ones.
"""
function save_nanu_correlations!(db::DuckDB.DB, correlations_df::DataFrame)
    DBInterface.execute(db, "DELETE FROM change_point_nanu_correlations")
    isempty(correlations_df) && return

    sql = """
    INSERT INTO change_point_nanu_correlations (
        cp_detected_at, cp_granularity, cp_prn, cp_metric,
        nanu_id, nanu_type, nanu_prn, time_offset_days, prn_match
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    """

    with_transaction(db) do
        stmt = DBInterface.prepare(db, sql)
        for row in eachrow(correlations_df)
            DBInterface.execute(stmt, [
                row.cp_detected_at,
                row.cp_granularity,
                row.cp_prn,
                row.cp_metric,
                row.nanu_id,
                row.nanu_type,
                ismissing(row.nanu_prn) ? missing : row.nanu_prn,
                Float64(row.time_offset_days),
                Bool(row.prn_match),
            ])
        end
    end
end

"""
    get_nanu_records(db::DuckDB.DB; prn=nothing, nanu_type=nothing) -> DataFrame

Query NANU records from the database with optional filters.
"""
function get_nanu_records(db::DuckDB.DB; prn::Union{Int,Nothing}=nothing,
                          nanu_type::Union{String,Nothing}=nothing)::DataFrame
    where_clauses = String[]
    params = Any[]

    if !isnothing(prn)
        push!(where_clauses, "prn = ?")
        push!(params, prn)
    end
    if !isnothing(nanu_type)
        push!(where_clauses, "nanu_type = ?")
        push!(params, nanu_type)
    end

    where_sql = isempty(where_clauses) ? "" : "WHERE " * join(where_clauses, " AND ")

    query = """
    SELECT nanu_id, msg_datetime, prn, nanu_type, category,
           event_start, event_stop, source_file
    FROM nanu_records
    $where_sql
    ORDER BY msg_datetime, nanu_id
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
    create_sentinel_nanu_table!(db::DuckDB.DB)

Create the `sentinel_nanu_correlations` table if it does not already exist.
Stores correlations between sentinel observation events and NANUs.
"""
function create_sentinel_nanu_table!(db::DuckDB.DB)
    DBInterface.execute(db, """
    CREATE TABLE IF NOT EXISTS sentinel_nanu_correlations (
        prn              INTEGER NOT NULL,
        sentinel_type    VARCHAR NOT NULL,
        event_type       VARCHAR NOT NULL,
        event_date       TIMESTAMP NOT NULL,
        nanu_id          VARCHAR NOT NULL,
        nanu_type        VARCHAR NOT NULL,
        nanu_prn         INTEGER,
        time_offset_days DOUBLE NOT NULL,
        FOREIGN KEY (nanu_id) REFERENCES nanu_records(nanu_id)
    )
    """)

    DBInterface.execute(db, """
    CREATE INDEX IF NOT EXISTS idx_sentinel_corr_prn ON sentinel_nanu_correlations(prn)
    """)
    DBInterface.execute(db, """
    CREATE INDEX IF NOT EXISTS idx_sentinel_corr_event ON sentinel_nanu_correlations(event_date)
    """)
end

"""
    save_sentinel_nanu_correlations!(db::DuckDB.DB, correlations_df::DataFrame)

Delete existing sentinel-NANU correlations and bulk-insert new ones.
"""
function save_sentinel_nanu_correlations!(db::DuckDB.DB, correlations_df::DataFrame)
    DBInterface.execute(db, "DELETE FROM sentinel_nanu_correlations")
    isempty(correlations_df) && return

    sql = """
    INSERT INTO sentinel_nanu_correlations (
        prn, sentinel_type, event_type, event_date,
        nanu_id, nanu_type, nanu_prn, time_offset_days
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    """

    with_transaction(db) do
        stmt = DBInterface.prepare(db, sql)
        for row in eachrow(correlations_df)
            DBInterface.execute(stmt, [
                Int(row.prn),
                String(row.sentinel_type),
                String(row.event_type),
                row.event_date,
                String(row.nanu_id),
                String(row.nanu_type),
                ismissing(row.nanu_prn) ? missing : Int(row.nanu_prn),
                Float64(row.time_offset_days),
            ])
        end
    end
end

"""
    get_identical_duplicate_summary(db::DuckDB.DB) -> DataFrame

Get summary statistics about identical duplicate observations.

Returns counts grouped by PRN showing which satellites have the most
identical duplicates (likely from overlapping data sources).
"""
function get_identical_duplicate_summary(db::DuckDB.DB)::DataFrame
    query = """
    SELECT
        prn,
        COUNT(*) as duplicate_entries,
        SUM(occurrence_count) as total_occurrences,
        SUM(occurrence_count) - COUNT(*) as extra_occurrences,
        MIN(datetime) as first_duplicate,
        MAX(datetime) as last_duplicate
    FROM identical_duplicates
    GROUP BY prn
    ORDER BY extra_occurrences DESC
    """

    result = DBInterface.execute(db, query)
    return DataFrame(result)
end
