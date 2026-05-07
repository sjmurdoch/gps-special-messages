# Statistical analysis utilities for GPS special message content

"""
    shannon_entropy(bytes::Vector{UInt8}) -> Float64

Calculate the Shannon entropy of a byte sequence in bits per byte.

Entropy = -Σ(p(x) * log2(p(x))) where p(x) is the probability of each byte value.

High entropy (approaching 8 bits/byte) suggests random or encrypted data.
Low entropy (< 4.5 bits/byte) suggests structured or text data.
"""
function shannon_entropy(bytes::Vector{UInt8})::Float64
    if isempty(bytes)
        return 0.0
    end

    # Count occurrences of each byte value
    counts = zeros(Int, 256)
    for byte in bytes
        counts[Int(byte) + 1] += 1
    end

    # Calculate Shannon entropy
    n = length(bytes)
    entropy = 0.0
    for count in counts
        if count > 0
            p = count / n
            entropy -= p * log2(p)
        end
    end

    return entropy
end

"""
    count_printable_chars(bytes::Vector{UInt8}) -> Int

Count the number of printable characters in a byte sequence.

Printable characters include:
- GPS character set: A-Z, 0-9, space, and special chars (+, -, ., ', °, /, :, ")
- Standard ASCII printable: 0x20-0x7E
"""
function count_printable_chars(bytes::Vector{UInt8})::Int
    count = 0
    for byte in bytes
        # Standard ASCII printable range (space to ~)
        if 0x20 <= byte <= 0x7E
            count += 1
        end
    end
    return count
end

"""
    count_null_bytes(bytes::Vector{UInt8}) -> Int

Count the number of null bytes (0x00) in a byte sequence.

High null byte counts typically indicate padding or incomplete text,
while low counts suggest random or encrypted data.
"""
function count_null_bytes(bytes::Vector{UInt8})::Int
    return count(==(0x00), bytes)
end

"""
    is_likely_text(bytes::Vector{UInt8}) -> Bool

Heuristic to determine if a byte sequence is likely text vs. encrypted/random data.

Criteria for text classification:
- At least 70% printable ASCII characters
- Entropy < 4.5 bits/byte (indicating non-random distribution)
- Fewer than 50% null bytes

This heuristic is designed for the GPS special message research analysis.
"""
function is_likely_text(bytes::Vector{UInt8})::Bool
    if isempty(bytes)
        return false
    end

    printable = count_printable_chars(bytes)
    null_count = count_null_bytes(bytes)
    entropy = shannon_entropy(bytes)

    n = length(bytes)
    printable_ratio = printable / n
    null_ratio = null_count / n

    # Text heuristic: mostly printable, low entropy, not too many nulls
    return (printable_ratio >= 0.70) &&
           (entropy < 4.5) &&
           (null_ratio < 0.50)
end

"""
    compute_message_stats(bytes::Vector{UInt8}) -> NamedTuple

Compute comprehensive statistics for a message byte sequence.

Returns a NamedTuple with:
- `printable_chars::Int`: Count of printable ASCII characters
- `null_bytes::Int`: Count of null bytes
- `entropy::Float64`: Shannon entropy in bits/byte
- `is_likely_text::Bool`: Text likelihood classification
"""
function compute_message_stats(bytes::Vector{UInt8})
    printable = count_printable_chars(bytes)
    nulls = count_null_bytes(bytes)
    ent = shannon_entropy(bytes)
    n = length(bytes)
    text = if isempty(bytes)
        false
    else
        (printable / n >= 0.70) && (ent < 4.5) && (nulls / n < 0.50)
    end
    return (
        printable_chars = printable,
        null_bytes = nulls,
        entropy = ent,
        is_likely_text = text
    )
end
