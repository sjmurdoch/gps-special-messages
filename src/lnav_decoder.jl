# LNAV frame parsing for GPS navigation messages
# Identifies Subframe 4, Page 17 (Special Messages) and extracts message bits

# GPS LNAV constants
const SUBFRAME_4 = 4
const PAGE_17_SV_ID = 55  # SV ID 55 identifies Page 17 in Subframe 4
const TLM_PREAMBLE = UInt32(0b10001011)  # Word 1 bits 1-8 (IS-GPS-200 §20.3.3.1)

"""
    SubframeInfo

Parsed information from the Handover Word (HOW, Word 2).
"""
struct SubframeInfo
    subframe_id::Int
    alert_flag::Bool
    tow::Int  # Time of Week count (17 bits)
    inverted::Bool  # Whether bits appear to be inverted
end

"""
    parse_how(word2::UInt32, expected_tow::Union{Int,Nothing}=nothing) -> SubframeInfo

Parse the Handover Word (Word 2) to extract subframe ID, alert flag, and TOW.

Word 2 structure (30 bits):
- Bits 1-17: Time of Week (TOW) count
- Bit 18: Alert flag
- Bit 19: Anti-spoof flag
- Bits 20-22: Subframe ID
- Bits 23-24: Reserved (parity computation)
- Bits 25-30: Parity

If `expected_tow` is provided, it's used to detect bit inversion.
"""
function parse_how(word2::UInt32, expected_tow::Union{Int,Nothing}=nothing)::SubframeInfo
    # Extract fields (GPS 1-indexed bit positions)
    tow_raw = word_bits(word2, 1, 17)
    alert_flag_bit = word_bits(word2, 18, 18)
    subframe_id_raw = word_bits(word2, 20, 22)

    # Check for bit inversion by comparing TOW if expected value provided
    inverted = false
    if expected_tow !== nothing
        # TOW in HOW is actual TOW / 6, and represents the TOW at the START of the NEXT subframe
        # So transmitted TOW * 6 - 6 should equal seconds of day mod 604800
        # mod, not %: TOW count 0 (frame starting at week rollover) gives
        # -6, which must wrap to 86394, not stay negative
        computed_tow = mod(Int(tow_raw) * 6 - 6, 86400)
        if computed_tow != expected_tow
            # Try inverted
            tow_inverted = invert_bits(tow_raw, 17)
            computed_tow_inv = mod(Int(tow_inverted) * 6 - 6, 86400)
            if computed_tow_inv == expected_tow
                inverted = true
            end
        end
    end

    if inverted
        tow = Int(invert_bits(tow_raw, 17))
        alert_flag = alert_flag_bit == 0  # Inverted
        subframe_id = Int(invert_bits(subframe_id_raw, 3))
    else
        tow = Int(tow_raw)
        alert_flag = alert_flag_bit == 1
        subframe_id = Int(subframe_id_raw)
    end

    return SubframeInfo(subframe_id, alert_flag, tow, inverted)
end

"""
    get_sv_id(word3::UInt32, inverted::Bool=false) -> Int

Extract SV ID from Word 3 of Subframe 4 or 5.

Word 3 structure for Subframe 4:
- Bits 1-2: Data ID
- Bits 3-8: SV ID (6 bits)
- Bits 9-24: Page-specific data
- Bits 25-30: Parity
"""
function get_sv_id(word3::UInt32, inverted::Bool=false)::Int
    sv_id_raw = word_bits(word3, 3, 8)
    if inverted
        return Int(invert_bits(sv_id_raw, 6))
    else
        return Int(sv_id_raw)
    end
end

"""
    get_sv_id_d30(packed::AbstractVector{UInt8}, inverted::Bool) -> Int

Extract the SV ID from Word 3 under the interpretation that the stored stream
retains on-air D30* complementing: Word 3's data bits are complemented iff the
stored Word 2's D30 (after frame un-inversion) is 1.
"""
function get_sv_id_d30(packed::AbstractVector{UInt8}, inverted::Bool)::Int
    word2 = extract_word(packed, 2)
    word3 = extract_word(packed, 3)
    if inverted
        word2 = invert_bits(word2, 30)
        word3 = invert_bits(word3, 30)
    end
    if isodd(word2)
        word3 = xor(word3, DATA_BITS_MASK)
    end
    return Int(word_bits(word3, 3, 8))
end

"""
    is_d30_complemented_page17(packed::AbstractVector{UInt8}, how_info::SubframeInfo) -> Bool

Detect a Page 17 frame in a stream that retains on-air D30* complementing.

In such streams the TLM word's D30* can complement the HOW's data bits, which
the TOW check in `parse_how` misreads as frame inversion; `get_sv_id` then
inverts Word 3's clean SV ID, so 55 reads as its 6-bit complement (8). The same
complemented reading arises from a polarity-inverted D30* stream whose HOW
complementing masks the inversion. Both cases are confirmed by re-reading the
SV ID under the D30* interpretation and checking parity with D30*
un-complementing (which is invariant to the inversion flag).
"""
function is_d30_complemented_page17(packed::AbstractVector{UInt8}, how_info::SubframeInfo)::Bool
    if get_sv_id_d30(packed, how_info.inverted) != PAGE_17_SV_ID
        return false
    end
    return check_message_parity(packed, how_info.inverted, true)
end

"""
    tlm_preamble_plausible(packed::AbstractVector{UInt8}) -> Bool

Check that Word 1 starts with the TLM preamble (10001011) in either polarity.

The TLM word is never D30*-complemented on air — IS-GPS-200 solves each
subframe's final word so its D29/D30 are 0 — so in any stream variant the
stored preamble is either the true value or its polarity complement.
"""
function tlm_preamble_plausible(packed::AbstractVector{UInt8})::Bool
    preamble = word_bits(extract_word(packed, 1), 1, 8)
    return preamble == TLM_PREAMBLE || preamble == (TLM_PREAMBLE ⊻ 0xFF)
end

"""
    confirm_direct_page17(packed::AbstractVector{UInt8}, how_info::SubframeInfo) -> Bool

Confirm a Subframe 4 frame whose SV ID reads 55 directly, by re-reading it
under the stream interpretation that passes parity.

The direct reading can lie in one case: a genuine SV ID 8 page in a
D30*-retained stream whose TLM D30 is 1. The complemented HOW is misread as
frame inversion, and un-inverting the (actually clean) Word 3 aliases SV ID
8 to 55 — the mirror image of the aliasing handled by
[`is_d30_complemented_page17`](@ref). Parity arbitrates: if the direct
interpretation passes, the reading stands; if only the D30* interpretation
passes, the SV ID re-read under it is authoritative and the alias is
rejected. If neither passes (bit errors), the direct reading is kept when
the TLM preamble is plausible — preserving legacy behaviour for noisy
frames, which downstream code flags with `parity_ok = false` — and
rejected otherwise (multi-error garbage).
"""
function confirm_direct_page17(packed::AbstractVector{UInt8}, how_info::SubframeInfo)::Bool
    if check_message_parity(packed, how_info.inverted, false)
        return true
    elseif check_message_parity(packed, how_info.inverted, true)
        return get_sv_id_d30(packed, how_info.inverted) == PAGE_17_SV_ID
    else
        return tlm_preamble_plausible(packed)
    end
end

"""
    is_special_message_frame(packed::AbstractVector{UInt8}, seconds_of_day::Union{Int,Nothing}=nothing) -> Bool

Check if the packed navbits represent a Subframe 4, Page 17 frame (Special Message).

Returns true if:
1. Word 2 indicates Subframe ID = 4
2. Word 3 indicates SV ID = 55 (Page 17) under the parity-verified stream
   interpretation: a direct read of 55 confirmed by
   [`confirm_direct_page17`](@ref), or a read of 55's 6-bit complement
   confirmed by [`is_d30_complemented_page17`](@ref)
"""
function is_special_message_frame(packed::AbstractVector{UInt8}, seconds_of_day::Union{Int,Nothing}=nothing)::Bool
    word2 = extract_word(packed, 2)
    how_info = parse_how(word2, seconds_of_day)

    if how_info.subframe_id != SUBFRAME_4
        return false
    end

    word3 = extract_word(packed, 3)
    sv_id = get_sv_id(word3, how_info.inverted)

    if sv_id == PAGE_17_SV_ID
        return confirm_direct_page17(packed, how_info)
    end

    # A D30*-complemented Page 17 reads as the 6-bit complement of 55
    if sv_id == Int(PAGE_17_SV_ID ⊻ 0x3F)
        return is_d30_complemented_page17(packed, how_info)
    end

    return false
end

"""
    check_message_parity(packed::AbstractVector{UInt8}, inverted::Bool, d30_uncomp::Bool=false) -> Bool

Check parity of Words 2-10 in a packed LNAV frame. Word 1 is not checked
(no previous subframe available) but its D29/D30 are used to seed the chain.
If `inverted` is true, each word is un-inverted before checking.

If `d30_uncomp` is true, each word's data bits (1-24) are un-complemented
based on D30* from the previous word before checking parity (IS-GPS-200
D30* complementing). This is needed when the stored data still has D30*
complementing applied.

Returns false if any word fails the parity check.
"""
function check_message_parity(packed::AbstractVector{UInt8}, inverted::Bool, d30_uncomp::Bool=false)::Bool
    # Extract Word 1, un-invert if needed, get D29/D30
    word1 = extract_word(packed, 1)
    if inverted
        word1 = invert_bits(word1, 30)
    end
    D29_star = isodd(word1 >> 1)
    D30_star = isodd(word1)

    # Check Words 2-10
    for word_idx in 2:10
        word = extract_word(packed, word_idx)
        if inverted
            word = invert_bits(word, 30)
        end
        # Un-complement data bits if D30* mode is active and previous D30 was set
        if d30_uncomp && D30_star
            word = xor(word, DATA_BITS_MASK)
        end
        if !check_word_parity(word, D29_star, D30_star)
            return false
        end
        # D29/D30 are parity bits (positions 1,0) — not affected by DATA_BITS_MASK
        D29_star = isodd(word >> 1)
        D30_star = isodd(word)
    end

    return true
end

"""
    extract_special_message_bits(packed::AbstractVector{UInt8}, inverted::Bool=false, d30_uncomp::Bool=false) -> Vector{UInt8}

Extract the 176 bits (22 bytes) of special message content from a Page 17 frame.

If `inverted` is true and `d30_uncomp` is false, data bits are inverted during
extraction (legacy frame-inversion handling).

If `d30_uncomp` is true, frame inversion and D30* un-complementing are both
applied at the word level before extraction. This produces the original source
data bits without needing per-character inversion.

Special message bits location:
- Word 3: bits 9-24 (16 bits)
- Word 4: bits 1-24 (24 bits)
- Word 5: bits 1-24 (24 bits)
- Word 6: bits 1-24 (24 bits)
- Word 7: bits 1-24 (24 bits)
- Word 8: bits 1-24 (24 bits)
- Word 9: bits 1-24 (24 bits)
- Word 10: bits 1-16 (16 bits)
Total: 16 + 6*24 + 16 = 176 bits = 22 characters
"""
function extract_special_message_bits(packed::AbstractVector{UInt8}, inverted::Bool=false, d30_uncomp::Bool=false)::Vector{UInt8}
    result = zeros(UInt8, 22)

    if d30_uncomp
        # Word-level path: un-invert entire word, then un-complement D30*.
        # Word 3 is un-complemented by Word 2's D30; Word 1 is not needed
        # because D30 is a parity bit, never complemented on air.
        word2 = extract_word(packed, 2)
        if inverted
            word2 = invert_bits(word2, 30)
        end
        # D30 is a parity bit (position 0), not affected by DATA_BITS_MASK
        prev_D30 = isodd(word2)

        # Word 3: bits 9-24 (16 bits)
        word3 = extract_word(packed, 3)
        if inverted
            word3 = invert_bits(word3, 30)
        end
        if prev_D30
            word3 = xor(word3, DATA_BITS_MASK)
        end
        bit_cursor = _add_bits_to_buffer!(result, 0, word_bits(word3, 9, 24), 16, false)
        prev_D30 = isodd(word3)

        # Words 4-9: bits 1-24 (24 bits each)
        for word_idx in 4:9
            word = extract_word(packed, word_idx)
            if inverted
                word = invert_bits(word, 30)
            end
            if prev_D30
                word = xor(word, DATA_BITS_MASK)
            end
            bit_cursor = _add_bits_to_buffer!(result, bit_cursor, word_bits(word, 1, 24), 24, false)
            prev_D30 = isodd(word)
        end

        # Word 10: bits 1-16 (16 bits)
        word10 = extract_word(packed, 10)
        if inverted
            word10 = invert_bits(word10, 30)
        end
        if prev_D30
            word10 = xor(word10, DATA_BITS_MASK)
        end
        _add_bits_to_buffer!(result, bit_cursor, word_bits(word10, 1, 16), 16, false)
    else
        # Simple path: extract data bits, inverting if frame is inverted
        word3 = extract_word(packed, 3)
        bit_cursor = _add_bits_to_buffer!(result, 0, word_bits(word3, 9, 24), 16, inverted)

        for word_idx in 4:9
            word = extract_word(packed, word_idx)
            bit_cursor = _add_bits_to_buffer!(result, bit_cursor, word_bits(word, 1, 24), 24, inverted)
        end

        word10 = extract_word(packed, 10)
        _add_bits_to_buffer!(result, bit_cursor, word_bits(word10, 1, 16), 16, inverted)
    end

    return result
end

"""
    _add_bits_to_buffer!(buffer::Vector{UInt8}, bit_cursor::Int, value::UInt32, num_bits::Int, inverted::Bool) -> Int

Helper function to add bits to a buffer at the current bit position.
Returns the updated bit_cursor position. This is a separate function to avoid
closure overhead and ensure type stability.
"""
@inline function _add_bits_to_buffer!(buffer::Vector{UInt8}, bit_cursor::Int, value::UInt32, num_bits::Int, inverted::Bool)::Int
    val = inverted ? invert_bits(value, num_bits) : value
    cursor = bit_cursor
    for i in (num_bits - 1):-1:0
        byte_idx = (cursor >> 3) + 1
        bit_in_byte = 7 - (cursor & 7)
        if ((val >> i) & 1) == 1
            buffer[byte_idx] |= UInt8(1) << bit_in_byte
        end
        cursor += 1
    end
    return cursor
end

"""
    FrameInfo

Complete parsed information about a navigation frame.
"""
struct FrameInfo
    subframe_id::Int
    page_number::Union{Int,Nothing}  # Only for subframes 4 and 5
    sv_id::Union{Int,Nothing}
    alert_flag::Bool
    tow::Int
    inverted::Bool
end

"""
    parse_frame(packed::AbstractVector{UInt8}, seconds_of_day::Union{Int,Nothing}=nothing) -> FrameInfo

Parse a navigation frame to extract all identification information.
"""
function parse_frame(packed::AbstractVector{UInt8}, seconds_of_day::Union{Int,Nothing}=nothing)::FrameInfo
    word2 = extract_word(packed, 2)
    how_info = parse_how(word2, seconds_of_day)

    sv_id = nothing
    page_number = nothing

    if how_info.subframe_id in (4, 5)
        word3 = extract_word(packed, 3)
        sv_id = get_sv_id(word3, how_info.inverted)

        # Map SV ID to page number for Subframe 4
        if how_info.subframe_id == 4
            if sv_id == PAGE_17_SV_ID && confirm_direct_page17(packed, how_info)
                page_number = 17
            elseif sv_id == Int(PAGE_17_SV_ID ⊻ 0x3F) &&
                   is_d30_complemented_page17(packed, how_info)
                sv_id = PAGE_17_SV_ID
                page_number = 17
            end
        end
    end

    return FrameInfo(
        how_info.subframe_id,
        page_number,
        sv_id,
        how_info.alert_flag,
        how_info.tow,
        how_info.inverted
    )
end
