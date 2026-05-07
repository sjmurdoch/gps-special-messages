@testset "Arrow Reader" begin

    mktempdir() do tmp_dir

        @testset "read_arrow_navbits" begin
            # Create test file
            arrow_path = joinpath(tmp_dir, "test_read.arrow")
            frames = [
                make_special_message_frame("MESSAGE 1            "),
                make_non_special_frame(1),
                make_special_message_frame("MESSAGE 2            ")
            ]
            times = Int32[100, 200, 300]
            create_test_arrow_file(arrow_path, frames, times; year=2024, day_of_year=150, prn=7)

            tbl, meta = read_arrow_navbits(arrow_path)

            @test meta.year == 2024
            @test meta.day_of_year == 150
            @test meta.prn == 7
            @test get_row_count(tbl) == 3
        end

        @testset "get_file_metadata" begin
            # Create file with custom metadata
            arrow_path = joinpath(tmp_dir, "test_meta.arrow")
            frames = [make_non_special_frame(1)]
            times = Int32[0]
            create_test_arrow_file(arrow_path, frames, times;
                                  year=2023, day_of_year=365, prn=31)

            tbl, meta = read_arrow_navbits(arrow_path)

            @test meta.year == 2023
            @test meta.day_of_year == 365
            @test meta.prn == 31
            @test meta.gps_week == 2200
            @test meta.source_file == "test.nc"
        end

        @testset "iter_rows" begin
            arrow_path = joinpath(tmp_dir, "test_iter.arrow")
            frames = [
                make_non_special_frame(1),
                make_non_special_frame(2),
                make_non_special_frame(3)
            ]
            times = Int32[10, 20, 30]
            create_test_arrow_file(arrow_path, frames, times)

            tbl, _ = read_arrow_navbits(arrow_path)
            rows = collect(iter_rows(tbl))

            @test length(rows) == 3
            @test rows[1].time == 10
            @test rows[2].time == 20
            @test rows[3].time == 30
            @test all(r -> length(r.navbits) == 38, rows)
        end

        @testset "empty file" begin
            arrow_path = joinpath(tmp_dir, "test_empty.arrow")
            frames = Vector{UInt8}[]
            times = Int32[]
            create_test_arrow_file(arrow_path, frames, times)

            tbl, meta = read_arrow_navbits(arrow_path)
            @test get_row_count(tbl) == 0
        end

        @testset "navbits integrity" begin
            # Verify that navbits are stored and retrieved correctly
            arrow_path = joinpath(tmp_dir, "test_integrity.arrow")
            test_message = "INTEGRITY TEST MSG   "
            original_frame = make_special_message_frame(test_message)
            frames = [original_frame]
            times = Int32[0]
            create_test_arrow_file(arrow_path, frames, times)

            tbl, _ = read_arrow_navbits(arrow_path)
            rows = collect(iter_rows(tbl))

            @test rows[1].navbits == original_frame
        end
    end
end
