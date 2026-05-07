#!/usr/bin/env julia
#
# Download GPS Ops Advisories from NAVCEN archives
#
# Files are published daily at:
#   https://navcen.uscg.gov/sites/default/files/gps/opsadvisory/YYYY/NNN.oa1
# where YYYY is the year and NNN is the zero-padded day-of-year (001–365/366).
# Archives are available from 2006 to the present.
#
# Uses Julia's built-in Downloads standard library — no external tools required.
#
# Usage:
#   julia download_ops_advisories.jl [output_dir] [options]
#
# Options:
#   --check          Check which files are missing or possibly truncated
#   --from=YEAR      Start year (default: 2007)
#   --to=YEAR        End year (default: current year)
#   output_dir       Directory to save files (default: data/ops_advisories)
#
# Examples:
#   julia download_ops_advisories.jl                         # download all missing files
#   julia download_ops_advisories.jl --check                 # report missing/truncated files
#   julia download_ops_advisories.jl data/oa --from=2020     # resume from 2020 into custom dir
#
# Resume behaviour: skips files that already exist and whose on-disk size matches
# the server Content-Length header.  Run again to resume an interrupted download.

using Dates
using Downloads

# ── Configuration ─────────────────────────────────────────────────────────────

const BASE_URL      = "https://navcen.uscg.gov/sites/default/files/gps/opsadvisory"
const FIRST_YEAR    = 2006          # earliest year available on the server
const MIN_FILE_SIZE = 500           # bytes — anything smaller is suspect
const TIMEOUT_SECS  = 60.0          # per-request timeout
const MAX_RETRIES   = 3

# ── Helpers ───────────────────────────────────────────────────────────────────

"""Return true if `year` is a leap year."""
is_leap(year::Int) = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0

"""Number of days in `year`."""
days_in_year(year::Int) = is_leap(year) ? 366 : 365

"""Local file path for a given year and day-of-year."""
function local_path(output_dir::String, year::Int, doy::Int)
    joinpath(output_dir, string(year), lpad(doy, 3, '0') * ".oa1")
end

"""Remote URL for a given year and day-of-year."""
remote_url(year::Int, doy::Int) =
    "$BASE_URL/$year/$(lpad(doy, 3, '0')).oa1"

"""Return (current_year, current_doy) based on local date."""
function today_doy()
    d = today()
    (year(d), dayofyear(d))
end

"""
    content_length_from_headers(headers) -> Union{Int,Nothing}

Extract Content-Length value from a vector of header pairs.
"""
function content_length_from_headers(headers)
    for (k, v) in headers
        lowercase(k) == "content-length" || continue
        n = tryparse(Int, strip(v))
        n !== nothing && return n
    end
    return nothing
end

"""
    head_content_length(url) -> Union{Int,Nothing}

Issue a HEAD request and return Content-Length, or `nothing` on any error.
"""
function head_content_length(url::String)
    try
        resp = Downloads.request(url; method="HEAD", timeout=TIMEOUT_SECS)
        resp.status == 200 || return nothing
        return content_length_from_headers(resp.headers)
    catch
        return nothing
    end
end

"""
    download_file(url, dest) -> (success::Bool, bytes::Int, message::String)

Download `url` to `dest`, writing via a `.part` temporary file for atomicity.
Retries up to MAX_RETRIES times on transient errors.  Returns success flag,
bytes written, and a status message.
"""
function download_file(url::String, dest::String)
    mkpath(dirname(dest))
    tmp = dest * ".part"

    for attempt in 1:MAX_RETRIES
        try
            open(tmp, "w") do io
                Downloads.download(url, io; timeout=TIMEOUT_SECS)
            end
        catch e
            isfile(tmp) && rm(tmp)
            if e isa Downloads.RequestError && e.response.status == 404
                return (false, 0, "404 not found")
            end
            if attempt < MAX_RETRIES
                sleep(2.0)
                continue
            end
            return (false, 0, "error after $MAX_RETRIES attempts: $e")
        end

        !isfile(tmp) && return (false, 0, "output file not created")

        sz = filesize(tmp)
        if sz < MIN_FILE_SIZE
            rm(tmp)
            if attempt < MAX_RETRIES
                sleep(2.0)
                continue
            end
            return (false, 0, "file too small ($sz bytes) — likely an error page")
        end

        # Atomic rename on success
        mv(tmp, dest; force=true)
        return (true, sz, "ok")
    end

    return (false, 0, "failed after $MAX_RETRIES attempts")
end

# ── Core logic ────────────────────────────────────────────────────────────────

"""
    download_missing(output_dir, years; verbose=true)

Download all files that are absent or appear truncated.  Skips files that exist
and are at least MIN_FILE_SIZE bytes.  Prints progress to stdout.
"""
function download_missing(output_dir::String, years::UnitRange{Int}; verbose::Bool=true)
    (cur_year, cur_doy) = today_doy()
    n_ok = 0; n_skip = 0; n_fail = 0; n_total = 0

    for year in years
        n_days = days_in_year(year)
        for doy in 1:n_days
            year == cur_year && doy > cur_doy && break
            n_total += 1
            path = local_path(output_dir, year, doy)

            if isfile(path) && filesize(path) >= MIN_FILE_SIZE
                n_skip += 1
                continue
            end

            url = remote_url(year, doy)
            tag = "$(year)/$(lpad(doy, 3, '0'))"
            verbose && print("  Downloading $tag … ")

            ok, sz, msg = download_file(url, path)
            if ok
                n_ok += 1
                verbose && println("$sz bytes")
            else
                n_fail += 1
                verbose && println("FAILED: $msg")
            end
        end
    end

    println("\nDone: $n_ok downloaded, $n_skip already present, $n_fail failed " *
            "(of $n_total total dates)")
end

"""
    run_check(output_dir, years)

Print a report of missing and possibly-truncated files.  Only issues network
requests for files that are present but suspiciously small.
"""
function run_check(output_dir::String, years::UnitRange{Int})
    println("Checking files in $output_dir for years $(first(years))–$(last(years)) …")
    (cur_year, cur_doy) = today_doy()

    missing_files   = Tuple{Int,Int}[]
    truncated_files = Tuple{Int,Int,Int,Union{Int,Nothing}}[]   # year, doy, local_sz, server_sz
    n_ok = 0

    for year in years
        n_days = days_in_year(year)
        for doy in 1:n_days
            year == cur_year && doy > cur_doy && break
            path = local_path(output_dir, year, doy)
            if !isfile(path)
                push!(missing_files, (year, doy))
            else
                sz = filesize(path)
                if sz < MIN_FILE_SIZE
                    server_sz = head_content_length(remote_url(year, doy))
                    push!(truncated_files, (year, doy, sz, server_sz))
                else
                    n_ok += 1
                end
            end
        end
    end

    println("\n✓ Complete files: $n_ok")

    if isempty(missing_files)
        println("✓ No missing files")
    else
        println("✗ Missing files ($(length(missing_files))):")
        for (y, d) in missing_files
            println("    $(y)/$(lpad(d, 3, '0')).oa1  →  $(remote_url(y, d))")
        end
    end

    if isempty(truncated_files)
        println("✓ No truncated files")
    else
        println("✗ Possibly truncated files ($(length(truncated_files))):")
        for (y, d, local_sz, server_sz) in truncated_files
            server_str = server_sz === nothing ? "unknown server size" : "$(server_sz) bytes on server"
            println("    $(y)/$(lpad(d, 3, '0')).oa1  →  $(local_sz) bytes locally, $server_str")
        end
    end
end

# ── Argument parsing ──────────────────────────────────────────────────────────

function parse_args(args)
    output_dir = "data/ops_advisories"
    from_year  = 2007
    to_year    = year(today())
    check_mode = false

    positional = String[]
    for arg in args
        if arg == "--check"
            check_mode = true
        elseif startswith(arg, "--from=")
            from_year = parse(Int, arg[8:end])
        elseif startswith(arg, "--to=")
            to_year = parse(Int, arg[6:end])
        elseif !startswith(arg, "--")
            push!(positional, arg)
        else
            println(stderr, "Unknown option: $arg")
            exit(1)
        end
    end

    !isempty(positional) && (output_dir = positional[1])

    from_year < FIRST_YEAR && (from_year = FIRST_YEAR)
    to_year   > year(today()) && (to_year = year(today()))
    from_year > to_year && error("--from year ($from_year) is after --to year ($to_year)")

    (output_dir, from_year:to_year, check_mode)
end

# ── Entry point ───────────────────────────────────────────────────────────────

function main(args=ARGS)
    output_dir, years, check_mode = parse_args(args)

    if check_mode
        run_check(output_dir, years)
    else
        println("Downloading GPS Ops Advisories to: $output_dir")
        println("Year range: $(first(years))–$(last(years))")
        println("(Files already present and ≥ $MIN_FILE_SIZE bytes will be skipped)\n")
        download_missing(output_dir, years)
    end
end

main()
