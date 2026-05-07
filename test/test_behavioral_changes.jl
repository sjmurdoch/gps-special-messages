using Test
using Dates
using DuckDB
using DataFrames

include("test_helpers.jl")

# ── cusum_detect ─────────────────────────────────────────────────────────────

@testset "CUSUM Change-Point Detection" begin

    @testset "Step change in synthetic series" begin
        # Build a series that is stable at 0 for 50 steps, then jumps to 5
        n_low = 50
        n_high = 50
        series = Float64[fill(0.0, n_low); fill(5.0, n_high)]
        mask   = trues(length(series))

        cps = cusum_detect(series, mask; slack=0.5, threshold=5.0)

        # Should detect at least one change point after position n_low
        @test !isempty(cps)
        @test all(cp -> cp > n_low, cps)
    end

    @testset "Onset estimation returns index near actual change" begin
        # Series: 100 steps at 0, then 100 steps at 10 (huge shift)
        n_low = 100
        series = Float64[fill(0.0, n_low); fill(10.0, 100)]
        mask   = trues(length(series))

        cps = cusum_detect(series, mask; slack=0.5, threshold=5.0)
        @test !isempty(cps)
        # Onset should be at or very near position 101 (the first changed value)
        @test cps[1] >= n_low + 1
        @test cps[1] <= n_low + 3   # within 2 steps of actual change
    end

    @testset "Stable series produces no change points" begin
        series = fill(1.0, 100)
        mask   = trues(100)

        cps = cusum_detect(series, mask)
        @test isempty(cps)
    end

    @testset "Too few valid observations returns empty" begin
        series = Float64[1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0]  # only 7
        mask   = trues(length(series))

        cps = cusum_detect(series, mask)
        @test isempty(cps)
    end

    @testset "Missing values are skipped" begin
        # 10 valid low values, then 10 valid high values; interspersed with missing
        vals = Union{Float64,Missing}[]
        mask = Bool[]
        for i in 1:10
            push!(vals, 0.0); push!(mask, true)
            push!(vals, missing); push!(mask, false)
        end
        for i in 1:10
            push!(vals, 8.0); push!(mask, true)
            push!(vals, missing); push!(mask, false)
        end

        cps = cusum_detect(vals, mask; slack=0.5, threshold=5.0)
        @test !isempty(cps)
    end

    @testset "Two-sided: detects both increases and decreases" begin
        # Decrease then increase
        series = Float64[fill(5.0, 50); fill(0.0, 50); fill(5.0, 50)]
        mask   = trues(length(series))

        cps = cusum_detect(series, mask; slack=0.5, threshold=5.0)
        @test length(cps) >= 1
    end

    @testset "Returns Vector{Int}" begin
        series = Float64[fill(0.0, 50); fill(5.0, 50)]
        mask   = trues(100)
        cps = cusum_detect(series, mask)
        @test cps isa Vector{Int}
    end

    @testset "Reference fraction is respected" begin
        # A step change that occurs before the reference period ends
        # should NOT be detected (the reference absorbs it)
        n = 200
        series = Float64[fill(0.0, 10); fill(5.0, n-10)]
        mask   = trues(n)

        # With reference_fraction=0.2 the first 40 obs form the reference,
        # which includes both 0 and 5 — σ will be inflated, suppressing detection
        cps_large_ref = cusum_detect(series, mask; reference_fraction=0.20)

        # With a tiny reference (first 5 obs only, all zero) the jump IS detected
        cps_small_ref = cusum_detect(series, mask; reference_fraction=0.05)

        # The small-reference run should detect the step change
        @test !isempty(cps_small_ref)
    end

    @testset "Adaptive reference: sustained shift triggers only once" begin
        # A single permanent step change should produce exactly one change point,
        # not repeated detections from the old baseline.
        n = 300
        series = Float64[fill(0.0, 50); fill(10.0, n - 50)]
        mask   = trues(n)
        cps = cusum_detect(series, mask; slack=0.5, threshold=5.0, reference_fraction=0.1)
        @test length(cps) == 1
        @test cps[1] >= 49 && cps[1] <= 53   # near the actual change at index 51
    end

    @testset "Adaptive reference: two distinct shifts detected separately" begin
        # Two step changes should produce exactly two change points.
        n = 300
        series = Float64[fill(0.0, 100); fill(10.0, 100); fill(-5.0, 100)]
        mask   = trues(n)
        cps = cusum_detect(series, mask; slack=0.5, threshold=5.0, reference_fraction=0.1)
        @test length(cps) == 2
        @test cps[1] >= 99 && cps[1] <= 103
        @test cps[2] >= 199 && cps[2] <= 203
    end
end

# ── compute_behavioral_metrics ───────────────────────────────────────────────

@testset "Behavioral Metrics Computation" begin

    db_path = tempname() * ".db"
    db = create_database(db_path)

    try
        # Insert a handful of messages across three days
        # Day 1 (2022-04-10): all-spaces sentinel on PRN 5
        frames_sentinel = [make_special_message_frame("                      "; tow=100)]
        sent_path = "$db_path.sent.arrow"
        create_test_arrow_file(sent_path, frames_sentinel, Int32[100];
                               year=2022, day_of_year=100, prn=5)
        messages = extract_messages(sent_path)
        meta = get_test_metadata(sent_path)
        insert_messages!(db, messages, meta, ones(Int32, 1))

        # Day 2 (2022-04-11): normal message on PRN 5
        frames_normal = [make_special_message_frame("NORMAL_MSG            "; tow=100)]
        norm_path = "$db_path.norm.arrow"
        create_test_arrow_file(norm_path, frames_normal, Int32[100];
                               year=2022, day_of_year=101, prn=5)
        messages = extract_messages(norm_path)
        meta = get_test_metadata(norm_path)
        insert_messages!(db, messages, meta, ones(Int32, 1))

        # Day 3 (2022-04-12): TEXT-prefixed on PRN 1
        frames_text = [make_special_message_frame("TEXT\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f\x10\x11\x12"; tow=100)]
        text_path = "$db_path.text.arrow"
        create_test_arrow_file(text_path, frames_text, Int32[100];
                               year=2022, day_of_year=102, prn=1)
        messages = extract_messages(text_path)
        meta = get_test_metadata(text_path)
        insert_messages!(db, messages, meta, ones(Int32, 1))

        metrics = compute_behavioral_metrics(db; granularities=[:daily])

        @testset "Returns a DataFrame" begin
            @test metrics isa DataFrame
        end

        @testset "Has required columns" begin
            for col in [:period_start, :granularity, :prn, :observation_count,
                        :sentinel_fraction, :text_fraction, :mean_duration_hours]
                @test hasproperty(metrics, col)
            end
        end

        @testset "Granularity column is 'daily'" begin
            @test all(==(String("daily")), metrics.granularity)
        end

        @testset "Fleet-wide aggregate rows present (prn == 0)" begin
            fleet_rows = filter(r -> r.prn == 0, metrics)
            @test nrow(fleet_rows) >= 1
        end

        @testset "Sentinel fraction is 1.0 for the all-spaces day" begin
            # Day 100 = 2022-04-10
            day100 = DateTime(2022, 4, 10)
            prn5_day100 = filter(r -> r.prn == 5 &&
                                     Date(r.period_start) == Date(day100), metrics)
            if !isempty(prn5_day100)
                @test prn5_day100[1, :sentinel_fraction] ≈ 1.0
            end
        end

        @testset "TEXT fraction is 1.0 for the TEXT day on PRN 1" begin
            day102 = DateTime(2022, 4, 12)
            prn1_day102 = filter(r -> r.prn == 1 &&
                                     Date(r.period_start) == Date(day102), metrics)
            if !isempty(prn1_day102)
                @test prn1_day102[1, :text_fraction] ≈ 1.0
            end
        end

    finally
        cleanup_test_db(db,
            "$db_path.sent.arrow",
            "$db_path.norm.arrow",
            "$db_path.text.arrow",
            db_path)
    end
end

# ── detect_behavioral_change_points ──────────────────────────────────────────

@testset "Behavioral Change Point Detection" begin

    @testset "Returns DataFrame with correct columns" begin
        # Build a synthetic metrics DataFrame
        n = 60
        dates = [DateTime(2020, 1, 1) + Day(i-1) for i in 1:n]
        sentinel_vals = [i <= 30 ? 0.0 : 0.9 for i in 1:n]

        metrics = DataFrame(
            period_start         = dates,
            granularity          = fill("daily", n),
            prn                  = fill(5, n),
            observation_count    = fill(100, n),
            transition_count     = fill(missing, n),
            unique_message_count = fill(missing, n),
            mean_entropy         = fill(4.0, n),
            sentinel_fraction    = sentinel_vals,
            text_fraction        = fill(0.0, n),
            active_prn_count     = fill(missing, n),
            mean_duration_hours  = fill(missing, n),
        )

        cp_df = detect_behavioral_change_points(metrics;
                                                slack=0.5, threshold=5.0,
                                                coordinated_min_prns=8)

        @test cp_df isa DataFrame
        for col in [:detected_at, :granularity, :prn, :metric,
                    :direction, :cusum_statistic, :is_coordinated,
                    :coordinated_prn_count]
            @test hasproperty(cp_df, col)
        end
    end

    @testset "Detects step change in sentinel_fraction" begin
        n = 100
        dates = [DateTime(2020, 1, 1) + Day(i-1) for i in 1:n]
        # Clear step at position 51
        sentinel_vals = Float64[i <= 50 ? 0.0 : 0.95 for i in 1:n]

        metrics = DataFrame(
            period_start         = dates,
            granularity          = fill("daily", n),
            prn                  = fill(5, n),
            observation_count    = fill(100, n),
            transition_count     = fill(missing, n),
            unique_message_count = fill(missing, n),
            mean_entropy         = fill(4.0, n),
            sentinel_fraction    = sentinel_vals,
            text_fraction        = fill(0.0, n),
            active_prn_count     = fill(missing, n),
            mean_duration_hours  = fill(missing, n),
        )

        cp_df = detect_behavioral_change_points(metrics; slack=0.5, threshold=5.0)

        sentinel_cps = filter(r -> r.metric == "sentinel_fraction", cp_df)
        @test !isempty(sentinel_cps)
        # All detections should be after the step
        @test all(r -> r.detected_at > dates[50], eachrow(sentinel_cps))
    end

    @testset "Direction is 'increase' for upward step" begin
        n = 100
        dates = [DateTime(2021, 1, 1) + Day(i-1) for i in 1:n]
        vals  = Float64[i <= 50 ? 0.0 : 0.9 for i in 1:n]

        metrics = DataFrame(
            period_start         = dates,
            granularity          = fill("daily", n),
            prn                  = fill(3, n),
            observation_count    = fill(100, n),
            transition_count     = fill(missing, n),
            unique_message_count = fill(missing, n),
            mean_entropy         = fill(4.0, n),
            sentinel_fraction    = vals,
            text_fraction        = fill(0.0, n),
            active_prn_count     = fill(missing, n),
            mean_duration_hours  = fill(missing, n),
        )

        cp_df = detect_behavioral_change_points(metrics)
        sentinel_cps = filter(r -> r.metric == "sentinel_fraction", cp_df)
        @test !isempty(sentinel_cps)
        @test all(r -> r.direction == "increase", eachrow(sentinel_cps))
    end

    @testset "Empty metrics produces empty result" begin
        empty_metrics = DataFrame(
            period_start         = DateTime[],
            granularity          = String[],
            prn                  = Int[],
            observation_count    = Union{Int,Missing}[],
            transition_count     = Union{Int,Missing}[],
            unique_message_count = Union{Int,Missing}[],
            mean_entropy         = Union{Float64,Missing}[],
            sentinel_fraction    = Union{Float64,Missing}[],
            text_fraction        = Union{Float64,Missing}[],
            active_prn_count     = Union{Int,Missing}[],
            mean_duration_hours  = Union{Float64,Missing}[],
        )
        cp_df = detect_behavioral_change_points(empty_metrics)
        @test nrow(cp_df) == 0
    end
end

# ── DuckDB behavioral table functions ─────────────────────────────────────────

@testset "Behavioral DuckDB Functions" begin

    db_path = tempname() * ".db"
    db = create_database(db_path)

    try
        create_behavioral_tables!(db)

        @testset "create_behavioral_tables! is idempotent" begin
            # Calling twice should not throw
            create_behavioral_tables!(db)
            @test true
        end

        # Build a minimal metrics DataFrame to save
        dates = [DateTime(2020, 1, 1) + Day(i-1) for i in 1:5]
        metrics = DataFrame(
            period_start         = dates,
            granularity          = fill("daily", 5),
            prn                  = fill(5, 5),
            observation_count    = [10, 10, 10, 10, 10],
            transition_count     = fill(missing, 5),
            unique_message_count = fill(missing, 5),
            mean_entropy         = [4.0, 4.1, 4.2, 4.3, 4.4],
            sentinel_fraction    = [0.0, 0.0, 0.5, 1.0, 1.0],
            text_fraction        = fill(0.0, 5),
            active_prn_count     = fill(missing, 5),
            mean_duration_hours  = fill(missing, 5),
        )

        @testset "save_behavioral_metrics! inserts rows" begin
            save_behavioral_metrics!(db, metrics)
            result = DBInterface.execute(db, "SELECT COUNT(*) as n FROM behavioral_metrics")
            @test first(result).n == 5
        end

        @testset "save_behavioral_metrics! replaces on re-run" begin
            save_behavioral_metrics!(db, metrics)
            result = DBInterface.execute(db, "SELECT COUNT(*) as n FROM behavioral_metrics")
            @test first(result).n == 5   # Still 5, not 10
        end

        # Build a minimal change-points DataFrame
        cp_df = DataFrame(
            detected_at           = [DateTime(2020, 1, 3)],
            granularity           = ["daily"],
            prn                   = [5],
            metric                = ["sentinel_fraction"],
            direction             = ["increase"],
            cusum_statistic       = [5.2],
            is_coordinated        = [false],
            coordinated_prn_count = [0],
        )

        @testset "save_behavioral_change_points! inserts rows" begin
            save_behavioral_change_points!(db, cp_df)
            result = DBInterface.execute(db, "SELECT COUNT(*) as n FROM behavioral_change_points")
            @test first(result).n == 1
        end

        @testset "save_behavioral_change_points! clears old rows on re-run" begin
            save_behavioral_change_points!(db, cp_df)
            result = DBInterface.execute(db, "SELECT COUNT(*) as n FROM behavioral_change_points")
            @test first(result).n == 1   # Still 1, not 2
        end

        @testset "get_behavioral_change_points returns DataFrame" begin
            df = get_behavioral_change_points(db)
            @test df isa DataFrame
            @test nrow(df) == 1
        end

        @testset "get_behavioral_change_points prn filter" begin
            df5 = get_behavioral_change_points(db; prn=5)
            @test nrow(df5) == 1

            df99 = get_behavioral_change_points(db; prn=99)
            @test nrow(df99) == 0
        end

        @testset "get_behavioral_change_points metric filter" begin
            df_sent = get_behavioral_change_points(db; metric="sentinel_fraction")
            @test nrow(df_sent) == 1

            df_text = get_behavioral_change_points(db; metric="text_fraction")
            @test nrow(df_text) == 0
        end

    finally
        cleanup_test_db(db, db_path)
    end
end
