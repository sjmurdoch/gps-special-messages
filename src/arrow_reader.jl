# Arrow file reading utilities for GPS navigation data

using Arrow
using JSON3
using Tables

"""
    FileMetadata

Metadata extracted from an Arrow file containing GPS navigation data.
"""
struct FileMetadata
    year::Int
    day_of_year::Int
    prn::Int
    gps_week::Int
    source_file::String
end

"""
    read_arrow_navbits(path::String) -> Tuple{Arrow.Table, FileMetadata}

Read an Arrow file and extract the table and metadata.
Returns the Arrow table and parsed FileMetadata struct.
"""
function read_arrow_navbits(path::String)::Tuple{Arrow.Table, FileMetadata}
    tbl = Arrow.Table(path)
    meta = get_file_metadata(tbl)
    return (tbl, meta)
end

"""
    get_file_metadata(tbl::Arrow.Table) -> FileMetadata

Extract metadata from an Arrow table's metadata.
"""
function get_file_metadata(tbl::Arrow.Table)::FileMetadata
    meta_dict = Arrow.getmetadata(tbl)

    if meta_dict === nothing || !haskey(meta_dict, "netcdf_metadata")
        # Return defaults if no metadata
        return FileMetadata(0, 0, 0, 0, "")
    end

    json_str = meta_dict["netcdf_metadata"]
    parsed = JSON3.read(json_str, Dict{String, Any})

    return FileMetadata(
        get(parsed, "year", 0),
        get(parsed, "day_of_year", 0),
        get(parsed, "prn", 0),
        get(parsed, "gps_week", 0),
        get(parsed, "source_file", "")
    )
end

"""
    NavbitRow

A single row from the navigation data with unpacked fields.
"""
struct NavbitRow
    time::Int32
    multiplicity::Int32
    navbits::Vector{UInt8}
end

"""
    iter_rows(tbl::Arrow.Table)

Return an iterator over rows as NavbitRow structs.
"""
function iter_rows(tbl::Arrow.Table)
    return (NavbitRow(row.time, row.multiplicity, collect(row.navbits)) for row in Tables.rows(tbl))
end

"""
    get_row_count(tbl::Arrow.Table) -> Int

Get the number of rows in an Arrow table.
"""
function get_row_count(tbl::Arrow.Table)::Int
    return length(Tables.rows(tbl))
end

"""
    find_arrow_files(dir::String; pattern::String="*.arrow", recursive::Bool=true) -> Vector{String}

Find all Arrow files in `dir`. Only `pattern == "*.arrow"` is supported; the
argument is kept for API compatibility with the previous Glob-based version.
"""
function find_arrow_files(dir::String; pattern::String="*.arrow", recursive::Bool=true)::Vector{String}
    if pattern != "*.arrow"
        error("find_arrow_files only supports pattern=\"*.arrow\"; got \"$pattern\"")
    end
    files = String[]
    if recursive
        for (root, _, filenames) in walkdir(dir)
            for f in filenames
                if endswith(f, ".arrow")
                    push!(files, joinpath(root, f))
                end
            end
        end
    else
        for f in readdir(dir)
            full = joinpath(dir, f)
            if isfile(full) && endswith(f, ".arrow")
                push!(files, full)
            end
        end
    end
    return files
end
