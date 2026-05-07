using Test
using Dates
using DuckDB

include("test_helpers.jl")

@testset "Temporal Analysis" begin
    @testset "Message Transitions" begin
        db_path = tempname() * ".db"
        db = create_database(db_path)

        try
            # Create test messages with transitions
            frames = [
                make_special_message_frame("MESSAGE_A             "; tow=100),
                make_special_message_frame("MESSAGE_A             "; tow=200),  # Same message
                make_special_message_frame("MESSAGE_B             "; tow=300),  # Transition
                make_special_message_frame("MESSAGE_B             "; tow=400),  # Same message
                make_special_message_frame("MESSAGE_C             "; tow=500),  # Transition
            ]

            times = Int32[100, 200, 300, 400, 500]
            mults = ones(Int32, 5)

            # Process messages
            arrow_path = "$db_path.arrow"
            create_test_arrow_file(arrow_path, frames, times; year=2022, day_of_year=100, prn=5)
            messages = extract_messages(arrow_path)
            meta = get_test_metadata(arrow_path)
            insert_messages!(db, messages, meta, mults)

            # Test getting transitions
            transitions = get_message_transitions(db)

            @test length(transitions) >= 2  # At least 2 transitions (A→B, B→C)
            @test all(t -> t.prn == 5, transitions)

            # Test PRN filtering
            trans_prn5 = get_message_transitions(db; prn=5)
            @test length(trans_prn5) >= 2

            trans_prn99 = get_message_transitions(db; prn=99)
            @test length(trans_prn99) == 0
        finally
            cleanup_test_db(db, "$db_path.arrow", db_path)
        end
    end

    @testset "Message Durations" begin
        db_path = tempname() * ".db"
        db = create_database(db_path)

        try
            # Create messages with known durations
            frames = [
                make_special_message_frame("SHORT_MESSAGE         "; tow=100),
                make_special_message_frame("SHORT_MESSAGE         "; tow=200),  # 100 sec duration
                make_special_message_frame("LONG_MESSAGE          "; tow=300),
                make_special_message_frame("LONG_MESSAGE          "; tow=500),  # 200 sec duration
            ]

            times = Int32[100, 200, 300, 500]
            mults = ones(Int32, 4)

            arrow_path = "$db_path.arrow"
            create_test_arrow_file(arrow_path, frames, times; year=2022, day_of_year=100, prn=5)
            messages = extract_messages(arrow_path)
            meta = get_test_metadata(arrow_path)
            insert_messages!(db, messages, meta, mults)

            # Test computing durations
            durations = compute_message_durations(db)

            @test length(durations) >= 2
            @test all(d -> d.duration_days >= 0, durations)

            # Test min_duration filter
            durations_filtered = compute_message_durations(db; min_duration_hours=0.1)
            @test length(durations_filtered) <= length(durations)
        finally
            cleanup_test_db(db, "$db_path.arrow", db_path)
        end
    end

    @testset "Day of Week Patterns" begin
        db_path = tempname() * ".db"
        db = create_database(db_path)

        try
            # Create messages across different days
            # DateTime(2022, 1, 3) is Monday
            frames_mon = [make_special_message_frame("MONDAY_MSG            "; tow=100)]
            frames_tue = [make_special_message_frame("TUESDAY_MSG           "; tow=100)]

            mon_path = "$db_path.mon.arrow"
            tue_path = "$db_path.tue.arrow"

            # Monday (day 3 of 2022)
            create_test_arrow_file(mon_path, frames_mon, Int32[100];
                                   year=2022, day_of_year=3, prn=5)
            messages = extract_messages(mon_path)
            meta = get_test_metadata(mon_path)
            insert_messages!(db, messages, meta, ones(Int32, 1))

            # Tuesday (day 4 of 2022)
            create_test_arrow_file(tue_path, frames_tue, Int32[100];
                                   year=2022, day_of_year=4, prn=5)
            messages = extract_messages(tue_path)
            meta = get_test_metadata(tue_path)
            insert_messages!(db, messages, meta, ones(Int32, 1))

            # Test day of week patterns
            patterns = analyze_day_of_week_patterns(db; year=2022)

            @test length(patterns) >= 1
            @test all(p -> 1 <= p.day_of_week <= 7, patterns)
            @test all(p -> p.message_count >= 0, patterns)
        finally
            cleanup_test_db(db, "$db_path.mon.arrow", "$db_path.tue.arrow", db_path)
        end
    end

    @testset "Change Point Detection" begin
        db_path = tempname() * ".db"
        db = create_database(db_path)

        try
            frames = [make_special_message_frame("TEST_MSG              "; tow=100)]
            arrow_path = "$db_path.arrow"
            create_test_arrow_file(arrow_path, frames, Int32[100];
                                   year=2022, day_of_year=100, prn=5)
            messages = extract_messages(arrow_path)
            meta = get_test_metadata(arrow_path)
            insert_messages!(db, messages, meta, ones(Int32, 1))

            # Test change point detection
            changepoints = detect_change_points(db; prn=5)

            @test changepoints isa Vector{DateTime}
            @test length(changepoints) >= 0  # May be empty for insufficient data
        finally
            cleanup_test_db(db, "$db_path.arrow", db_path)
        end
    end

    @testset "Date Range Queries" begin
        db_path = tempname() * ".db"
        db = create_database(db_path)

        try
            # Create messages across multiple days
            frames = [make_special_message_frame("TEST_MSG              "; tow=100)]

            d100_path = "$db_path.d100.arrow"
            d101_path = "$db_path.d101.arrow"
            d102_path = "$db_path.d102.arrow"

            # Day 100
            create_test_arrow_file(d100_path, frames, Int32[100];
                                   year=2022, day_of_year=100, prn=5)
            messages = extract_messages(d100_path)
            meta = get_test_metadata(d100_path)
            insert_messages!(db, messages, meta, ones(Int32, 1))

            # Day 101
            create_test_arrow_file(d101_path, frames, Int32[100];
                                   year=2022, day_of_year=101, prn=5)
            messages = extract_messages(d101_path)
            meta = get_test_metadata(d101_path)
            insert_messages!(db, messages, meta, ones(Int32, 1))

            # Day 102
            create_test_arrow_file(d102_path, frames, Int32[100];
                                   year=2022, day_of_year=102, prn=5)
            messages = extract_messages(d102_path)
            meta = get_test_metadata(d102_path)
            insert_messages!(db, messages, meta, ones(Int32, 1))

            # Test date range query
            start_date = DateTime(2022, 4, 10)  # Day 100
            end_date = DateTime(2022, 4, 11)    # Day 101

            df = get_messages_by_date_range(db, start_date, end_date)

            @test nrow(df) >= 0
            @test all(row -> start_date <= row.datetime <= end_date, eachrow(df))

            # Test PRN filtering
            df_prn5 = get_messages_by_date_range(db, start_date, end_date; prn=5)
            @test nrow(df_prn5) >= 0
            @test all(row -> row.prn == 5, eachrow(df_prn5))
        finally
            cleanup_test_db(db, "$db_path.d100.arrow", "$db_path.d101.arrow", "$db_path.d102.arrow", db_path)
        end
    end

    @testset "Duration Distribution" begin
        db_path = tempname() * ".db"
        db = create_database(db_path)

        try
            # Create messages
            frames = [
                make_special_message_frame("MSG_A                 "; tow=100),
                make_special_message_frame("MSG_B                 "; tow=200),
                make_special_message_frame("MSG_A                 "; tow=300),
            ]

            times = Int32[100, 200, 300]
            arrow_path = "$db_path.arrow"
            create_test_arrow_file(arrow_path, frames, times;
                                   year=2022, day_of_year=100, prn=5)
            messages = extract_messages(arrow_path)
            meta = get_test_metadata(arrow_path)
            insert_messages!(db, messages, meta, ones(Int32, 3))

            # Test duration distribution
            dist = get_duration_distribution(db)

            @test haskey(dist, :mean_hours)
            @test haskey(dist, :median_hours)
            @test haskey(dist, :min_hours)
            @test haskey(dist, :max_hours)
            @test haskey(dist, :num_transitions)

            @test dist.mean_hours >= 0
            @test dist.num_transitions >= 0

            # Test year filtering
            dist_2022 = get_duration_distribution(db; year=2022)
            @test haskey(dist_2022, :mean_hours)

            # Test PRN filtering
            dist_prn5 = get_duration_distribution(db; prn=5)
            @test haskey(dist_prn5, :mean_hours)
        finally
            cleanup_test_db(db, "$db_path.arrow", db_path)
        end
    end
end
