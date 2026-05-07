@testset "LNAV Decoder" begin

    @testset "parse_how" begin
        # Test basic subframe ID extraction
        for sf_id in 1:5
            word = make_how_word(sf_id)
            info = parse_how(word)
            @test info.subframe_id == sf_id
            @test info.alert_flag == false
            @test info.inverted == false
        end

        # Test alert flag
        word_alert = make_how_word(4; alert=true)
        info = parse_how(word_alert)
        @test info.alert_flag == true

        word_no_alert = make_how_word(4; alert=false)
        info = parse_how(word_no_alert)
        @test info.alert_flag == false

        # Test TOW extraction
        word_tow = make_how_word(4; tow=12345)
        info = parse_how(word_tow)
        @test info.tow == 12345
    end

    @testset "get_sv_id" begin
        # Test SV ID extraction
        for sv_id in [1, 25, 32, 51, 55, 56, 63]
            word = make_word3_subframe4(sv_id)
            @test get_sv_id(word, false) == sv_id
        end

        # Test Page 17 SV ID
        word_page17 = make_word3_subframe4(PAGE_17_SV_ID)
        @test get_sv_id(word_page17, false) == 55
    end

    @testset "is_special_message_frame" begin
        # Test positive case: Subframe 4, Page 17
        frame_sf4_p17 = make_special_message_frame("TEST MESSAGE         ")
        @test is_special_message_frame(frame_sf4_p17) == true

        # Test negative cases: other subframes
        for sf_id in [1, 2, 3, 5]
            frame_other = make_non_special_frame(sf_id)
            @test is_special_message_frame(frame_other) == false
        end

        # Test negative case: Subframe 4 but different page
        frame_sf4_other = make_non_special_frame(4)  # Uses SV ID 52
        @test is_special_message_frame(frame_sf4_other) == false
    end

    @testset "extract_special_message_bits" begin
        # Test with known message
        test_message = "ABCDEFGHIJKLMNOPQRSTUV"  # 22 characters
        frame = make_special_message_frame(test_message)

        bits = extract_special_message_bits(frame, false)
        @test length(bits) == 22

        # Decode and verify
        decoded = String([Char(b) for b in bits])
        @test decoded == test_message

        # Test with all spaces
        space_message = "                      "  # 22 spaces
        frame_space = make_special_message_frame(space_message)
        bits_space = extract_special_message_bits(frame_space, false)
        @test all(b -> b == UInt8(' '), bits_space)

        # Test with mixed content
        mixed_message = "GPS 12:34:56 TEST/MSG"
        # Pad to 22 chars
        mixed_padded = rpad(mixed_message, 22)
        frame_mixed = make_special_message_frame(mixed_padded)
        bits_mixed = extract_special_message_bits(frame_mixed, false)
        @test String([Char(b) for b in bits_mixed]) == mixed_padded
    end

    @testset "parse_frame" begin
        # Test Subframe 4, Page 17
        frame_sf4_p17 = make_special_message_frame("TEST")
        info = parse_frame(frame_sf4_p17)
        @test info.subframe_id == 4
        @test info.page_number == 17
        @test info.sv_id == 55

        # Test other subframes
        for sf_id in [1, 2, 3, 5]
            frame = make_non_special_frame(sf_id)
            info = parse_frame(frame)
            @test info.subframe_id == sf_id
        end

        # Test Subframe 4, other page
        frame_sf4_other = make_non_special_frame(4)
        info = parse_frame(frame_sf4_other)
        @test info.subframe_id == 4
        @test info.sv_id == 52
        @test info.page_number === nothing
    end

    @testset "bit positions verification" begin
        # Verify the bit layout matches GPS ICD specification

        # Create a frame with known patterns
        words = fill(UInt32(0), 10)

        # Word 2: Set subframe ID to 4 (bits 20-22 = 100)
        words[2] = make_how_word(4)

        # Word 3: Set SV ID to 55 (bits 3-8)
        words[3] = make_word3_subframe4(55)

        packed = pack_words_to_bytes(words)

        # Verify extraction
        word2 = extract_word(packed, 2)
        @test word_bits(word2, 20, 22) == 4

        word3 = extract_word(packed, 3)
        @test word_bits(word3, 3, 8) == 55

        # Verify is_special_message_frame
        @test is_special_message_frame(packed) == true
    end

    @testset "check_message_parity" begin
        # Valid frame should pass parity
        frame = make_special_message_frame("PARITY TEST FRAME    ")
        @test check_message_parity(frame, false) == true

        # Non-special frame should also pass parity
        frame_other = make_non_special_frame(1)
        @test check_message_parity(frame_other, false) == true

        # Corrupt a message data bit and verify parity fails
        frame_corrupt = copy(frame)
        # Flip a bit in the middle of the frame (byte 10, bit 3)
        frame_corrupt[10] = xor(frame_corrupt[10], UInt8(0x08))
        @test check_message_parity(frame_corrupt, false) == false
    end

    @testset "decode_frame records parity_ok" begin
        # Valid frame should have parity_ok=true
        frame = make_special_message_frame("PARITY OK TEST       ")
        decoded = decode_frame(frame, Int32(3600), 5, 2024, 100)
        @test decoded.parity_ok == true

        # Corrupt a data bit and verify parity_ok=false
        frame_corrupt = copy(frame)
        frame_corrupt[10] = xor(frame_corrupt[10], UInt8(0x08))
        decoded_corrupt = decode_frame(frame_corrupt, Int32(3600), 5, 2024, 100)
        @test decoded_corrupt.parity_ok == false
    end

    @testset "D30* un-complementing via parity" begin
        test_msg = "D30 UNCOMP TEST MSG  "
        msg_bytes = encode_message_to_bits(test_msg)

        # Build a frame WITH D30* complementing (simulating real GPS transmission)
        words = Vector{UInt32}(undef, 10)
        words[1] = UInt32(0b10001011) << 22

        words[2] = make_how_word(4; tow=0, alert=false)

        words[3] = make_word3_subframe4(55)
        for i in 0:15
            byte_idx = (i >> 3) + 1
            bit_in_byte = 7 - (i & 7)
            if (msg_bytes[byte_idx] >> bit_in_byte) & 1 == 1
                words[3] |= UInt32(1) << (21 - i)
            end
        end

        msg_bit_cursor = 16
        for word_idx in 4:9
            words[word_idx] = UInt32(0)
            for i in 0:23
                byte_idx = ((msg_bit_cursor + i) >> 3) + 1
                bit_in_byte = 7 - ((msg_bit_cursor + i) & 7)
                if byte_idx <= 22 && (msg_bytes[byte_idx] >> bit_in_byte) & 1 == 1
                    words[word_idx] |= UInt32(1) << (29 - i)
                end
            end
            msg_bit_cursor += 24
        end

        words[10] = UInt32(0)
        for i in 0:15
            byte_idx = ((msg_bit_cursor + i) >> 3) + 1
            bit_in_byte = 7 - ((msg_bit_cursor + i) & 7)
            if byte_idx <= 22 && (msg_bytes[byte_idx] >> bit_in_byte) & 1 == 1
                words[10] |= UInt32(1) << (29 - i)
            end
        end

        # Apply parity WITH D30* complementing
        apply_parity_with_d30_complementing!(words)
        d30_frame = pack_words_to_bytes(words)

        # Parity should FAIL without D30* un-complementing (data bits are complemented)
        # but only if D30* was actually applied (D30 of some word was 1)
        parity_direct = check_message_parity(d30_frame, false, false)
        parity_d30 = check_message_parity(d30_frame, false, true)

        # At least one mode should pass
        @test parity_direct || parity_d30

        # If D30* was actually applied, the D30 path should pass
        if !parity_direct
            @test parity_d30 == true
        end

        # decode_frame should correctly decode the message using parity-based detection
        decoded = decode_frame(d30_frame, Int32(0), 5, 2024, 100)
        @test decoded.parity_ok == true
        @test startswith(decoded.ascii_message, rstrip(test_msg))
    end
end
