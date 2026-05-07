@testset "Integration Tests" begin

    mktempdir() do tmp_dir

        @testset "end-to-end with synthetic data" begin
            # Create a realistic scenario with multiple satellites and days
            arrow_path = joinpath(tmp_dir, "synthetic.arrow")

            # Mix of special messages and regular frames
            messages_expected = [
                "GPS CONTROL SEGMENT  ",
                "USAF SCHRIEVER AFB   ",
                "SYSTEM STATUS OK     "
            ]

            frames = Vector{Vector{UInt8}}()
            times = Vector{Int32}()

            # Add special message frames interspersed with regular frames
            time = Int32(0)
            for msg in messages_expected
                # Add some non-special frames before
                for sf in 1:3
                    push!(frames, make_non_special_frame(sf))
                    push!(times, time)
                    time += 30
                end
                # Add special message
                push!(frames, make_special_message_frame(msg))
                push!(times, time)
                time += 30
            end

            create_test_arrow_file(arrow_path, frames, times;
                                  year=2024, day_of_year=100, prn=5)

            # Process and verify
            messages = extract_messages(arrow_path)

            @test length(messages) == 3

            # Verify message content (trimming for comparison)
            for (i, expected) in enumerate(messages_expected)
                @test rstrip(messages[i].ascii_message) == rstrip(expected)
            end

            # Verify metadata
            for msg in messages
                @test msg.prn == 5
                @test msg.sv_id == 55
                @test Dates.year(msg.datetime) == 2024
                @test Dates.dayofyear(msg.datetime) == 100
            end
        end

        @testset "multiple files multiple satellites" begin
            # Simulate data from multiple satellites. Use a fresh subdirectory so
            # arrow files left behind by other subtests in tmp_dir don't pollute
            # the directory-wide scan.
            sats_dir = mkpath(joinpath(tmp_dir, "sats"))
            satellites = [1, 5, 12, 31]

            for prn in satellites
                arrow_path = joinpath(sats_dir, "sat_$prn.arrow")
                frames = [
                    make_special_message_frame("SAT $prn MESSAGE     "),
                    make_non_special_frame(1),
                    make_special_message_frame("SAT $prn MSG 2       ")
                ]
                times = Int32[0, 30, 60]
                create_test_arrow_file(arrow_path, frames, times;
                                      year=2024, day_of_year=200, prn=prn)
            end

            messages = extract_messages_from_dir(sats_dir)

            # Should have 2 messages per satellite
            @test length(messages) == 8

            # Verify all satellites represented
            prns = Set([m.prn for m in messages])
            @test prns == Set(satellites)
        end

        @testset "message content verification" begin
            # Test specific character encoding
            test_cases = [
                "ABCDEFGHIJKLMNOPQRSTUV",  # All uppercase
                "0123456789 TEST      ",   # Digits
                "GPS/UTC+0:00 TEST    ",   # Special characters
                "TEST'S \"QUOTED\" MSG ",  # Quotes
            ]

            for (i, expected) in enumerate(test_cases)
                arrow_path = joinpath(tmp_dir, "content_$i.arrow")
                frames = [make_special_message_frame(expected)]
                times = Int32[0]
                create_test_arrow_file(arrow_path, frames, times)

                messages = extract_messages(arrow_path)

                @test length(messages) == 1
                # Compare trimmed to handle padding differences
                @test rstrip(messages[1].ascii_message) == rstrip(expected)
            end
        end

        @testset "datetime accuracy" begin
            # Test various times throughout the day
            time_cases = [
                (0, 0, 0, 0),          # Midnight
                (3600, 1, 0, 0),       # 01:00:00
                (43200, 12, 0, 0),     # 12:00:00
                (86399, 23, 59, 59),   # 23:59:59
                (45296, 12, 34, 56),   # 12:34:56
            ]

            for (seconds, hour, minute, second) in time_cases
                arrow_path = joinpath(tmp_dir, "time_$(seconds).arrow")
                frames = [make_special_message_frame("TIME TEST            ")]
                times = Int32[seconds]
                create_test_arrow_file(arrow_path, frames, times;
                                      year=2024, day_of_year=1)

                messages = extract_messages(arrow_path)

                @test length(messages) == 1
                dt = messages[1].datetime
                @test Dates.hour(dt) == hour
                @test Dates.minute(dt) == minute
                @test Dates.second(dt) == second
            end
        end

        @testset "alert flag handling" begin
            # Test alert flag propagation
            arrow_path = joinpath(tmp_dir, "alert.arrow")

            # Create frame with alert flag set
            frame_alert = make_special_message_frame("ALERT MESSAGE        "; alert=true)
            frame_normal = make_special_message_frame("NORMAL MESSAGE       "; alert=false)

            frames = [frame_alert, frame_normal]
            times = Int32[0, 30]
            create_test_arrow_file(arrow_path, frames, times)

            messages = extract_messages(arrow_path)

            @test length(messages) == 2
            @test messages[1].alert_flag == true
            @test messages[2].alert_flag == false
        end

        @testset "large file simulation" begin
            # Simulate processing a day's worth of data
            arrow_path = joinpath(tmp_dir, "large.arrow")

            n_subframes = 100
            frames = Vector{Vector{UInt8}}(undef, n_subframes)
            times = Vector{Int32}(undef, n_subframes)

            special_count = 0
            for i in 1:n_subframes
                times[i] = Int32((i - 1) * 30)
                # Every 10th frame is a special message (simulating Page 17 rotation)
                if i % 10 == 0
                    frames[i] = make_special_message_frame("MSG $(lpad(i, 3, '0'))             ")
                    special_count += 1
                else
                    frames[i] = make_non_special_frame(((i - 1) % 5) + 1)
                end
            end

            create_test_arrow_file(arrow_path, frames, times)

            messages = extract_messages(arrow_path)

            @test length(messages) == special_count
        end

    end
end
