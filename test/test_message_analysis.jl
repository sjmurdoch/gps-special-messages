using Test

@testset "Message Analysis" begin
    @testset "Shannon Entropy" begin
        # Test empty array
        @test shannon_entropy(UInt8[]) == 0.0

        # Test uniform distribution (maximum entropy)
        # All 256 possible byte values appearing once each
        uniform = UInt8.(0:255)
        @test shannon_entropy(uniform) ≈ 8.0

        # Test single value (minimum entropy)
        single = fill(UInt8(42), 100)
        @test shannon_entropy(single) == 0.0

        # Test binary distribution
        # Equal mix of 0x00 and 0xFF
        binary = vcat(fill(UInt8(0x00), 50), fill(UInt8(0xFF), 50))
        @test shannon_entropy(binary) == 1.0

        # Test typical text (lower entropy)
        # ASCII "HELLO WORLD" repeated
        text_bytes = UInt8.(collect("HELLO WORLD"))
        text_repeated = repeat(text_bytes, 10)
        text_entropy = shannon_entropy(text_repeated)
        @test text_entropy < 4.5  # Text should have lower entropy
        @test text_entropy > 0.0  # But not zero (has variation)
    end

    @testset "Count Printable Characters" begin
        # All printable ASCII
        printable = UInt8.(collect(" !\"#\$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~"))
        @test count_printable_chars(printable) == length(printable)

        # No printable characters
        non_printable = UInt8.([0x00, 0x01, 0x02, 0x1F, 0x7F, 0x80, 0xFF])
        @test count_printable_chars(non_printable) == 0

        # Mix of printable and non-printable
        mixed = UInt8.([0x00, 0x41, 0x42, 0x20, 0xFF])  # null, 'A', 'B', space, 0xFF
        @test count_printable_chars(mixed) == 3  # A, B, space

        # Empty array
        @test count_printable_chars(UInt8[]) == 0
    end

    @testset "Count Null Bytes" begin
        # No null bytes
        no_nulls = UInt8.([0x01, 0x02, 0x03, 0x41, 0x42])
        @test count_null_bytes(no_nulls) == 0

        # All null bytes
        all_nulls = fill(UInt8(0x00), 10)
        @test count_null_bytes(all_nulls) == 10

        # Some null bytes
        some_nulls = UInt8.([0x00, 0x41, 0x00, 0x42, 0x00])
        @test count_null_bytes(some_nulls) == 3

        # Empty array
        @test count_null_bytes(UInt8[]) == 0
    end

    @testset "Is Likely Text" begin
        # Clear text: "HELLO WORLD ABCDEFGH"
        clear_text = UInt8.(collect("HELLO WORLD ABCDEFGH"))
        @test is_likely_text(clear_text) == true

        # Random/encrypted data (high entropy, non-printable)
        random_data = UInt8.([0x8A, 0x3F, 0xD2, 0x91, 0x4B, 0xE7, 0x22, 0xC4,
                              0x5D, 0x89, 0xF1, 0x3A, 0x76, 0xB3, 0x1E, 0x9C,
                              0x45, 0xD8, 0x62, 0xAF, 0x17, 0xE4])
        @test is_likely_text(random_data) == false

        # Null-padded text: "TEST" followed by nulls
        null_padded = vcat(UInt8.(collect("TEST")), fill(UInt8(0x00), 18))
        # This should be borderline - has printable chars but high null ratio
        # Based on our threshold (< 50% nulls), this is 18/22 = 82% nulls
        @test is_likely_text(null_padded) == false

        # High entropy text-like data (but still > 4.5 entropy)
        # Create a string with all unique characters
        high_entropy_text = UInt8.(collect("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123"))
        # This might have entropy > 4.5, so it should fail the entropy test
        if shannon_entropy(high_entropy_text) >= 4.5
            @test is_likely_text(high_entropy_text) == false
        else
            @test is_likely_text(high_entropy_text) == true
        end

        # Empty array
        @test is_likely_text(UInt8[]) == false

        # Low printable ratio (less than 70%)
        low_printable = vcat(UInt8.(collect("HELLO")),
                            UInt8.([0x80, 0x81, 0x82, 0x83, 0x84, 0x85, 0x86,
                                    0x87, 0x88, 0x89, 0x8A, 0x8B, 0x8C, 0x8D,
                                    0x8E, 0x8F, 0x90]))  # 5 printable out of 22
        @test is_likely_text(low_printable) == false
    end

    @testset "Compute Message Stats" begin
        # Test with typical text message
        text_msg = UInt8.(collect("GPS SPECIAL MESSAGE!"))
        stats = compute_message_stats(text_msg)

        @test stats.printable_chars > 0
        @test stats.null_bytes >= 0
        @test stats.entropy >= 0.0
        @test stats.is_likely_text isa Bool

        # Test with random data
        random_msg = rand(UInt8, 22)
        random_stats = compute_message_stats(random_msg)

        @test random_stats.printable_chars >= 0
        @test random_stats.null_bytes >= 0
        @test random_stats.entropy >= 0.0
        @test random_stats.is_likely_text isa Bool

        # Verify that stats match individual function calls
        @test stats.printable_chars == count_printable_chars(text_msg)
        @test stats.null_bytes == count_null_bytes(text_msg)
        @test stats.entropy == shannon_entropy(text_msg)
        @test stats.is_likely_text == is_likely_text(text_msg)
    end
end
