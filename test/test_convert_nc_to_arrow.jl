using Test
using NCDatasets
using Arrow
using DataFrames
using JSON3
using Dates

# Include the pipeline script under test
include(joinpath(@__DIR__, "..", "pipeline", "03_convert_to_arrow.jl"))

@testset "NetCDF to Arrow Conversion Tests" begin
    
    # Helper to create a basic NC file
    function create_nc_file(path, n_time, navbits_data; 
                            version=1, year=2024, doy=100, prn=5, gps_week=2200,
                            extra_global_attrs=Dict{String,Any}(),
                            missing_scalars=false)
        NCDataset(path, "c") do ds
            defDim(ds, "time", n_time)
            defDim(ds, "gps_word", 10)
            
            v_time = defVar(ds, "time", Int32, ("time",))
            v_time[:] = Int32.(1:n_time)
            
            v_mult = defVar(ds, "multiplicity", Int32, ("time",))
            v_mult[:] = ones(Int32, n_time)
            
            v_nav = defVar(ds, "navbits", Int32, ("time", "gps_word"))
            v_nav[:, :] = navbits_data
            
            v_word = defVar(ds, "gps_word", Int16, ("gps_word",))
            v_word[:] = Int16.(1:10)
            
            defVar(ds, "nofsfr", Int32, ())[:] = n_time
            
            if !missing_scalars
                defVar(ds, "version", Int16, ())[:] = version
                defVar(ds, "year", Int16, ())[:] = year
                defVar(ds, "day_of_year", Int16, ())[:] = doy
                defVar(ds, "prn", Int16, ())[:] = prn
                defVar(ds, "gps_week", Int16, ())[:] = gps_week
            end

            for (k, v) in extra_global_attrs
                ds.attrib[k] = v
            end
            
            # Add variable attribute for testing
            v_nav.attrib["units"] = "bits"
        end
    end

    mktempdir() do tmp_dir
        
        @testset "Basic Functionality" begin
            nc_path = joinpath(tmp_dir, "basic.nc")
            arrow_path = joinpath(tmp_dir, "basic.arrow")
            
            n_time = 5
            # Random data within 30-bit range
            data = rand(Int32(0):Int32(2^30-1), n_time, 10)
            create_nc_file(nc_path, n_time, data)
            
            nc_to_arrow(nc_path, arrow_path)
            df, meta = read_arrow_with_metadata(arrow_path)
            
            @test nrow(df) == n_time
            @test meta["year"] == 2024
            @test meta["variable_attributes"]["navbits"]["units"] == "bits"
            
            rec = reconstruct_navbits(df)
            @test rec == permutedims(data)
        end

        @testset "Edge Cases & Robustness" begin
            # 1. Empty File
            nc_empty = joinpath(tmp_dir, "empty.nc")
            arrow_empty = joinpath(tmp_dir, "empty.arrow")
            create_nc_file(nc_empty, 0, Matrix{Int32}(undef, 0, 10))
            
            nc_to_arrow(nc_empty, arrow_empty)
            df, _ = read_arrow_with_metadata(arrow_empty)
            @test nrow(df) == 0
            
            # 2. Missing Metadata (Should succeed with defaults)
            nc_missing = joinpath(tmp_dir, "missing.nc")
            arrow_missing = joinpath(tmp_dir, "missing.arrow")
            create_nc_file(nc_missing, 1, zeros(Int32, 1, 10); missing_scalars=true)
            
            nc_to_arrow(nc_missing, arrow_missing)
            _, meta_missing = read_arrow_with_metadata(arrow_missing)
            
            @test meta_missing["year"] == 0
            @test meta_missing["prn"] == 0
            
            # 3. Dirty Input (Bits 30-31 set)
            nc_dirty = joinpath(tmp_dir, "dirty.nc")
            arrow_dirty = joinpath(tmp_dir, "dirty.arrow")
            
            # 0xC0000001 has bits 31, 30, and 0 set.
            # We expect bits 31 and 30 to be ignored, so result is 1.
            dirty_data = fill(reinterpret(Int32, 0xC0000001), 1, 10)
            create_nc_file(nc_dirty, 1, dirty_data)
            
            nc_to_arrow(nc_dirty, arrow_dirty)
            df, _ = read_arrow_with_metadata(arrow_dirty)
            rec = reconstruct_navbits(df)
            
            # Expected: 0x00000001 (only bit 0 preserved)
            @test all(rec .== 1)
        end

        @testset "Data Integrity & Bit Logic" begin
            nc_bits = joinpath(tmp_dir, "bits.nc")
            arrow_bits = joinpath(tmp_dir, "bits.arrow")
            
            # Patterns
            # Row 1: All Zeros
            # Row 2: All Ones (masked to 30 bits -> 0x3FFFFFFF)
            # Row 3: Alternating 1010... (0x2AAAAAAA)
            # Row 4: Alternating 0101... (0x15555555)
            
            patterns = [
                Int32(0),
                Int32(0x3FFFFFFF),
                Int32(0x2AAAAAAA),
                Int32(0x15555555)
            ]
            
            n_rows = length(patterns)
            data = zeros(Int32, n_rows, 10)
            for i in 1:n_rows
                data[i, :] .= patterns[i]
            end
            
            create_nc_file(nc_bits, n_rows, data)
            nc_to_arrow(nc_bits, arrow_bits)
            df, _ = read_arrow_with_metadata(arrow_bits)
            rec = reconstruct_navbits(df)
            
            @test rec[:, 1] == fill(patterns[1], 10)
            @test rec[:, 2] == fill(patterns[2], 10)
            @test rec[:, 3] == fill(patterns[3], 10)
            @test rec[:, 4] == fill(patterns[4], 10)
            
            # Walking Bit Test
            # Create 30 rows, each with a different bit set in Word 1
            nc_walk = joinpath(tmp_dir, "walk.nc")
            arrow_walk = joinpath(tmp_dir, "walk.arrow")
            
            walk_data = zeros(Int32, 30, 10)
            for b in 0:29
                walk_data[b+1, 1] = 1 << b
            end
            
            create_nc_file(nc_walk, 30, walk_data)
            nc_to_arrow(nc_walk, arrow_walk)
            df_walk, _ = read_arrow_with_metadata(arrow_walk)
            rec_walk = reconstruct_navbits(df_walk)
            
            @test rec_walk == permutedims(walk_data)
        end

        @testset "System & I/O" begin
            # 1. File Overwriting
            nc_overwrite = joinpath(tmp_dir, "overwrite.nc")
            arrow_overwrite = joinpath(tmp_dir, "overwrite.arrow")
            create_nc_file(nc_overwrite, 1, zeros(Int32, 1, 10))
            
            # Run once
            nc_to_arrow(nc_overwrite, arrow_overwrite)
            @test isfile(arrow_overwrite)
            mtime1 = stat(arrow_overwrite).mtime
            
            sleep(1.1) # Ensure filesystem timestamp tick
            
            # Run again
            nc_to_arrow(nc_overwrite, arrow_overwrite)
            mtime2 = stat(arrow_overwrite).mtime
            
            @test mtime2 > mtime1
            
            # 2. Non-NC Files
            input_dir = joinpath(tmp_dir, "input_mixed")
            output_dir = joinpath(tmp_dir, "output_mixed")
            mkpath(input_dir)
            
            # Create valid NC
            create_nc_file(joinpath(input_dir, "valid.nc"), 1, zeros(Int32, 1, 10))
            # Create dummy text file
            write(joinpath(input_dir, "ignore.txt"), "I am not a netcdf")
            
            convert_directory(input_dir, output_dir; verbose=false)
            
            @test isfile(joinpath(output_dir, "valid.arrow"))
            @test !isfile(joinpath(output_dir, "ignore.arrow"))
            
            # 3. JSON Metadata Special Chars
            nc_json = joinpath(tmp_dir, "json.nc")
            arrow_json = joinpath(tmp_dir, "json.arrow")
            
            special_str = "Key with \"quotes\", \nnewlines, and unicode: αβγ"
            create_nc_file(nc_json, 1, zeros(Int32, 1, 10); 
                           extra_global_attrs=Dict("special" => special_str))
            
            nc_to_arrow(nc_json, arrow_json)
            _, meta = read_arrow_with_metadata(arrow_json)
            
            @test meta["global_attributes"]["special"] == special_str
        end
    end
end