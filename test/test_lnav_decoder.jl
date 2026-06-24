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

    @testset "week rollover (TOW count 0)" begin
        # The subframe starting Saturday 23:59:54 carries TOW count 0 (the
        # count names the NEXT subframe start, which is the week epoch), so
        # tow*6-6 = -6 must wrap to seconds-of-day 86394, not stay negative.
        tow = 0
        sod = 86394
        msg = "WEEK ROLLOVER TEST   ."

        # Clean stream, true polarity: identified
        frame = make_special_message_frame(msg; tow=tow)
        @test is_special_message_frame(frame, sod) == true
        @test parse_how(extract_word(frame, 2), sod).inverted == false

        # Clean stream, inverted polarity: inversion must still be detected
        frame_inv = map(~, frame)
        how_inv = parse_how(extract_word(frame_inv, 2), sod)
        @test how_inv.inverted == true
        @test is_special_message_frame(frame_inv, sod) == true
        decoded = decode_frame(frame_inv, Int32(sod), 5, 2024, 100)
        @test decoded.parity_ok == true
        @test decoded.raw_bytes == encode_message_to_bits(msg)

        # D30*-retained stream with complemented HOW: the inverted-TOW
        # match must also wrap correctly
        frame_d30 = make_d30_offair_page17_frame(msg; tow=tow)
        @test is_special_message_frame(frame_d30, sod) == true
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

        # Word 1: TLM preamble (identification of unverifiable frames —
        # this one carries no parity — requires a plausible preamble)
        words[1] = UInt32(0b10001011) << 22

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

    @testset "D30*-complemented Page 17 identification" begin
        test_msg = "D30 PAGE17 IDENT TEST "
        tow = 100
        sod = (tow * 6 - 6) % 86400  # seconds_of_day matching the HOW

        frame = make_d30_offair_page17_frame(test_msg; tow=tow)

        # Guard: the synthetic frame reproduces the real failure mode — the
        # complemented HOW is misread as frame inversion and the clean SV ID
        # 55 then reads as its 6-bit complement
        how_info = parse_how(extract_word(frame, 2), sod)
        @test how_info.subframe_id == 4
        @test how_info.inverted == true
        @test get_sv_id(extract_word(frame, 3), how_info.inverted) == 8

        # Recovery: SV ID under the D30* interpretation reads 55 and parity
        # confirms, so the frame is identified
        @test get_sv_id_d30(frame, how_info.inverted) == 55
        @test is_d30_complemented_page17(frame, how_info) == true
        @test is_special_message_frame(frame, sod) == true

        # parse_frame reports the corrected SV ID and page number
        info = parse_frame(frame, sod)
        @test info.subframe_id == 4
        @test info.sv_id == 55
        @test info.page_number == 17

        # decode_frame extracts the original message
        decoded = decode_frame(frame, Int32(sod), 5, 2024, 100)
        @test decoded.parity_ok == true
        @test decoded.sv_id == 55
        @test startswith(decoded.ascii_message, rstrip(test_msg))

        # Without seconds_of_day the complemented HOW also corrupts the
        # subframe ID read (4 -> 3), so identification requires the TOW
        # context — which the extraction pipeline always provides
        @test is_special_message_frame(frame) == false

        # Negative control: a clean Subframe 4 frame with a genuine SV ID 8
        # must not be identified as Page 17
        words = Vector{UInt32}(undef, 10)
        words[1] = UInt32(0b10001011) << 22
        words[2] = make_how_word(4)
        words[3] = make_word3_subframe4(8)
        for i in 4:10
            words[i] = UInt32(0)
        end
        apply_parity!(words)
        frame_sv8 = pack_words_to_bytes(words)
        @test is_special_message_frame(frame_sv8) == false
        @test parse_frame(frame_sv8).page_number === nothing
        @test parse_frame(frame_sv8).sv_id == 8
    end

    @testset "SV ID 8 aliased to 55 by complemented HOW" begin
        # The mirror image of the previous testset: in a D30*-retained
        # stream with TLM D30 = 1, the complemented HOW is misread as frame
        # inversion, and un-inverting a genuine SV ID 8 page's clean Word 3
        # makes its SV ID read 55. The direct reading must be overruled by
        # the parity-verified D30* interpretation, which reads the true 8.
        tow = 200
        sod = (tow * 6 - 6) % 86400
        frame_sv8 = make_d30_offair_subframe4_frame(8, "NOT A SPECIAL MESSAGE."; tow=tow)

        # Guard: the aliasing is real — the direct read says Page 17
        how_info = parse_how(extract_word(frame_sv8, 2), sod)
        @test how_info.subframe_id == 4
        @test how_info.inverted == true
        @test get_sv_id(extract_word(frame_sv8, 3), how_info.inverted) == 55

        # The parity-verified D30* interpretation reads the true SV ID
        @test get_sv_id_d30(frame_sv8, how_info.inverted) == 8
        @test confirm_direct_page17(frame_sv8, how_info) == false
        @test is_special_message_frame(frame_sv8, sod) == false
        @test parse_frame(frame_sv8, sod).page_number === nothing

        # Genuine Page 17 frames in D30*-retained streams keep identifying
        # through the direct branch when TLM D30 = 0 (Word 3 arrives clean,
        # SV ID reads 55 directly, the D30* interpretation agrees)
        msg = "REAL SPECIAL MESSAGE "
        frame_p17 = make_d30_offair_subframe4_frame(55, msg; tow=tow, tlm_d30=false)
        how_p17 = parse_how(extract_word(frame_p17, 2), sod)
        @test how_p17.inverted == false
        @test get_sv_id(extract_word(frame_p17, 3), how_p17.inverted) == 55
        @test confirm_direct_page17(frame_p17, how_p17) == true
        @test is_special_message_frame(frame_p17, sod) == true
        decoded = decode_frame(frame_p17, Int32(sod), 5, 2024, 100)
        @test decoded.parity_ok == true
        @test decoded.raw_bytes == encode_message_to_bits(msg)

        # And a genuine SV ID 8 page with TLM D30 = 0 reads 8 directly and
        # is rejected on the complement branch (D30* re-read still says 8)
        frame_sv8_clean_how = make_d30_offair_subframe4_frame(8, "ALSO NOT A MESSAGE   ."; tow=tow, tlm_d30=false)
        @test is_special_message_frame(frame_sv8_clean_how, sod) == false
    end

    @testset "unverifiable frames: legacy fallback gated on TLM preamble" begin
        tow = 300
        sod = (tow * 6 - 6) % 86400
        msg = "NOISY FRAME TEST     ."
        frame = make_special_message_frame(msg; tow=tow)

        # One flipped payload bit fails parity under both interpretations,
        # but the frame is still accepted (legacy behaviour for noisy
        # clean-stream frames) and flagged parity_ok = false
        noisy = copy(frame)
        noisy[19] ⊻= 0x10  # a Word 5 data bit
        how_info = parse_how(extract_word(noisy, 2), sod)
        @test check_message_parity(noisy, how_info.inverted, false) == false
        @test check_message_parity(noisy, how_info.inverted, true) == false
        @test is_special_message_frame(noisy, sod) == true
        @test decode_frame(noisy, Int32(sod), 5, 2024, 100).parity_ok == false

        # If the TLM preamble is also implausible, the frame is rejected
        garbage = copy(noisy)
        garbage[1] = 0x00  # preamble bits, neither 0x8B nor its complement
        @test tlm_preamble_plausible(garbage) == false
        @test is_special_message_frame(garbage, sod) == false

        # A complemented preamble (inverted stream) is plausible
        @test tlm_preamble_plausible(map(~, frame)) == true

        # A corrupted preamble alone does not reject a frame whose parity
        # verifies — the gate applies only to the unverifiable fallback
        preamble_only = copy(frame)
        preamble_only[1] = 0x00
        @test is_special_message_frame(preamble_only, sod) == true
        @test decode_frame(preamble_only, Int32(sod), 5, 2024, 100).parity_ok == true
    end

    @testset "stream-state round-trip matrix" begin
        # Page 17 frames must identify and decode in every stream variant:
        # clean (D30* removed) vs D30*-retained, true vs inverted polarity,
        # and (for D30*-retained, where it changes the identification
        # branch) TLM D30 = 0 vs 1. Message content is varied to exercise
        # different D30 patterns through the parity chain.
        det_msg(i) = String([Char(0x20 + mod(11 * i + 7 * j, 95)) for j in 1:22])

        function check_roundtrip(frame, msg, sod; label)
            @test is_special_message_frame(frame, sod)
            decoded = decode_frame(frame, Int32(sod), 5, 2024, 100)
            @test decoded.parity_ok
            @test decoded.raw_bytes == encode_message_to_bits(msg)
        end

        for i in 1:10
            msg = det_msg(i)
            tow = 400 + 50 * i
            sod = tow * 6 - 6

            # Clean stream, both polarities
            clean = make_special_message_frame(msg; tow=tow)
            check_roundtrip(clean, msg, sod; label="clean/true")
            check_roundtrip(map(~, clean), msg, sod; label="clean/inverted")

            # D30*-retained stream: TLM D30 = 0 (direct branch) and
            # TLM D30 = 1 (complement branch), both polarities
            for tlm_d30 in (false, true)
                d30 = make_d30_offair_subframe4_frame(55, msg; tow=tow, tlm_d30=tlm_d30)
                check_roundtrip(d30, msg, sod; label="d30/true/tlm=$tlm_d30")
                check_roundtrip(map(~, d30), msg, sod; label="d30/inverted/tlm=$tlm_d30")
            end
        end
    end
end
