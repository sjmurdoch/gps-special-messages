"""
    PPMEntropy

PPM-D (Prediction by Partial Matching with exclusion) model for computing
marginal compression entropy.

Maintains n-gram counts for orders 0..max_order. Scoring uses the standard
PPM-D escape mechanism: at each order, symbols seen at higher orders are
excluded from the probability mass.

This is a standalone module (not part of GPSSpecialMessages).
"""
module PPMEntropy

export PPMModel, update!, score_byte, score_sequence, pack_context, find_repeated_substrings

"""
    PPMModel(max_order; vocab_size=256)

Create a PPM-D model with context orders 0 through `max_order`.

`max_order` must be between 0 and 8 (inclusive), since context bytes are
packed into `UInt64` keys (8 bytes maximum).
"""
struct PPMModel
    max_order::Int
    vocab_size::Int
    # counts[order+1][packed_context][byte_value] = frequency
    counts::Vector{Dict{UInt64, Dict{UInt8, Int}}}

    function PPMModel(max_order::Int; vocab_size::Int=256)
        (0 <= max_order <= 8) || throw(ArgumentError("max_order must be 0..8, got $max_order"))
        vocab_size > 0 || throw(ArgumentError("vocab_size must be positive, got $vocab_size"))
        counts = [Dict{UInt64, Dict{UInt8, Int}}() for _ in 1:max_order+1]
        new(max_order, vocab_size, counts)
    end
end

"""
    pack_context(seq, endpos, order) -> UInt64

Pack `order` bytes from `seq[endpos-order+1:endpos]` into a `UInt64` key.
Avoids allocating a `Vector` for use as dictionary keys.
"""
@inline function pack_context(seq::AbstractVector{UInt8}, endpos::Int, order::Int)::UInt64
    ctx = zero(UInt64)
    @inbounds for j in (endpos - order + 1):endpos
        ctx = (ctx << 8) | UInt64(seq[j])
    end
    ctx
end

"""
    update!(model, seq; delta=1)

Add (`delta=+1`) or remove (`delta=-1`) a sequence's n-gram counts.
"""
function update!(model::PPMModel, seq::AbstractVector{UInt8}; delta::Int=1)
    n = length(seq)
    for pos in 1:n
        @inbounds byte = seq[pos]
        max_ord = min(pos - 1, model.max_order)
        for order in 0:max_ord
            ctx = order == 0 ? zero(UInt64) : pack_context(seq, pos - 1, order)
            node = get!(Dict{UInt8, Int}, model.counts[order + 1], ctx)
            node[byte] = get(node, byte, 0) + delta
        end
    end
    model
end

"""
    score_byte(model, seq, pos) -> Float64

Return the probability of `seq[pos]` given the preceding context, using
PPM-D exclusion. `pos` is 1-indexed.
"""
function score_byte(model::PPMModel, seq::AbstractVector{UInt8}, pos::Int)::Float64
    excluded = falses(256)
    _score_byte_impl(model, seq, pos, excluded)
end

"""
    _score_byte_impl(model, seq, pos, excluded) -> Float64

Internal PPM-D scoring with a pre-allocated exclusion buffer.
"""
function _score_byte_impl(model::PPMModel, seq::AbstractVector{UInt8}, pos::Int,
                          excluded::BitVector)::Float64
    @inbounds byte = seq[pos]
    max_ctx_len = min(pos - 1, model.max_order)
    escape_prod = 1.0
    n_excluded = 0

    for order in max_ctx_len:-1:0
        ctx = order == 0 ? zero(UInt64) : pack_context(seq, pos - 1, order)
        node = get(model.counts[order + 1], ctx, nothing)
        node === nothing && continue

        # Count seen symbols (count > 0, not excluded)
        adjusted_total = 0
        distinct = 0
        @inbounds for (b, c) in node
            if c > 0 && !excluded[Int(b) + 1]
                adjusted_total += c
                distinct += 1
            end
        end
        distinct == 0 && continue

        denom = adjusted_total + distinct

        # Check if target byte is among seen symbols
        byte_count = get(node, byte, 0)
        @inbounds if byte_count > 0 && !excluded[Int(byte) + 1]
            return escape_prod * byte_count / denom
        end

        # Escape: multiply escape probability and exclude seen symbols
        escape_prod *= distinct / denom
        @inbounds for (b, c) in node
            if c > 0 && !excluded[Int(b) + 1]
                excluded[Int(b) + 1] = true
                n_excluded += 1
            end
        end
    end

    # Order -1: uniform over remaining byte values
    remaining = model.vocab_size - n_excluded
    if remaining > 0
        return escape_prod / remaining
    end
    return escape_prod / model.vocab_size
end

"""
    score_sequence(model, seq) -> Float64

Score a sequence, returning total information content in bits.
"""
function score_sequence(model::PPMModel, seq::AbstractVector{UInt8})::Float64
    n = length(seq)
    n == 0 && return 0.0
    total_bits = 0.0
    excluded = falses(256)
    for pos in 1:n
        fill!(excluded, false)
        prob = _score_byte_impl(model, seq, pos, excluded)
        total_bits += -log2(prob)
    end
    total_bits
end

"""
    find_repeated_substrings(raw_messages; min_len=6)

Find byte substrings of length >= `min_len` that appear in 2 or more distinct
messages. Returns only maximal substrings (those not fully contained within a
longer reported shared substring).

Returns a vector of named tuples `(bytes, occurrences)` sorted by substring
length descending, where `occurrences` is a vector of `(message_index, start_position)`,
both 1-indexed.
"""
function find_repeated_substrings(raw_messages::AbstractVector{<:AbstractVector{UInt8}};
                                  min_len::Int=6)
    RT = NamedTuple{(:bytes, :occurrences), Tuple{Vector{UInt8}, Vector{Tuple{Int,Int}}}}
    n = length(raw_messages)
    n == 0 && return RT[]

    max_len = maximum(length, raw_messages)
    min_len > max_len && return RT[]

    results = RT[]

    # Track covered intervals per message to filter non-maximal substrings
    covered = Dict{Int, Vector{UnitRange{Int}}}()

    for len in max_len:-1:min_len
        substr_map = Dict{Vector{UInt8}, Vector{Tuple{Int,Int}}}()
        for (i, raw) in enumerate(raw_messages)
            length(raw) < len && continue
            for start in 1:(length(raw) - len + 1)
                key = raw[start:start+len-1]
                push!(get!(Vector{Tuple{Int,Int}}, substr_map, key), (i, start))
            end
        end

        for (sub, occs) in substr_map
            # Must appear in at least 2 different messages
            msg_set = Set(first.(occs))
            length(msg_set) < 2 && continue

            # Skip if all occurrences are covered by longer substrings
            all_covered = all(occs) do (mi, sp)
                intervals = get(covered, mi, UnitRange{Int}[])
                any(iv -> sp >= first(iv) && sp + len - 1 <= last(iv), intervals)
            end
            all_covered && continue

            push!(results, (bytes=copy(sub), occurrences=copy(occs)))
            for (mi, sp) in occs
                push!(get!(Vector{UnitRange{Int}}, covered, mi), sp:(sp+len-1))
            end
        end
    end

    sort!(results, by=x -> (-length(x.bytes), -length(Set(first.(x.occurrences)))))
end

end # module
