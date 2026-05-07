@testset "ASCII Decoder" begin

    @testset "CP437 to UTF-8 conversion" begin
        # Test ASCII characters (same in CP437 and Unicode)
        @test CP437_TO_UNICODE[Int('A') + 1] == 'A'
        @test CP437_TO_UNICODE[Int('Z') + 1] == 'Z'
        @test CP437_TO_UNICODE[Int('0') + 1] == '0'
        @test CP437_TO_UNICODE[Int('9') + 1] == '9'
        @test CP437_TO_UNICODE[Int(' ') + 1] == ' '

        # Test degree symbol (248 in CP437 = ° in Unicode)
        @test CP437_TO_UNICODE[248 + 1] == '°'

        # Test some extended CP437 characters
        @test CP437_TO_UNICODE[1 + 1] == '☺'   # Smiley face
        @test CP437_TO_UNICODE[2 + 1] == '☻'   # Dark smiley face
        @test CP437_TO_UNICODE[3 + 1] == '♥'   # Heart
        @test CP437_TO_UNICODE[128 + 1] == 'Ç' # C-cedilla
        @test CP437_TO_UNICODE[225 + 1] == 'ß' # German eszett
    end

    @testset "decode_special_message" begin
        # Test simple messages
        msg = "ABCDEFGHIJKLMNOPQRSTUV"
        bytes = [UInt8(c) for c in msg]
        @test decode_special_message(bytes) == msg

        # Test all spaces
        space_msg = "                      "
        space_bytes = fill(UInt8(' '), 22)
        @test decode_special_message(space_bytes) == space_msg

        # Test with digits and special chars
        mixed = "GPS 12:34 TEST/MSG+1 "  # 21 chars, pad to 22
        mixed_padded = rpad(mixed, 22)
        mixed_bytes = [UInt8(c) for c in mixed_padded]
        @test decode_special_message(mixed_bytes) == mixed_padded

        # Test with degree symbol (CP437 byte 248 -> UTF-8 °)
        deg_bytes = fill(UInt8(' '), 22)
        deg_bytes[1] = UInt8('N')
        deg_bytes[2] = UInt8(248)  # degree symbol
        deg_bytes[3] = UInt8('W')
        @test decode_special_message(deg_bytes) == "N°W                   "

        # Test with extended characters (all bytes decode directly as CP437)
        extended_bytes = fill(UInt8(' '), 22)
        extended_bytes[1] = UInt8(0)    # null -> replacement character
        extended_bytes[2] = UInt8(1)    # ☺
        extended_bytes[3] = UInt8(0xFF) # CP437 0xFF = non-breaking space
        result = decode_special_message(extended_bytes)
        chars = collect(result)  # Convert to character array for indexing
        @test chars[1] == '�'
        @test chars[2] == '☺'
        @test chars[3] == ' '  # CP437 0xFF maps to space

        # Test length validation
        @test_throws ArgumentError decode_special_message(UInt8[1, 2, 3])
    end

    @testset "make_datetime" begin
        # Test basic conversion
        dt = make_datetime(2024, 1, 0)
        @test Dates.year(dt) == 2024
        @test Dates.month(dt) == 1
        @test Dates.day(dt) == 1
        @test Dates.hour(dt) == 0
        @test Dates.minute(dt) == 0
        @test Dates.second(dt) == 0

        # Test mid-year date
        dt2 = make_datetime(2024, 100, 3661)  # 1 hour, 1 minute, 1 second
        @test Dates.dayofyear(dt2) == 100
        @test Dates.hour(dt2) == 1
        @test Dates.minute(dt2) == 1
        @test Dates.second(dt2) == 1

        # Test end of day
        dt3 = make_datetime(2024, 1, 86399)  # 23:59:59
        @test Dates.hour(dt3) == 23
        @test Dates.minute(dt3) == 59
        @test Dates.second(dt3) == 59
    end

    @testset "decode_frame" begin
        test_message = "GPS SPECIAL MESSAGE  "  # 21 chars + space
        frame = make_special_message_frame(test_message)

        decoded = decode_frame(frame, Int32(3600), 5, 2024, 100)

        @test decoded.time == 3600
        @test decoded.prn == 5
        @test decoded.sv_id == 55
        @test Dates.year(decoded.datetime) == 2024
        @test Dates.dayofyear(decoded.datetime) == 100
        @test Dates.hour(decoded.datetime) == 1

        # Trim and compare (message may have trailing chars)
        @test startswith(decoded.ascii_message, rstrip(test_message))
    end

    @testset "format_message" begin
        test_message = "TEST MESSAGE         "
        frame = make_special_message_frame(test_message)
        decoded = decode_frame(frame, Int32(43200), 12, 2024, 150)

        formatted = format_message(decoded)

        @test occursin("2024", formatted)
        @test occursin("PRN=12", formatted)
        @test occursin("SV_ID=55", formatted)
        @test occursin("Alert=0", formatted)
        @test occursin("Message=", formatted)
    end

    @testset "DecodedSpecialMessage show" begin
        test_message = "SHOW TEST            "
        frame = make_special_message_frame(test_message)
        decoded = decode_frame(frame, Int32(0), 1, 2024, 1)

        # Test that show doesn't error
        io = IOBuffer()
        show(io, decoded)
        output = String(take!(io))

        @test !isempty(output)
        @test occursin("PRN=", output)
    end
end
