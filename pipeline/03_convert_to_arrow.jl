using NCDatasets
using Arrow
using DataFrames
using JSON3
using Logging

"""
Convert a NetCDF file to Arrow format, preserving all data and metadata.

The Arrow file contains:
- All variables as columns (2D arrays are flattened with one row per time index)
- Variable attributes stored in Arrow metadata as JSON
- Global attributes stored in Arrow metadata as JSON
"""
function nc_to_arrow(nc_path::String, arrow_path::String)
    # Suppress NCDatasets warnings about non-standard time units
    Logging.with_logger(Logging.SimpleLogger(stderr, Logging.Error)) do
        NCDataset(nc_path, "r") do ds
            _nc_to_arrow_inner(ds, nc_path, arrow_path)
        end
    end
end

function _nc_to_arrow_inner(ds, nc_path::String, arrow_path::String)
    # Extract dimensions - in NCDatasets, navbits is (time, gps_word)
    n_time = ds.dim["time"]
    n_words = ds.dim["gps_word"]

    # Get actual number of valid subframes (use full dimension, nofsfr is informational)
    nofsfr = Int(ds["nofsfr"].var[1])

    # Build DataFrame with one row per subframe
    df = DataFrame()

    # Time variable (1D, indexed by time)
    # Suppress time unit parsing warning for non-standard "seconds since midnight GPS time"
    df.time = Logging.with_logger(Logging.SimpleLogger(stderr, Logging.Error)) do
        Vector{Int32}(ds["time"].var[:])
    end

    # Multiplicity (1D, indexed by time)
    df.multiplicity = Vector{Int32}(ds["multiplicity"].var[:])

    # Navbits - 2D array, shape is (time, gps_word) in NCDatasets
    navbits = Array{Int32}(ds["navbits"].var[:, :])  # (n_time, n_words)
    n_rows = size(navbits, 1)
    packed_navbits = Vector{Vector{UInt8}}(undef, n_rows)

    # Pack 10 words (30 bits each) into 300 bits
    # GPS bits 1..30 correspond to bit positions 29..0
    for i in 1:n_rows
        bytes = zeros(UInt8, 38)
        bit_cursor = 0
        for w_idx in 1:n_words
            w = navbits[i, w_idx]
            for b_idx in 29:-1:0
                if (w >> b_idx) & 1 == 1
                    byte_pos = (bit_cursor >>> 3) + 1
                    bit_in_byte = 7 - (bit_cursor & 7)
                    bytes[byte_pos] |= (1 << bit_in_byte)
                end
                bit_cursor += 1
            end
        end
        packed_navbits[i] = bytes
    end
    df.navbits = packed_navbits

    # GPS word indices (static, but include for completeness)
    gps_word_values = Vector{Int16}(ds["gps_word"].var[:])

    # Collect all metadata
    metadata = Dict{String, Any}()

    # Global attributes
    global_attrs = Dict{String, Any}()
    for attr_name in keys(ds.attrib)
        global_attrs[attr_name] = ds.attrib[attr_name]
    end
    metadata["global_attributes"] = global_attrs

    # Variable attributes
    var_attrs = Dict{String, Any}()
    for var_name in keys(ds)
        attrs = Dict{String, Any}()
        raw_var = ds[var_name].var
        for attr_name in keys(raw_var.attrib)
            attrs[attr_name] = raw_var.attrib[attr_name]
        end
        if !isempty(attrs)
            var_attrs[var_name] = attrs
        end
    end
    metadata["variable_attributes"] = var_attrs

    # Scalar variables - store in metadata as they are constant for the file
    # Use defaults if missing to ensure robustness
    metadata["version"] = haskey(ds, "version") ? Int(ds["version"].var[1]) : 0
    metadata["year"] = haskey(ds, "year") ? Int(ds["year"].var[1]) : 0
    metadata["day_of_year"] = haskey(ds, "day_of_year") ? Int(ds["day_of_year"].var[1]) : 0
    metadata["prn"] = haskey(ds, "prn") ? Int(ds["prn"].var[1]) : 0
    metadata["gps_week"] = haskey(ds, "gps_week") ? Int(ds["gps_week"].var[1]) : 0

    # Dimension info
    metadata["dimensions"] = Dict(
        "gps_word" => n_words,
        "time" => n_time,
        "nofsfr" => nofsfr
    )

    # GPS word mapping (for reconstructing the 2D navbits array)
    metadata["gps_word_indices"] = gps_word_values

    # Store source file info
    metadata["source_file"] = basename(nc_path)

    n_time = nrow(df)

    # Convert metadata to JSON string for Arrow
    metadata_json = JSON3.write(metadata)

    # Write Arrow file with metadata and compression
    Arrow.write(
        arrow_path,
        df;
        compress = :zstd,
        metadata = ["netcdf_metadata" => metadata_json]
    )

    return n_time
end

"""
Recursively find all .nc files in a directory and its subdirectories.
Returns a vector of tuples (full_path, relative_path).
"""
function find_nc_files_recursive(root_dir::String)
    nc_files = Tuple{String, String}[]

    function walk_dir(current_dir::String, rel_path::String="")
        for entry in readdir(current_dir)
            full_path = joinpath(current_dir, entry)
            entry_rel_path = isempty(rel_path) ? entry : joinpath(rel_path, entry)

            if isdir(full_path)
                walk_dir(full_path, entry_rel_path)
            elseif endswith(entry, ".nc")
                push!(nc_files, (full_path, entry_rel_path))
            end
        end
    end

    walk_dir(root_dir)
    return nc_files
end

"""
Convert all NetCDF files in a directory (recursively) to Arrow format.
Preserves the directory structure in the output directory.
Files are processed in parallel across threads (use `julia -t auto` for all cores).
"""
function convert_directory(input_dir::String, output_dir::String; verbose::Bool=true)
    mkpath(output_dir)

    # Recursively find all .nc files
    nc_files = find_nc_files_recursive(input_dir)

    if isempty(nc_files)
        @warn "No .nc files found in $input_dir (searched recursively)"
        return
    end

    n_files = length(nc_files)
    verbose && println("Found $n_files NetCDF files to convert (searched recursively)")
    verbose && println("Using $(Threads.nthreads()) threads")

    # Build work items and pre-create all output directories before threading
    work_items = Vector{Tuple{String, String, String}}(undef, n_files)
    for (i, (nc_path, rel_path)) in enumerate(nc_files)
        arrow_rel_path = replace(rel_path, ".nc" => ".arrow")
        arrow_path = joinpath(output_dir, arrow_rel_path)
        mkpath(dirname(arrow_path))
        work_items[i] = (nc_path, arrow_path, rel_path)
    end

    total_subframes = Threads.Atomic{Int}(0)
    completed = Threads.Atomic{Int}(0)
    failed = Threads.Atomic{Int}(0)
    print_lock = ReentrantLock()

    Threads.@threads for (nc_path, arrow_path, rel_path) in work_items
        try
            n_subframes = nc_to_arrow(nc_path, arrow_path)
            Threads.atomic_add!(total_subframes, n_subframes)
            c = Threads.atomic_add!(completed, 1) + 1
            if verbose
                lock(print_lock) do
                    println("[$c/$n_files] Converted $rel_path ($n_subframes subframes)")
                end
            end
        catch e
            Threads.atomic_add!(failed, 1)
            lock(print_lock) do
                @error "Failed to convert $rel_path" exception=(e, catch_backtrace())
            end
        end
    end

    verbose && println("\nConversion complete: $(completed[]) files converted, $(failed[]) failed, $(total_subframes[]) total subframes")
end

"""
Read an Arrow file and reconstruct the original data structure.
"""
function read_arrow_with_metadata(arrow_path::String)
    tbl = Arrow.Table(arrow_path)
    df = DataFrame(tbl)

    # Extract metadata
    meta = Arrow.getmetadata(tbl)
    if haskey(meta, "netcdf_metadata")
        metadata = JSON3.read(meta["netcdf_metadata"], Dict{String, Any})
    else
        metadata = nothing
    end

    return df, metadata
end

"""
Reconstruct the 2D navbits array from the packed binary column.
"""
function reconstruct_navbits(df::DataFrame)
    n_time = nrow(df)
    navbits = Matrix{Int32}(undef, 10, n_time)
    packed_col = df.navbits

    Threads.@threads for i in 1:n_time
        bytes = packed_col[i]
        bit_cursor = 0
        for w_idx in 1:10
            w = Int32(0)
            for b_idx in 29:-1:0
                byte_pos = (bit_cursor >>> 3) + 1
                bit_in_byte = 7 - (bit_cursor & 7)
                if (bytes[byte_pos] >> bit_in_byte) & 1 == 1
                    w |= (1 << b_idx)
                end
                bit_cursor += 1
            end
            navbits[w_idx, i] = w
        end
    end
    return navbits
end

# Main entry point
if abspath(PROGRAM_FILE) == @__FILE__
    input_dir = get(ARGS, 1, "data/processed")
    output_dir = get(ARGS, 2, "data/arrow")

    println("Converting NetCDF files from '$input_dir' to Arrow format in '$output_dir'")
    convert_directory(input_dir, output_dir)
end
