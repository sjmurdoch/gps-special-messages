@testset "Bit Extraction" begin

    @testset "extract_bits" begin
        # Test single byte extraction
        bytes = UInt8[0b10101010]
        @test extract_bits(bytes, 0, 8) == 0b10101010
        @test extract_bits(bytes, 0, 4) == 0b1010
        @test extract_bits(bytes, 4, 4) == 0b1010
        @test extract_bits(bytes, 0, 1) == 1
        @test extract_bits(bytes, 1, 1) == 0
        @test extract_bits(bytes, 7, 1) == 0

        # Test multi-byte extraction
        bytes = UInt8[0xFF, 0x00]
        @test extract_bits(bytes, 0, 16) == 0xFF00
        @test extract_bits(bytes, 0, 8) == 0xFF
        @test extract_bits(bytes, 8, 8) == 0x00

        # Test byte-spanning extraction
        bytes = UInt8[0b11110000, 0b00001111]
        @test extract_bits(bytes, 4, 8) == 0b00000000  # Last 4 of first + first 4 of second
        @test extract_bits(bytes, 2, 4) == 0b1100
        @test extract_bits(bytes, 6, 4) == 0b0000

        # Test 30-bit extraction (GPS word size)
        # 30 ones: 11111111 11111111 11111100 (bits 0-29 set, bits 30-31 clear)
        bytes = UInt8[0xFF, 0xFF, 0xFF, 0xFC]  # 30 ones followed by zeros
        @test extract_bits(bytes, 0, 30) == 0x3FFFFFFF
    end

    @testset "extract_word" begin
        # Create test data with known patterns
        # Word 1 = all ones (0x3FFFFFFF), Word 2 = all zeros, etc.
        words = [
            UInt32(0x3FFFFFFF),  # Word 1: all ones (30 bits)
            UInt32(0x00000000),  # Word 2: all zeros
            UInt32(0x15555555),  # Word 3: alternating 01
            UInt32(0x2AAAAAAA),  # Word 4: alternating 10
            UInt32(0x00000001),  # Word 5: single bit
            UInt32(0x20000000),  # Word 6: MSB set
            UInt32(0x12345678 & 0x3FFFFFFF),  # Word 7
            UInt32(0x0FEDCBA9 & 0x3FFFFFFF),  # Word 8
            UInt32(0x3F000000),  # Word 9
            UInt32(0x0000003F),  # Word 10
        ]

        packed = pack_words_to_bytes(words)

        for (i, expected) in enumerate(words)
            @test extract_word(packed, i) == expected
        end
    end

    @testset "word_bits" begin
        # Test GPS 1-indexed bit positions
        # GPS bit 1 is MSB, bit 30 is LSB

        word = UInt32(0x3FFFFFFF)  # All 30 bits set
        @test word_bits(word, 1, 30) == 0x3FFFFFFF
        @test word_bits(word, 1, 1) == 1
        @test word_bits(word, 30, 30) == 1
        @test word_bits(word, 1, 8) == 0xFF  # First byte

        # Test specific patterns
        word = UInt32(0b10001011) << 22  # TLM preamble at bits 1-8
        @test word_bits(word, 1, 8) == 0b10001011

        # Subframe ID at bits 20-22
        word = UInt32(0b100) << 8  # Subframe 4
        @test word_bits(word, 20, 22) == 4

        # SV ID at bits 3-8 of word 3
        word = UInt32(55) << 22  # SV ID 55
        @test word_bits(word, 3, 8) == 55
    end

    @testset "invert_bits" begin
        @test invert_bits(UInt32(0), 8) == 0xFF
        @test invert_bits(UInt32(0xFF), 8) == 0x00
        @test invert_bits(UInt32(0b10101010), 8) == 0b01010101
        @test invert_bits(UInt32(0x3FFFFFFF), 30) == 0x00000000
        @test invert_bits(UInt32(0x00000000), 30) == 0x3FFFFFFF
    end

    @testset "round-trip packing" begin
        # Test that packing and extracting preserves data
        original_words = [UInt32(rand(0:0x3FFFFFFF)) for _ in 1:10]
        packed = pack_words_to_bytes(original_words)

        for (i, expected) in enumerate(original_words)
            @test extract_word(packed, i) == expected
        end
    end

    @testset "walking bit test" begin
        # Test each bit position individually
        for bit_pos in 0:29
            words = fill(UInt32(0), 10)
            words[1] = UInt32(1) << bit_pos
            packed = pack_words_to_bytes(words)

            @test extract_word(packed, 1) == UInt32(1) << bit_pos
            # Other words should be zero
            for i in 2:10
                @test extract_word(packed, i) == 0
            end
        end
    end

    @testset "parity - set_word_parity produces valid parity" begin
        # A word with known data bits should pass check after set_word_parity
        for _ in 1:20
            data = UInt32(rand(0:0x00FFFFFF)) << 6  # random data bits, parity clear
            D29 = rand(Bool)
            D30 = rand(Bool)
            word = set_word_parity(data, D29, D30)
            @test check_word_parity(word, D29, D30)
        end
    end

    @testset "parity - check_word_parity detects flipped data bit" begin
        data = UInt32(0x41424300) << 6  # arbitrary data bits
        word = set_word_parity(data, false, false)
        @test check_word_parity(word, false, false)

        # Flip a data bit (GPS bit 10 = position 20)
        corrupted = xor(word, UInt32(1) << 20)
        @test !check_word_parity(corrupted, false, false)
    end

    @testset "parity - compute_parity_bits with all zeros" begin
        # All-zero word with D29*=false, D30*=false should produce zero parity
        @test compute_parity_bits(UInt32(0), false, false) == UInt32(0)
    end

    @testset "parity - D29*/D30* affect result" begin
        word = UInt32(0)
        p1 = compute_parity_bits(word, false, false)
        p2 = compute_parity_bits(word, true, false)
        p3 = compute_parity_bits(word, false, true)
        # With different D29*/D30* inputs, parity should differ
        @test p1 != p2
        @test p1 != p3
    end
end
