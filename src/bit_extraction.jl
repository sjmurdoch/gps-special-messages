# Bit extraction utilities for GPS LNAV navigation messages
# Navbits are packed as 10 words x 30 bits = 300 bits in 38 bytes (MSB first)

"""
    extract_bits(bytes::AbstractVector{UInt8}, start_bit::Int, num_bits::Int) -> UInt32

Extract `num_bits` bits starting at `start_bit` (0-indexed, MSB-first) from packed bytes.
Returns the extracted bits as a UInt32.

The bit numbering is 0-indexed where bit 0 is the MSB of byte 1.
"""
function extract_bits(bytes::AbstractVector{UInt8}, start_bit::Int, num_bits::Int)::UInt32
    result = UInt32(0)
    for i in 0:(num_bits - 1)
        bit_pos = start_bit + i
        byte_idx = (bit_pos >> 3) + 1  # 1-indexed byte
        bit_in_byte = 7 - (bit_pos & 7)  # MSB is bit 7
        if (bytes[byte_idx] >> bit_in_byte) & 1 == 1
            result |= UInt32(1) << (num_bits - 1 - i)
        end
    end
    return result
end

"""
    extract_word(packed::AbstractVector{UInt8}, word_idx::Int) -> UInt32

Extract word `word_idx` (1-indexed, 1-10) from 38-byte packed navbits.
Each word is 30 bits. Returns the 30-bit word as UInt32.
"""
function extract_word(packed::AbstractVector{UInt8}, word_idx::Int)::UInt32
    @boundscheck 1 <= word_idx <= 10 || throw(BoundsError("word_idx must be 1-10, got $word_idx"))
    start_bit = (word_idx - 1) * 30
    return extract_bits(packed, start_bit, 30)
end

"""
    word_bits(word::UInt32, start_bit::Int, end_bit::Int) -> UInt32

Extract bits from a 30-bit GPS word using GPS 1-indexed bit positions.
GPS bit 1 is the MSB (bit 29 in 0-indexed), GPS bit 30 is the LSB (bit 0).

Example: word_bits(word, 1, 8) extracts the preamble (bits 1-8).
"""
function word_bits(word::UInt32, start_bit::Int, end_bit::Int)::UInt32
    @boundscheck 1 <= start_bit <= end_bit <= 30 || throw(ArgumentError("Invalid bit range: $start_bit-$end_bit"))
    num_bits = end_bit - start_bit + 1
    # GPS bit 1 is at position 29, GPS bit 30 is at position 0
    shift = 30 - end_bit
    mask = (UInt32(1) << num_bits) - 1
    return (word >> shift) & mask
end

"""
    invert_bits(value::UInt32, num_bits::Int) -> UInt32

Invert (flip) the lower `num_bits` bits of value.
"""
function invert_bits(value::UInt32, num_bits::Int)::UInt32
    mask = (UInt32(1) << num_bits) - 1
    return xor(value, mask)
end

# D30* complementing mask: GPS data bits 1-24 (UInt32 positions 6-29)
# If D30 of the previous word is 1, these bits are XOR'd by the transmitter.
const DATA_BITS_MASK = UInt32(0x3FFFFFC0)

# GPS LNAV parity checking (IS-GPS-200 Table 20-XIV)
# Each mask selects data bits (d1-d24) from a 30-bit word for one parity equation.
# GPS bit i is at UInt32 position (30 - i).

const PARITY_25_MASK = 0x3B1F3480  # d1,d2,d3,d5,d6,d10,d11,d12,d13,d14,d17,d18,d20,d23
const PARITY_26_MASK = 0x1D8F9A40  # d2,d3,d4,d6,d7,d11,d12,d13,d14,d15,d18,d19,d21,d24
const PARITY_27_MASK = 0x2EC7CD00  # d1,d3,d4,d5,d7,d8,d12,d13,d14,d15,d16,d19,d20,d22
const PARITY_28_MASK = 0x1763E680  # d2,d4,d5,d6,d8,d9,d13,d14,d15,d16,d17,d20,d21,d23
const PARITY_29_MASK = 0x2BB1F340  # d1,d3,d5,d6,d7,d9,d10,d14,d15,d16,d17,d18,d21,d22,d24
const PARITY_30_MASK = 0x0B7A89C0  # d3,d5,d6,d8,d9,d10,d11,d13,d15,d19,d22,d23,d24

"""
    compute_parity_bits(word::UInt32, D29_star::Bool, D30_star::Bool) -> UInt32

Compute the expected 6-bit parity for a 30-bit GPS LNAV word using the
IS-GPS-200 parity equations. `D29_star` and `D30_star` are the D29 and D30
bits from the previous word. Returns a 6-bit UInt32 (D25 in bit 5, D30 in bit 0).
"""
function compute_parity_bits(word::UInt32, D29_star::Bool, D30_star::Bool)::UInt32
    d25 = xor(isodd(count_ones(word & PARITY_25_MASK)), D29_star)
    d26 = xor(isodd(count_ones(word & PARITY_26_MASK)), D30_star)
    d27 = xor(isodd(count_ones(word & PARITY_27_MASK)), D29_star)
    d28 = xor(isodd(count_ones(word & PARITY_28_MASK)), D30_star)
    d29 = xor(isodd(count_ones(word & PARITY_29_MASK)), D30_star)
    d30 = xor(isodd(count_ones(word & PARITY_30_MASK)), D29_star)

    return (UInt32(d25) << 5) | (UInt32(d26) << 4) | (UInt32(d27) << 3) |
           (UInt32(d28) << 2) | (UInt32(d29) << 1) | UInt32(d30)
end

"""
    check_word_parity(word::UInt32, D29_star::Bool, D30_star::Bool) -> Bool

Check whether a 30-bit GPS LNAV word has valid parity. Compares the received
parity bits (25-30) against the expected parity computed from data bits and
the previous word's D29/D30.
"""
function check_word_parity(word::UInt32, D29_star::Bool, D30_star::Bool)::Bool
    received_parity = word & UInt32(0x3F)
    expected_parity = compute_parity_bits(word, D29_star, D30_star)
    return received_parity == expected_parity
end

"""
    set_word_parity(word::UInt32, D29_star::Bool, D30_star::Bool) -> UInt32

Set correct parity bits (25-30) on a 30-bit GPS LNAV word. Clears any existing
parity bits and computes the correct ones from the data bits and previous word's D29/D30.
"""
function set_word_parity(word::UInt32, D29_star::Bool, D30_star::Bool)::UInt32
    data_bits = word & ~UInt32(0x3F)
    parity = compute_parity_bits(data_bits, D29_star, D30_star)
    return data_bits | parity
end
