#!/usr/bin/env julia
#
# Extract GPS raw tar files organized by year
#
# Extracts all tar files from raw_dir into processed_dir.
# Assumes raw_dir contains year directories (e.g., y2007) which contain .tar files.
# Extracts each .tar file into a subdirectory of the same name in processed_dir/year/.
# Also gunzips any .gz files found after extraction.
#
# Uses tar/gzip if available, falls back to 7zip (7zz) if not.
#
# Usage:
#   julia decompress_data.jl [options]
#
# Options:
#   --raw=DIR     Input raw directory containing year folders (default: data/raw)
#   --out=DIR     Output directory for extracted files (default: data/processed)
#   --dry-run     Simulate extraction without making changes

"""
Check if a command is available on the system.
Uses Julia's built-in Sys.which() for cross-platform compatibility.
"""
function command_available(cmd::String)::Bool
    return Sys.which(cmd) !== nothing
end

# Detect available tools at module load time
const HAS_TAR = command_available("tar")
const HAS_GZIP = command_available("gzip")
const HAS_7ZIP = command_available("7zz")

"""
Parse command line arguments.
"""
function parse_args(args)
    raw_dir = "data/raw"
    out_dir = "data/processed"
    dry_run = false

    for arg in args
        if arg == "--dry-run"
            dry_run = true
        elseif startswith(arg, "--raw=")
            raw_dir = arg[7:end]
        elseif startswith(arg, "--out=")
            out_dir = arg[7:end]
        elseif !startswith(arg, "-")
            # Positional arguments: first is raw, second is out
            if raw_dir == "data/raw"
                raw_dir = arg
            else
                out_dir = arg
            end
        end
    end

    return (raw_dir=raw_dir, out_dir=out_dir, dry_run=dry_run)
end

"""
List contents of a tar file (for dry-run mode).
"""
function list_tar_contents(tar_path::String)
    if HAS_TAR
        output = read(`tar -tf $tar_path`, String)
    elseif HAS_7ZIP
        # 7zz lists with extra info, extract just filenames
        output = read(`7zz l -ba $tar_path`, String)
        # -ba gives bare format: size date time attr name
        # Extract just the last column (filename)
        lines = split(output, '\n')
        names = String[]
        for line in lines
            parts = split(strip(line))
            if length(parts) >= 5
                push!(names, parts[end])
            end
        end
        return filter(!isempty, names)
    else
        error("No tar or 7zz available to list archive contents")
    end
    return filter(!isempty, split(output, '\n'))
end

"""
Extract a tar file to the specified directory.
"""
function extract_tar(tar_path::String, output_dir::String)
    mkpath(output_dir)
    if HAS_TAR
        run(`tar -xf $tar_path -C $output_dir`)
    elseif HAS_7ZIP
        run(`7zz x $tar_path -o$output_dir -y`)
    else
        error("No tar or 7zz available to extract archive")
    end
end

"""
Decompress a single .gz file, removing the original.
"""
function gunzip_file(gz_path::String)
    if HAS_GZIP
        run(`gzip -d $gz_path`)
    elseif HAS_7ZIP
        # 7zz extracts to same directory, then we remove the .gz
        dir = dirname(gz_path)
        run(`7zz x $gz_path -o$dir -y`)
        rm(gz_path)
    else
        error("No gzip or 7zz available to decompress file")
    end
end

"""
Recursively find and gunzip all .gz files in a directory.
"""
function gunzip_all(dir::String)
    for (root, _, files) in walkdir(dir)
        for file in files
            if endswith(file, ".gz")
                gz_path = joinpath(root, file)
                try
                    gunzip_file(gz_path)
                catch e
                    println(stderr, "  Failed to gunzip $file: $e")
                end
            end
        end
    end
end

"""
Extract all tar files from raw_dir into processed_dir.
"""
function extract_tars(raw_dir::String, processed_dir::String; dry_run::Bool=false)
    # Check tool availability
    if !HAS_TAR && !HAS_7ZIP
        println(stderr, "Error: Neither tar nor 7zz is available. Please install one of them.")
        return
    end
    if !HAS_GZIP && !HAS_7ZIP
        println(stderr, "Error: Neither gzip nor 7zz is available. Please install one of them.")
        return
    end

    # Report which tools will be used
    tar_tool = HAS_TAR ? "tar" : "7zz"
    gzip_tool = HAS_GZIP ? "gzip" : "7zz"
    println("Using $tar_tool for tar extraction, $gzip_tool for gzip decompression")

    if !isdir(raw_dir)
        println(stderr, "Error: Raw directory '$raw_dir' does not exist.")
        return
    end

    # Iterate through year directories
    for year_entry in sort(readdir(raw_dir))
        year_dir = joinpath(raw_dir, year_entry)

        if !isdir(year_dir)
            continue
        end

        # Find tar files in year directory
        tar_files = filter(f -> endswith(f, ".tar"), readdir(year_dir))

        if isempty(tar_files)
            continue
        end

        println("Processing $year_entry ($(length(tar_files)) files)...")

        for tar_name in tar_files
            tar_path = joinpath(year_dir, tar_name)

            # Output directory: processed/year/tar_filename_no_ext
            tar_stem = tar_name[1:end-4]  # Remove .tar extension
            output_subdir = joinpath(processed_dir, year_entry, tar_stem)

            if isdir(output_subdir)
                println("  Skipping $tar_name (already extracted)")
                continue
            end

            if dry_run
                println("  [DRY RUN] Would create directory $output_subdir")
                println("  [DRY RUN] Would extract $tar_name to $output_subdir")

                # List tar contents
                try
                    contents = list_tar_contents(tar_path)
                    for name in contents
                        println("    [DRY RUN] Would extract: $name")
                        if endswith(name, ".gz")
                            println("    [DRY RUN] Would gunzip: $name -> $(name[1:end-3])")
                        end
                    end
                catch e
                    println(stderr, "  Failed to list $tar_name: $e")
                end
            else
                println("  Extracting $tar_name to $output_subdir")

                try
                    extract_tar(tar_path, output_subdir)
                    gunzip_all(output_subdir)
                catch e
                    println(stderr, "  Failed to extract $tar_name: $e")
                end
            end
        end
    end
end

# Main entry point
if abspath(PROGRAM_FILE) == @__FILE__
    opts = parse_args(ARGS)
    extract_tars(opts.raw_dir, opts.out_dir; dry_run=opts.dry_run)
end
