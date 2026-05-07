#!/usr/bin/env julia
#
# Download GPS NAVBIT data from GFZ ISDC archive
#
# Usage:
#   julia download_navbit_data.jl [output_dir] [options]
#
# Arguments:
#   output_dir    - Directory to save files (default: data/raw)
#
# Options:
#   --dry-run     - List files without downloading
#   --verify      - Verify existing files against expected sizes
#   --overwrite   - Re-download files even if they exist
#   --year=YYYY   - Only download specific year(s), comma-separated
#
# Examples:
#   julia download_navbit_data.jl
#   julia download_navbit_data.jl data/raw --dry-run
#   julia download_navbit_data.jl data/raw --year=2024
#   julia download_navbit_data.jl data/raw --year=2023,2024
#   julia download_navbit_data.jl data/raw --verify
#   julia download_navbit_data.jl data/raw --overwrite

using Downloads
using Dates

const BASE_URL = "https://isdc-data.gfz.de/gnss/GNSS-GPS-1-NAVBIT/"

"""
Parse command line arguments.
"""
function parse_args(args)
    output_dir = "data/raw"
    dry_run = false
    verify_only = false
    overwrite = false
    years = nothing

    for arg in args
        if arg == "--dry-run"
            dry_run = true
        elseif arg == "--verify"
            verify_only = true
        elseif arg == "--overwrite"
            overwrite = true
        elseif startswith(arg, "--year=")
            year_str = arg[8:end]
            years = Set(parse.(Int, split(year_str, ",")))
        elseif !startswith(arg, "-")
            output_dir = arg
        end
    end

    return (output_dir=output_dir, dry_run=dry_run, verify_only=verify_only,
            overwrite=overwrite, years=years)
end

"""
Fetch HTML content from a URL.
"""
function fetch_html(url::String)::String
    io = IOBuffer()
    try
        Downloads.download(url, io)
        return String(take!(io))
    catch e
        @error "Failed to fetch $url" exception=e
        return ""
    end
end

"""
File info from directory listing.
"""
struct FileInfo
    name::String
    href::String
    size::Union{Int,Nothing}  # Expected size in bytes, nothing if unknown
end

"""
Parse size string from Apache directory listing (e.g., "1.2M", "456K", "789").
Returns size in bytes or nothing if unparseable.
"""
function parse_size_string(size_str::AbstractString)::Union{Int,Nothing}
    size_str = strip(size_str)

    if isempty(size_str) || size_str == "-"
        return nothing
    end

    # Try to parse with suffix
    m = match(r"^([\d.]+)([KMGT]?)$"i, size_str)
    if m === nothing
        return nothing
    end

    value = tryparse(Float64, m.captures[1])
    if value === nothing
        return nothing
    end

    suffix = uppercase(something(m.captures[2], ""))

    multiplier = if suffix == "K"
        1024
    elseif suffix == "M"
        1024^2
    elseif suffix == "G"
        1024^3
    elseif suffix == "T"
        1024^4
    else
        1
    end

    return round(Int, value * multiplier)
end

"""
Extract href links and file sizes from HTML directory listing.
Returns vector of FileInfo.
"""
function parse_directory_listing(html::String)::Vector{FileInfo}
    files = FileInfo[]

    # Apache directory listing format:
    # <tr><td>...</td><td><a href="file.tar">file.tar</a></td><td>...</td><td>1.2M</td><td>...</td></tr>
    # Or simpler format with just links and sizes on same line

    # First, try to extract file info with sizes from table rows
    # Pattern matches: href, name, and looks for size nearby
    for m in eachmatch(r"<a\s+href=\"([^\"]+)\"[^>]*>([^<]*)</a>.*?</td>\s*<td[^>]*>\s*([\d.]+[KMGT]?|-)\s*</td>"is, html)
        href = m.captures[1]
        name = strip(m.captures[2])
        size_str = m.captures[3]

        # Skip parent directory and sorting links
        if href in ["../", "?C=N;O=D", "?C=M;O=A", "?C=S;O=A", "?C=D;O=A"]
            continue
        end

        # Clean up name (remove trailing /)
        name = rstrip(name, '/')
        size = parse_size_string(size_str)

        push!(files, FileInfo(name, href, size))
    end

    # If table parsing didn't work, fall back to just extracting links
    if isempty(files)
        for m in eachmatch(r"<a\s+href=\"([^\"]+)\"[^>]*>([^<]*)</a>"i, html)
            href = m.captures[1]
            name = strip(m.captures[2])

            if href in ["../", "?C=N;O=D", "?C=M;O=A", "?C=S;O=A", "?C=D;O=A"]
                continue
            end

            name = rstrip(name, '/')
            push!(files, FileInfo(name, href, nothing))
        end
    end

    return files
end

"""
Get list of year directories (starting with 'y').
"""
function get_year_directories(base_url::String; years::Union{Nothing,Set{Int}}=nothing)::Vector{String}
    println("Fetching directory listing from $base_url")
    html = fetch_html(base_url)

    if isempty(html)
        return String[]
    end

    entries = parse_directory_listing(html)
    year_dirs = String[]

    for entry in entries
        # Match directories starting with 'y' followed by 4 digits
        if startswith(entry.name, "y") && length(entry.name) >= 5
            year_str = entry.name[2:5]
            if all(isdigit, year_str)
                year = parse(Int, year_str)
                if years === nothing || year in years
                    push!(year_dirs, entry.href)
                end
            end
        end
    end

    sort!(year_dirs)
    return year_dirs
end

"""
Get list of files in a directory with their expected sizes.
"""
function get_files_in_directory(url::String)::Vector{FileInfo}
    html = fetch_html(url)

    if isempty(html)
        return FileInfo[]
    end

    entries = parse_directory_listing(html)

    # Filter to only files (not directories - those end with /)
    files = [entry for entry in entries if !endswith(entry.href, "/")]

    return files
end

"""
Result of a download/verify operation.
"""
@enum DownloadResult begin
    DOWNLOAD_OK
    DOWNLOAD_SKIPPED
    DOWNLOAD_FAILED
    DOWNLOAD_SIZE_MISMATCH
end

"""
Download a file with progress indication and optional size verification.
Returns (result, actual_size, expected_size).
"""
function download_file(url::String, dest_path::String;
                       expected_size::Union{Int,Nothing}=nothing,
                       overwrite::Bool=false)::Tuple{DownloadResult,Int,Union{Int,Nothing}}
    if isfile(dest_path) && !overwrite
        actual_size = filesize(dest_path)

        # Verify existing file size if we have expected size
        if expected_size !== nothing
            # Allow 10% tolerance for size estimates from directory listing
            tolerance = max(1024, round(Int, expected_size * 0.1))
            if abs(actual_size - expected_size) > tolerance
                println("  SIZE MISMATCH (exists): $(basename(dest_path)) - got $(format_size(actual_size)), expected ~$(format_size(expected_size))")
                return (DOWNLOAD_SIZE_MISMATCH, actual_size, expected_size)
            end
        end

        println("  Skipping (exists, verified): $(basename(dest_path))")
        return (DOWNLOAD_SKIPPED, actual_size, expected_size)
    end

    # Ensure directory exists
    mkpath(dirname(dest_path))

    try
        print("  Downloading: $(basename(dest_path))... ")
        Downloads.download(url, dest_path)
        actual_size = filesize(dest_path)

        # Verify downloaded file size
        if expected_size !== nothing
            tolerance = max(1024, round(Int, expected_size * 0.1))
            if abs(actual_size - expected_size) > tolerance
                println("SIZE MISMATCH - got $(format_size(actual_size)), expected ~$(format_size(expected_size))")
                return (DOWNLOAD_SIZE_MISMATCH, actual_size, expected_size)
            end
        end

        println("done ($(format_size(actual_size)))")
        return (DOWNLOAD_OK, actual_size, expected_size)
    catch e
        println("FAILED")
        @error "Failed to download $url" exception=e
        return (DOWNLOAD_FAILED, 0, expected_size)
    end
end

"""
Verify a previously downloaded file against expected size.
"""
function verify_file(path::String, expected_size::Union{Int,Nothing})::Tuple{Bool,Int}
    if !isfile(path)
        return (false, 0)
    end

    actual_size = filesize(path)

    if expected_size === nothing
        return (true, actual_size)
    end

    # Allow 10% tolerance
    tolerance = max(1024, round(Int, expected_size * 0.1))
    ok = abs(actual_size - expected_size) <= tolerance

    return (ok, actual_size)
end

"""
Format file size for display.
"""
function format_size(bytes::Int)::String
    if bytes < 1024
        return "$bytes B"
    elseif bytes < 1024^2
        return "$(round(bytes/1024, digits=1)) KB"
    elseif bytes < 1024^3
        return "$(round(bytes/1024^2, digits=1)) MB"
    else
        return "$(round(bytes/1024^3, digits=2)) GB"
    end
end

"""
Main download function.
"""
function download_navbit_data(; output_dir::String="data/raw",
                               dry_run::Bool=false,
                               verify_only::Bool=false,
                               overwrite::Bool=false,
                               years::Union{Nothing,Set{Int}}=nothing)
    println("=" ^ 60)
    println("GPS NAVBIT Data Downloader")
    println("=" ^ 60)
    println("Base URL: $BASE_URL")
    println("Output directory: $output_dir")
    println("Mode: $(dry_run ? "dry-run" : verify_only ? "verify" : "download")")
    println("Overwrite: $overwrite")
    if years !== nothing
        println("Years filter: $(sort(collect(years)))")
    end
    println()

    # Get year directories
    year_dirs = get_year_directories(BASE_URL; years=years)

    if isempty(year_dirs)
        println("No year directories found!")
        return
    end

    println("Found $(length(year_dirs)) year directories:")
    for yd in year_dirs
        println("  - $yd")
    end
    println()

    total_files = 0
    downloaded_files = 0
    skipped_files = 0
    failed_files = 0
    size_mismatch_files = 0
    size_mismatches = Tuple{String,Int,Int}[]  # (path, actual, expected)

    for year_dir in year_dirs
        year_url = BASE_URL * year_dir
        year_name = rstrip(year_dir, '/')

        println("\n" * "-" ^ 40)
        println("Processing: $year_name")
        println("-" ^ 40)

        # Get files in year directory
        files = get_files_in_directory(year_url)

        if isempty(files)
            println("  No files found")
            continue
        end

        println("  Found $(length(files)) files")
        total_files += length(files)

        # Create output directory for this year
        year_output_dir = joinpath(output_dir, year_name)

        if dry_run
            for file_info in files
                size_str = file_info.size !== nothing ? " (~$(format_size(file_info.size)))" : ""
                println("  [DRY RUN] Would download: $(file_info.name)$size_str")
            end
        elseif verify_only
            # Verify mode: check existing files against expected sizes
            for file_info in files
                dest_path = joinpath(year_output_dir, file_info.name)

                if !isfile(dest_path)
                    println("  MISSING: $(file_info.name)")
                    failed_files += 1
                else
                    ok, actual_size = verify_file(dest_path, file_info.size)
                    if ok
                        println("  OK: $(file_info.name) ($(format_size(actual_size)))")
                        skipped_files += 1
                    else
                        expected = something(file_info.size, 0)
                        println("  SIZE MISMATCH: $(file_info.name) - got $(format_size(actual_size)), expected ~$(format_size(expected))")
                        size_mismatch_files += 1
                        push!(size_mismatches, (dest_path, actual_size, expected))
                    end
                end
            end
        else
            mkpath(year_output_dir)

            for file_info in files
                file_url = year_url * file_info.href
                dest_path = joinpath(year_output_dir, file_info.name)

                result, actual_size, expected_size = download_file(
                    file_url, dest_path;
                    expected_size=file_info.size,
                    overwrite=overwrite
                )

                if result == DOWNLOAD_OK
                    downloaded_files += 1
                elseif result == DOWNLOAD_SKIPPED
                    skipped_files += 1
                elseif result == DOWNLOAD_FAILED
                    failed_files += 1
                elseif result == DOWNLOAD_SIZE_MISMATCH
                    size_mismatch_files += 1
                    push!(size_mismatches, (dest_path, actual_size, something(expected_size, 0)))
                end
            end
        end
    end

    # Summary
    println("\n" * "=" ^ 60)
    println("Summary")
    println("=" ^ 60)
    println("Total files found: $total_files")
    if !dry_run
        println("Downloaded: $downloaded_files")
        println("Skipped (verified): $skipped_files")
        println("Failed: $failed_files")
        println("Size mismatches: $size_mismatch_files")

        # Report size mismatches
        if !isempty(size_mismatches)
            println("\n⚠️  Files with size mismatches:")
            for (path, actual, expected) in size_mismatches
                println("  - $(basename(path)): $(format_size(actual)) (expected ~$(format_size(expected)))")
            end
            println("\nThese files may be corrupted or incomplete. Consider re-downloading with --overwrite")
        end

        # Calculate total size
        if downloaded_files > 0 || skipped_files > 0
            total_size = 0
            for (root, _, filenames) in walkdir(output_dir)
                for f in filenames
                    total_size += filesize(joinpath(root, f))
                end
            end
            println("\nTotal size on disk: $(format_size(total_size))")
        end

        # Return success status
        if failed_files > 0 || size_mismatch_files > 0
            println("\n❌ Some downloads failed or have size mismatches")
            return false
        else
            println("\n✓ All downloads completed successfully")
            return true
        end
    end

    return true
end

# Main entry point
if abspath(PROGRAM_FILE) == @__FILE__
    opts = parse_args(ARGS)
    success = download_navbit_data(;
        output_dir=opts.output_dir,
        dry_run=opts.dry_run,
        verify_only=opts.verify_only,
        overwrite=opts.overwrite,
        years=opts.years
    )
    exit(success ? 0 : 1)
end
