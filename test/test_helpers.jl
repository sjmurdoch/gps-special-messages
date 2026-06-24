# Test helper functions for GPS Special Messages tests

using Arrow
using DataFrames
using JSON3

"""
    pack_words_to_bytes(words::Vector{UInt32}) -> Vector{UInt8}

Pack 10 x 30-bit words into 38 bytes (300 bits), MSB first.
This is the inverse of reconstruct_navbits in convert_nc_to_arrow.jl.
"""
function pack_words_to_bytes(words::Vector{UInt32})::Vector{UInt8}
    @assert length(words) == 10 "Expected 10 words, got $(length(words))"

    bytes = zeros(UInt8, 38)
    bit_cursor = 0

    for word in words
        for b_idx in 29:-1:0
            if (word >> b_idx) & 1 == 1
                byte_pos = (bit_cursor >> 3) + 1
                bit_in_byte = 7 - (bit_cursor & 7)
                bytes[byte_pos] |= UInt8(1) << bit_in_byte
            end
            bit_cursor += 1
        end
    end

    return bytes
end

"""
    make_word(bits::String) -> UInt32

Create a 30-bit word from a binary string.
Pads with zeros on the right if less than 30 bits.
"""
function make_word(bits::String)::UInt32
    # Pad to 30 bits
    padded = rpad(bits, 30, '0')
    @assert length(padded) == 30 "Binary string too long: $(length(bits)) bits"
    return parse(UInt32, padded; base=2)
end

"""
    make_how_word(subframe_id::Int; tow::Int=0, alert::Bool=false) -> UInt32

Create a Hand-Over Word (Word 2) with the specified subframe ID.

HOW structure (30 bits):
- Bits 1-17: TOW count
- Bit 18: Alert flag
- Bit 19: Anti-spoof flag (set to 0)
- Bits 20-22: Subframe ID
- Bits 23-24: Reserved (0)
- Bits 25-30: Parity (set to 0 for testing)
"""
function make_how_word(subframe_id::Int; tow::Int=0, alert::Bool=false)::UInt32
    @assert 1 <= subframe_id <= 5 "Subframe ID must be 1-5"

    word = UInt32(0)

    # TOW (bits 1-17, positions 29-13 in 0-indexed)
    word |= (UInt32(tow) & 0x1FFFF) << 13

    # Alert flag (bit 18, position 12)
    if alert
        word |= UInt32(1) << 12
    end

    # Subframe ID (bits 20-22, positions 10-8)
    word |= (UInt32(subframe_id) & 0x7) << 8

    return word
end

"""
    make_word3_subframe4(sv_id::Int; data_id::Int=1) -> UInt32

Create Word 3 for Subframe 4 with the specified SV ID.

Word 3 structure for Subframe 4:
- Bits 1-2: Data ID
- Bits 3-8: SV ID
- Bits 9-24: Page-specific data (zeros for testing)
- Bits 25-30: Parity (zeros for testing)
"""
function make_word3_subframe4(sv_id::Int; data_id::Int=1)::UInt32
    word = UInt32(0)

    # Data ID (bits 1-2, positions 29-28)
    word |= (UInt32(data_id) & 0x3) << 28

    # SV ID (bits 3-8, positions 27-22)
    word |= (UInt32(sv_id) & 0x3F) << 22

    return word
end

"""
    encode_message_to_bits(message::String) -> Vector{UInt8}

Encode a 22-character string to 22 bytes using GPS character encoding.
"""
function encode_message_to_bits(message::String)::Vector{UInt8}
    # Pad or truncate to 22 characters
    padded = rpad(message, 22)[1:22]
    return [UInt8(c) for c in padded]
end

"""
    apply_parity!(words::Vector{UInt32})

Apply correct GPS LNAV parity to all 10 words in sequence.
Word 1 uses D29*=false, D30*=false (no previous subframe).
Each subsequent word uses D29/D30 from the previous word.

Note: This does NOT apply D30* complementing (which a real GPS transmitter would).
The stored GFZ data has D30* complementing already removed.
"""
function apply_parity!(words::Vector{UInt32})
    words[1] = set_word_parity(words[1], false, false)
    for i in 2:10
        D29_star = isodd(words[i-1] >> 1)
        D30_star = isodd(words[i-1])
        words[i] = set_word_parity(words[i], D29_star, D30_star)
    end
end

"""
    apply_parity_with_d30_complementing!(words::Vector{UInt32})

Apply GPS LNAV parity AND D30* complementing to simulate real GPS transmission.
After setting parity, data bits 1-24 of each word are complemented if D30*
of the previous word is 1 (as a real GPS transmitter does).
"""
function apply_parity_with_d30_complementing!(words::Vector{UInt32})
    words[1] = set_word_parity(words[1], false, false)
    for i in 2:10
        D29_star = isodd(words[i-1] >> 1)
        D30_star = isodd(words[i-1])
        words[i] = set_word_parity(words[i], D29_star, D30_star)
        if D30_star
            words[i] = xor(words[i], DATA_BITS_MASK)
        end
    end
end

"""
    make_special_message_words(message::String; tow::Int=0, alert::Bool=false) -> Vector{UInt32}

Build the 10 data words of a Subframe 4, Page 17 frame with the given message.
Parity is NOT applied; callers apply `apply_parity!` or
`apply_parity_with_d30_complementing!` as needed.
"""
function make_special_message_words(message::String; tow::Int=0, alert::Bool=false)::Vector{UInt32}
    msg_bytes = encode_message_to_bits(message)

    # Build 10 words
    words = Vector{UInt32}(undef, 10)

    # Word 1: TLM (preamble + reserved)
    words[1] = UInt32(0b10001011) << 22  # Preamble in bits 1-8

    # Word 2: HOW with Subframe 4
    words[2] = make_how_word(4; tow=tow, alert=alert)

    # Word 3: SV ID 55 (Page 17) + first 16 bits of message (bits 9-24)
    words[3] = make_word3_subframe4(55)
    # Add message bits 0-15 to positions 21-6 (GPS bits 9-24)
    for i in 0:15
        byte_idx = (i >> 3) + 1
        bit_in_byte = 7 - (i & 7)
        if (msg_bytes[byte_idx] >> bit_in_byte) & 1 == 1
            words[3] |= UInt32(1) << (21 - i)
        end
    end

    # Words 4-9: 24 bits each of message
    msg_bit_cursor = 16  # Start after first 16 bits
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

    # Word 10: Last 16 bits of message (bits 1-16)
    words[10] = UInt32(0)
    for i in 0:15
        byte_idx = ((msg_bit_cursor + i) >> 3) + 1
        bit_in_byte = 7 - ((msg_bit_cursor + i) & 7)
        if byte_idx <= 22 && (msg_bytes[byte_idx] >> bit_in_byte) & 1 == 1
            words[10] |= UInt32(1) << (29 - i)
        end
    end

    return words
end

"""
    make_special_message_frame(message::String; tow::Int=0, alert::Bool=false) -> Vector{UInt8}

Create a complete Subframe 4, Page 17 frame with the given message.
Returns 38 bytes of packed navbits with valid parity on all words.
"""
function make_special_message_frame(message::String; tow::Int=0, alert::Bool=false)::Vector{UInt8}
    words = make_special_message_words(message; tow=tow, alert=alert)

    # Apply valid parity to all words
    apply_parity!(words)

    return pack_words_to_bytes(words)
end

"""
    make_d30_offair_subframe4_frame(sv_id::Int, message::String; tow::Int=0, tlm_d30::Bool=true) -> Vector{UInt8}

Create a Subframe 4 frame with the given SV ID as it appears in a raw off-air
stream that retains on-air D30* complementing. The TLM word's D30 is forced to
`tlm_d30`; when 1, the HOW's data bits (including the TOW) are complemented on
air. The HOW's reserved bits 23-24 are solved so Word 2's transmitted
D29/D30 = 0, as IS-GPS-200 requires. The message payload occupies the Page 17
bit positions regardless of SV ID (for non-55 SV IDs it stands in for
arbitrary page data).
"""
function make_d30_offair_subframe4_frame(sv_id::Int, message::String;
                                         tow::Int=0, tlm_d30::Bool=true)::Vector{UInt8}
    words = make_special_message_words(message; tow=tow)
    words[3] = (words[3] & ~(UInt32(0x3F) << 22)) | ((UInt32(sv_id) & 0x3F) << 22)

    # Force TLM D30 to the requested value by toggling reserved data bits
    # (bit 24, position 6, participates in the D30 parity equation)
    for k in 0:3
        cand = (words[1] & ~(UInt32(0x3) << 6)) | (UInt32(k) << 6)
        if isodd(set_word_parity(cand, false, false)) == tlm_d30
            words[1] = cand
            break
        end
    end
    word1 = set_word_parity(words[1], false, false)
    @assert isodd(word1) == tlm_d30 "Could not force TLM D30 = $tlm_d30"

    # Solve HOW bits 23-24 so Word 2's transmitted D29/D30 = 0
    d29s = isodd(word1 >> 1)
    d30s = isodd(word1)
    for t in 0:3
        cand = (words[2] & ~(UInt32(0x3) << 6)) | (UInt32(t) << 6)
        if set_word_parity(cand, d29s, d30s) & 0x3 == 0
            words[2] = cand
            break
        end
    end
    @assert set_word_parity(words[2], d29s, d30s) & 0x3 == 0 "Could not solve HOW D29/D30 = 0"

    apply_parity_with_d30_complementing!(words)

    return pack_words_to_bytes(words)
end

"""
    make_d30_offair_page17_frame(message::String; tow::Int=0) -> Vector{UInt8}

Create a Subframe 4, Page 17 frame in a D30*-retained stream with TLM D30 = 1.
This reproduces the stream variant where `parse_how` misreads the complemented
TOW as frame inversion and Page 17's SV ID reads as the 6-bit complement of 55.
"""
make_d30_offair_page17_frame(message::String; tow::Int=0) =
    make_d30_offair_subframe4_frame(55, message; tow=tow, tlm_d30=true)

"""
    make_non_special_frame(subframe_id::Int; tow::Int=0) -> Vector{UInt8}

Create a navigation frame that is NOT a special message frame.
"""
function make_non_special_frame(subframe_id::Int; tow::Int=0)::Vector{UInt8}
    words = Vector{UInt32}(undef, 10)

    # Word 1: TLM
    words[1] = UInt32(0b10001011) << 22

    # Word 2: HOW with specified subframe
    words[2] = make_how_word(subframe_id; tow=tow)

    # Word 3: For subframe 4, use a different SV ID
    if subframe_id == 4
        words[3] = make_word3_subframe4(52)  # SV ID 52, not 55
    else
        words[3] = UInt32(0)
    end

    # Words 4-10: Zeros
    for i in 4:10
        words[i] = UInt32(0)
    end

    # Apply valid parity to all words
    apply_parity!(words)

    return pack_words_to_bytes(words)
end

"""
    create_test_arrow_file(path::String, frames::Vector{Vector{UInt8}}, times::Vector{Int32};
                           year::Int=2024, day_of_year::Int=100, prn::Int=5) -> Nothing

Create a test Arrow file with the given frames and metadata.
"""
function create_test_arrow_file(path::String, frames::Vector{Vector{UInt8}}, times::Vector{Int32};
                                year::Int=2024, day_of_year::Int=100, prn::Int=5)
    @assert length(frames) == length(times)

    df = DataFrame(
        time = times,
        multiplicity = ones(Int32, length(times)),
        navbits = frames
    )

    metadata = Dict{String,Any}(
        "year" => year,
        "day_of_year" => day_of_year,
        "prn" => prn,
        "gps_week" => 2200,
        "source_file" => "test.nc"
    )

    metadata_json = JSON3.write(metadata)

    Arrow.write(
        path,
        df;
        compress = :zstd,
        metadata = ["netcdf_metadata" => metadata_json]
    )
end

"""
    get_test_metadata(path::String) -> FileMetadata

Get metadata from an Arrow file. Helper function for tests.
"""
function get_test_metadata(path::String)::FileMetadata
    tbl = Arrow.Table(path)
    return get_file_metadata(tbl)
end

"""
    extract_messages(path::String) -> Vector{DecodedSpecialMessage}

Test convenience wrapper around `extract_messages_from_file`. Returns the
list of decoded messages, or an empty vector if the file has none.
"""
function extract_messages(path::String)::Vector{DecodedSpecialMessage}
    batch = extract_messages_from_file(path)
    batch === nothing ? DecodedSpecialMessage[] : batch.messages
end

"""
    extract_messages_from_dir(dir::String) -> Vector{DecodedSpecialMessage}

Test convenience wrapper around `extract_all_messages` that returns a flat
vector of decoded messages across all `*.arrow` files in `dir`.
"""
function extract_messages_from_dir(dir::String)::Vector{DecodedSpecialMessage}
    batches = extract_all_messages(dir; verbose=false, use_threads=false)
    return reduce(vcat, (b.messages for b in batches); init=DecodedSpecialMessage[])
end

"""
    cleanup_test_db(db, paths...)

Safely close a DuckDB connection and remove database/temp files.
Handles Windows file-locking by retrying deletion after GC.
"""
function cleanup_test_db(db, paths...)
    try; close(db); catch; end
    GC.gc()
    for path in paths
        for attempt in 1:5
            try
                rm(path, force=true)
                break
            catch e
                e isa Base.IOError || rethrow()
                attempt < 5 && sleep(0.1)
            end
        end
    end
end
