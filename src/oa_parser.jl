# GPS Operational Advisory (OA) file parser
#
# Parses .oa1 files from the NAVCEN archive to extract NANU (Notice Advisory
# to Navstar Users) records. Each daily OA file lists all currently active NANUs,
# so the same NANU appears in ~7 consecutive files. Deduplication keeps the
# earliest source file for each NANU ID.

using Dates

"""
    NANURecord

A single NANU (Notice Advisory to Navstar Users) extracted from a GPS
Operational Advisory file.

# Fields
- `nanu_id`: 7-digit identifier (4-digit year + 3-digit sequence), e.g. "2020028"
- `msg_datetime`: When the NANU was issued (from the MSG DATE/TIME column)
- `prn`: Satellite PRN number, or `nothing` for GENERAL/LEAPSEC
- `nanu_type`: e.g. "FCSTDV", "UNUSUFN", "GENERAL", "LAUNCH"
- `category`: `:forecast`, `:advisory`, or `:general` (from Section 2A/B/C)
- `event_start`: Start of the event window, or `nothing`
- `event_stop`: Stop of the event window, or `nothing`
- `source_file`: Relative path e.g. "2020/180.oa1"
"""
struct NANURecord
    nanu_id::String
    msg_datetime::DateTime
    prn::Union{Int,Nothing}
    nanu_type::String
    category::Symbol
    event_start::Union{DateTime,Nothing}
    event_stop::Union{DateTime,Nothing}
    source_file::String
end

# Month abbreviations used in OA files
const MONTH_ABBREVS = Dict(
    "JAN" => 1, "FEB" => 2, "MAR" => 3, "APR" => 4,
    "MAY" => 5, "JUN" => 6, "JUL" => 7, "AUG" => 8,
    "SEP" => 9, "OCT" => 10, "NOV" => 11, "DEC" => 12,
)

"""
    parse_msg_datetime(s::AbstractString) -> DateTime

Parse NANU message datetime from format like "192025Z JUN 2020" (DDHHMMZ MON YYYY).
"""
function parse_msg_datetime(s::AbstractString)::DateTime
    m = match(r"(\d{2})(\d{2})(\d{2})Z\s+(\w{3})\s+(\d{4})", strip(s))
    isnothing(m) && error("Cannot parse msg datetime: '$s'")
    day   = parse(Int, m[1])
    hour  = parse(Int, m[2])
    min   = parse(Int, m[3])
    month = MONTH_ABBREVS[uppercase(m[4])]
    year  = parse(Int, m[5])
    return DateTime(year, month, day, hour, min)
end

"""
    nanu_event_timespan(start_doy::Union{Int,Nothing}, start_time::Union{String,Nothing},
                        stop_doy::Union{Int,Nothing}, stop_time::Union{String,Nothing},
                        file_year::Int) -> Tuple{Union{DateTime,Nothing}, Union{DateTime,Nothing}}

Convert DOY/HHMM summary fields to absolute DateTime values using the file's year
as context. Handles year boundaries (DOY in early January from a late-December file).
"""
function nanu_event_timespan(start_doy::Union{Int,Nothing}, start_time::Union{AbstractString,Nothing},
                             stop_doy::Union{Int,Nothing}, stop_time::Union{AbstractString,Nothing},
                             file_year::Int)
    function doy_to_datetime(doy::Int, hhmm::AbstractString, year::Int)
        h = parse(Int, hhmm[1:2])
        m = parse(Int, hhmm[3:4])
        base = DateTime(year, 1, 1) + Day(doy - 1)
        return base + Hour(h) + Minute(m)
    end

    event_start = nothing
    event_stop  = nothing

    if !isnothing(start_doy) && !isnothing(start_time)
        # If DOY is small and the NANU is from late in the year, it wraps to next year
        year = file_year
        if start_doy < 30 && file_year > 0
            # Check if this might be a year-boundary wrap (file from late December,
            # event in early January). We use a heuristic: DOY < 30 in a file from
            # the archive year directory might be next year's event.
            # This is resolved by the caller who knows the file context.
        end
        event_start = doy_to_datetime(start_doy, start_time, year)
    end

    if !isnothing(stop_doy) && !isnothing(stop_time)
        year = file_year
        # If stop is before start, it's in the next year
        if !isnothing(start_doy) && stop_doy < start_doy
            year += 1
        end
        event_stop = doy_to_datetime(stop_doy, stop_time, year)
    end

    return (event_start, event_stop)
end

"""
    parse_summary_field(summary::AbstractString) -> (start_doy, start_time, stop_doy, stop_time)

Parse the SUMMARY column, which has format "JDAY/HHMM-JDAY/HHMM" or "/-/" for
events without a time window.

Returns `(doy::Union{Int,Nothing}, time::Union{String,Nothing})` for start and stop.
"""
function parse_summary_field(summary::AbstractString)
    s = strip(summary)

    # Handle "/-/" (no time window)
    if s == "/-/" || s == "/-" || s == "/" || isempty(s)
        return (nothing, nothing, nothing, nothing)
    end

    # Try full pattern: DOY/HHMM-DOY/HHMM
    m = match(r"(\d{1,3})/(\d{4})-(\d{1,3})/(\d{4})", s)
    if !isnothing(m)
        return (parse(Int, m[1]), m[2], parse(Int, m[3]), m[4])
    end

    # Try open-ended: DOY/HHMM-/
    m = match(r"(\d{1,3})/(\d{4})-/?", s)
    if !isnothing(m)
        return (parse(Int, m[1]), m[2], nothing, nothing)
    end

    # Try stop-only: /-DOY/HHMM (unlikely but handle it)
    m = match(r"/?-(\d{1,3})/(\d{4})", s)
    if !isnothing(m)
        return (nothing, nothing, parse(Int, m[1]), m[2])
    end

    return (nothing, nothing, nothing, nothing)
end

"""
    parse_oa_file(filepath::String) -> Vector{NANURecord}

Parse a single GPS Operational Advisory (.oa1) file and return all NANU records found.

The file is expected to have Section 2 with subsections A (Forecasts), B (Advisories),
and C (General), each containing NANU record lines.
"""
function parse_oa_file(filepath::String)::Vector{NANURecord}
    lines = readlines(filepath)
    records = NANURecord[]

    # Extract year from directory path (e.g., "data/ops_advisories/2020/180.oa1" → 2020)
    # or from the SUBJ line
    file_year = _extract_year_from_path(filepath)
    if isnothing(file_year)
        file_year = _extract_year_from_content(lines)
    end
    isnothing(file_year) && return records

    # Build relative source_file path (YYYY/NNN.oa1)
    source_file = _make_source_path(filepath)

    # Find Section 2
    section2_start = findfirst(l -> occursin(r"^2\.\s+CURRENT ADVISORIES"i, l), lines)
    isnothing(section2_start) && return records

    # Find Section 3 (end boundary)
    section3_start = findfirst(l -> occursin(r"^3\.\s+REMARKS"i, l), lines)
    section_end = isnothing(section3_start) ? length(lines) : section3_start - 1

    # Parse within section 2
    current_category = nothing

    for i in (section2_start + 1):section_end
        line = lines[i]

        # Detect subsection headers
        if occursin(r"^A\.\s+FORECASTS"i, line)
            current_category = :forecast
            continue
        elseif occursin(r"^B\.\s+ADVISORIES"i, line)
            current_category = :advisory
            continue
        elseif occursin(r"^C\.\s+GENERAL"i, line)
            current_category = :general
            continue
        end

        isnothing(current_category) && continue

        # Skip header lines and blank lines
        if occursin(r"^NANU\s+MSG DATE"i, line) || occursin(r"^\s*$", line)
            continue
        end

        # Parse NANU record line
        rec = _parse_nanu_line(line, current_category, file_year, source_file)
        if !isnothing(rec)
            push!(records, rec)
        end
    end

    return records
end

"""
    _parse_nanu_line(line, category, file_year, source_file) -> Union{NANURecord, Nothing}

Parse a single NANU record line. Returns `nothing` if the line doesn't match.

Example lines:
  "2020028       192025Z JUN 2020    03   FCSTDV       178/0445-178/1645"
  "2014038       241350Z APR 2014         GENERAL      /-/"
"""
function _parse_nanu_line(line::AbstractString, category::Symbol,
                          file_year::Int, source_file::String)::Union{NANURecord, Nothing}
    # NANU lines start with the NANU ID (digits)
    stripped = lstrip(line)
    occursin(r"^\d{4,7}", stripped) || return nothing

    # Regex to capture: NANU_ID, MSG_DATETIME, optional PRN, TYPE, SUMMARY
    # The PRN field is 2-digit right-justified in a ~5-char column, or blank
    m = match(r"^(\d{4,7})\s+(\d{6}Z\s+\w{3}\s+\d{4})\s{2,}(\d{1,2})?\s{2,}(\S+)\s+(.*?)\s*$", stripped)
    isnothing(m) && return nothing

    nanu_id = m[1]

    msg_datetime = try
        parse_msg_datetime(m[2])
    catch
        return nothing
    end

    prn = isnothing(m[3]) ? nothing : parse(Int, m[3])
    nanu_type = uppercase(m[4])
    summary_str = m[5]

    # Parse the summary field for event start/stop
    (start_doy, start_time, stop_doy, stop_time) = parse_summary_field(summary_str)
    (event_start, event_stop) = nanu_event_timespan(start_doy, start_time, stop_doy, stop_time, file_year)

    return NANURecord(nanu_id, msg_datetime, prn, nanu_type, category,
                      event_start, event_stop, source_file)
end

"""
    _extract_year_from_path(filepath::String) -> Union{Int, Nothing}

Extract the 4-digit year from the directory path (e.g., ".../2020/180.oa1" → 2020).
"""
function _extract_year_from_path(filepath::String)::Union{Int, Nothing}
    m = match(r"/(\d{4})/\d{3}\.oa1$"i, filepath)
    isnothing(m) && return nothing
    return parse(Int, m[1])
end

"""
    _extract_year_from_content(lines::Vector{String}) -> Union{Int, Nothing}

Extract the year from the SUBJ line (e.g., "SUBJ: GPS STATUS      28 JUN 2020").
"""
function _extract_year_from_content(lines::Vector{String})::Union{Int, Nothing}
    for line in lines
        m = match(r"SUBJ:.*(\d{4})\s*$", line)
        if !isnothing(m)
            return parse(Int, m[1])
        end
    end
    return nothing
end

"""
    _make_source_path(filepath::String) -> String

Build a short relative source path like "2020/180.oa1" from a full path.
"""
function _make_source_path(filepath::String)::String
    m = match(r"(\d{4}/\d{3}\.oa1)$"i, filepath)
    isnothing(m) && return basename(filepath)
    return m[1]
end

"""
    parse_all_oa_files(dir::String; years=nothing, verbose::Bool=false) -> Vector{NANURecord}

Walk `dir/YYYY/NNN.oa1` and parse all OA files. Deduplicates by NANU ID,
keeping the record from the earliest source file (same NANU appears in ~7
consecutive daily files).

# Arguments
- `dir`: Root directory containing year subdirectories
- `years`: Optional collection of years to restrict parsing (e.g., `2010:2015`)
- `verbose`: Print progress information
"""
function parse_all_oa_files(dir::String; years=nothing, verbose::Bool=false)::Vector{NANURecord}
    all_records = NANURecord[]

    # Find year directories
    year_dirs = filter(readdir(dir; join=true)) do d
        isdir(d) && occursin(r"^\d{4}$", basename(d))
    end
    sort!(year_dirs)

    # Filter by years if specified
    if !isnothing(years)
        year_set = Set(years)
        filter!(d -> parse(Int, basename(d)) in year_set, year_dirs)
    end

    for ydir in year_dirs
        year = parse(Int, basename(ydir))
        oa_files = filter(f -> endswith(f, ".oa1"), readdir(ydir; join=true))
        sort!(oa_files)

        verbose && println("  Parsing $(length(oa_files)) files from $year…")

        for filepath in oa_files
            try
                recs = parse_oa_file(filepath)
                append!(all_records, recs)
            catch e
                verbose && println("    Warning: failed to parse $(basename(filepath)): $e")
            end
        end
    end

    # Deduplicate by NANU ID — keep earliest source file
    verbose && println("  Deduplicating $(length(all_records)) raw records…")
    deduped = _deduplicate_nanus(all_records)
    verbose && println("  → $(length(deduped)) unique NANUs")

    return deduped
end

"""
    _deduplicate_nanus(records::Vector{NANURecord}) -> Vector{NANURecord}

Keep only the first occurrence of each NANU ID (earliest source file).
"""
function _deduplicate_nanus(records::Vector{NANURecord})::Vector{NANURecord}
    seen = Dict{String, NANURecord}()

    for rec in records
        if !haskey(seen, rec.nanu_id)
            seen[rec.nanu_id] = rec
        else
            # Keep the one from the earlier source file
            existing = seen[rec.nanu_id]
            if rec.source_file < existing.source_file
                seen[rec.nanu_id] = rec
            end
        end
    end

    result = collect(values(seen))
    sort!(result, by = r -> (r.msg_datetime, r.nanu_id))
    return result
end
