using Test
using Dates

# ── parse_msg_datetime ──────────────────────────────────────────────────────

@testset "OA Parser" begin

    @testset "parse_msg_datetime" begin
        @test parse_msg_datetime("192025Z JUN 2020") == DateTime(2020, 6, 19, 20, 25)
        @test parse_msg_datetime("041715Z DEC 2006") == DateTime(2006, 12, 4, 17, 15)
        @test parse_msg_datetime("131735Z JAN 2020") == DateTime(2020, 1, 13, 17, 35)
        @test parse_msg_datetime("010000Z MAR 2015") == DateTime(2015, 3, 1, 0, 0)
        @test_throws ErrorException parse_msg_datetime("not a date")
    end

    # ── parse_summary_field ──────────────────────────────────────────────

    @testset "parse_summary_field" begin
        @testset "Full range" begin
            (sd, st, ed, et) = parse_summary_field("178/0445-178/1645")
            @test sd == 178
            @test st == "0445"
            @test ed == 178
            @test et == "1645"
        end

        @testset "Open-ended" begin
            (sd, st, ed, et) = parse_summary_field("013/1734-/")
            @test sd == 13
            @test st == "1734"
            @test isnothing(ed)
            @test isnothing(et)
        end

        @testset "No time window" begin
            (sd, st, ed, et) = parse_summary_field("/-/")
            @test isnothing(sd)
            @test isnothing(st)
            @test isnothing(ed)
            @test isnothing(et)
        end

        @testset "DOY with varying digits" begin
            (sd, st, _, _) = parse_summary_field("5/0800-10/1200")
            @test sd == 5
            @test st == "0800"
        end
    end

    # ── nanu_event_timespan ──────────────────────────────────────────────

    @testset "nanu_event_timespan" begin
        @testset "Full range in same year" begin
            (start, stop) = nanu_event_timespan(178, "0445", 178, "1645", 2020)
            @test start == DateTime(2020, 6, 26, 4, 45)
            @test stop == DateTime(2020, 6, 26, 16, 45)
        end

        @testset "Open-ended" begin
            (start, stop) = nanu_event_timespan(13, "1734", nothing, nothing, 2020)
            @test start == DateTime(2020, 1, 13, 17, 34)
            @test isnothing(stop)
        end

        @testset "Both nothing" begin
            (start, stop) = nanu_event_timespan(nothing, nothing, nothing, nothing, 2020)
            @test isnothing(start)
            @test isnothing(stop)
        end

        @testset "Year boundary (stop DOY < start DOY)" begin
            (start, stop) = nanu_event_timespan(365, "2200", 3, "0600", 2020)
            @test start == DateTime(2020, 12, 30, 22, 0)
            @test stop == DateTime(2021, 1, 3, 6, 0)
        end
    end

    # ── parse_oa_file with real data ─────────────────────────────────────

    oa_dir = joinpath(@__DIR__, "..", "data", "ops_advisories")

    if isdir(oa_dir)
        @testset "Parse 2020/180.oa1" begin
            filepath = joinpath(oa_dir, "2020", "180.oa1")
            if isfile(filepath)
                records = parse_oa_file(filepath)

                # Should find records from all three sections
                @test length(records) >= 8  # 2 forecasts + 3 advisories + at least 3 general

                # Check known forecasts
                fcst_records = filter(r -> r.category == :forecast, records)
                @test length(fcst_records) == 2

                nanu_2020028 = filter(r -> r.nanu_id == "2020028", records)
                @test length(nanu_2020028) == 1
                @test nanu_2020028[1].prn == 3
                @test nanu_2020028[1].nanu_type == "FCSTDV"
                @test nanu_2020028[1].category == :forecast
                @test nanu_2020028[1].source_file == "2020/180.oa1"

                # Check known advisories
                adv_records = filter(r -> r.category == :advisory, records)
                @test length(adv_records) == 3

                nanu_2020004 = filter(r -> r.nanu_id == "2020004", records)
                @test length(nanu_2020004) == 1
                @test nanu_2020004[1].prn == 4
                @test nanu_2020004[1].nanu_type == "USABINIT"

                # Check DECOM record
                nanu_2020012 = filter(r -> r.nanu_id == "2020012", records)
                @test length(nanu_2020012) == 1
                @test nanu_2020012[1].prn == 23
                @test nanu_2020012[1].nanu_type == "DECOM"

                # Check general section
                gen_records = filter(r -> r.category == :general, records)
                @test length(gen_records) >= 6

                # GENERAL records should have no PRN
                pure_general = filter(r -> r.nanu_type == "GENERAL", gen_records)
                for rec in pure_general
                    @test isnothing(rec.prn)
                end

                # LAUNCH records in general section should have PRN
                launch_records = filter(r -> r.nanu_type == "LAUNCH", gen_records)
                @test length(launch_records) >= 1
            end
        end

        @testset "Parse 2011/150.oa1" begin
            filepath = joinpath(oa_dir, "2011", "150.oa1")
            if isfile(filepath)
                records = parse_oa_file(filepath)

                # Section A (forecasts) is empty
                fcst_records = filter(r -> r.category == :forecast, records)
                @test length(fcst_records) == 0

                # Section B: 3 advisories
                adv_records = filter(r -> r.category == :advisory, records)
                @test length(adv_records) == 3

                # Check UNUSUFN for PRN 10
                nanu_2011040 = filter(r -> r.nanu_id == "2011040", records)
                @test length(nanu_2011040) == 1
                @test nanu_2011040[1].prn == 10
                @test nanu_2011040[1].nanu_type == "UNUSUFN"
                @test nanu_2011040[1].category == :advisory

                # Check UNUSABLE for PRN 10
                nanu_2011041 = filter(r -> r.nanu_id == "2011041", records)
                @test length(nanu_2011041) == 1
                @test nanu_2011041[1].prn == 10
                @test nanu_2011041[1].nanu_type == "UNUSABLE"
                # UNUSABLE should have both start and stop
                @test !isnothing(nanu_2011041[1].event_start)
                @test !isnothing(nanu_2011041[1].event_stop)

                # Check UNUSUFN for PRN 30
                nanu_2011042 = filter(r -> r.nanu_id == "2011042", records)
                @test length(nanu_2011042) == 1
                @test nanu_2011042[1].prn == 30
                @test nanu_2011042[1].nanu_type == "UNUSUFN"

                # Section C: 2 general
                gen_records = filter(r -> r.category == :general, records)
                @test length(gen_records) == 2
            end
        end

        @testset "Parse 2007/001.oa1 (early file)" begin
            filepath = joinpath(oa_dir, "2007", "001.oa1")
            if isfile(filepath)
                records = parse_oa_file(filepath)
                @test length(records) >= 10

                # Should handle 2006-era NANU IDs from 2007 file
                nanu_2006152 = filter(r -> r.nanu_id == "2006152", records)
                @test length(nanu_2006152) == 1
                @test nanu_2006152[1].prn == 27
                @test nanu_2006152[1].nanu_type == "FCSTDV"

                # Check year boundary: DOY 005 in 2007/001.oa1 with NANU from 2006
                # NANU 2006167 has summary "005/0730-006/0730" — these DOYs are in 2007
                nanu_2006167 = filter(r -> r.nanu_id == "2006167", records)
                @test length(nanu_2006167) == 1
                @test nanu_2006167[1].event_start !== nothing
            end
        end

        @testset "Deduplication across files" begin
            # Parse two consecutive files from 2020 — same NANUs should appear in both
            f1 = joinpath(oa_dir, "2020", "179.oa1")
            f2 = joinpath(oa_dir, "2020", "180.oa1")
            if isfile(f1) && isfile(f2)
                r1 = parse_oa_file(f1)
                r2 = parse_oa_file(f2)

                # Combine and deduplicate
                all_records = vcat(r1, r2)
                deduped = GPSSpecialMessages._deduplicate_nanus(all_records)

                # Should have fewer records than the sum
                @test length(deduped) < length(r1) + length(r2)

                # Each NANU ID should appear exactly once
                ids = [r.nanu_id for r in deduped]
                @test length(ids) == length(unique(ids))
            end
        end

        @testset "parse_all_oa_files with year filter" begin
            records = parse_all_oa_files(oa_dir; years=2020:2020)
            @test length(records) > 0

            # All source files should be from 2020
            for rec in records
                @test startswith(rec.source_file, "2020/")
            end

            # Should find NANU 2020028
            found = filter(r -> r.nanu_id == "2020028", records)
            @test length(found) == 1
        end
    else
        @warn "OA directory not found, skipping real-data tests: $oa_dir"
    end

    # ── Edge cases ───────────────────────────────────────────────────────

    @testset "Edge cases" begin
        @testset "Summary with trailing whitespace" begin
            (sd, st, ed, et) = parse_summary_field("178/0445-178/1645  ")
            @test sd == 178
            @test et == "1645"
        end

        @testset "Empty summary" begin
            (sd, st, ed, et) = parse_summary_field("")
            @test isnothing(sd)
        end
    end
end
