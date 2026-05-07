include(joinpath(@__DIR__, "..", "src", "ppm_model.jl"))
using .PPMEntropy

@testset "PPM Model" begin

    # ── pack_context ──────────────────────────────────────────────────

    @testset "pack_context boundary: order 0" begin
        @test pack_context(UInt8[0x41], 0, 0) == UInt64(0)
    end

    @testset "pack_context single byte" begin
        seq = UInt8[0x41, 0x42, 0x43]
        @test pack_context(seq, 1, 1) == UInt64(0x41)
    end

    @testset "pack_context multi-byte" begin
        seq = UInt8[0x41, 0x42, 0x43, 0x44]
        @test pack_context(seq, 3, 3) == UInt64(0x414243)
    end

    @testset "pack_context high byte values" begin
        seq = UInt8[0xFF, 0xFE, 0xFD]
        @test pack_context(seq, 3, 3) == UInt64(0xFFFEFD)
    end

    @testset "pack_context order 8 full UInt64" begin
        seq = UInt8[0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09]
        @test pack_context(seq, 8, 8) == UInt64(0x0102030405060708)
    end

    @testset "pack_context preserves byte order" begin
        seq = UInt8[0xAB, 0xCD]
        @test pack_context(seq, 2, 2) == UInt64(0xABCD)
        @test pack_context(seq, 2, 1) == UInt64(0xCD)
    end

    # ── Construction ──────────────────────────────────────────────────

    @testset "valid construction" begin
        m = PPMModel(0)
        @test m.max_order == 0
        @test m.vocab_size == 256
        @test length(m.counts) == 1

        m8 = PPMModel(8)
        @test m8.max_order == 8
        @test length(m8.counts) == 9
    end

    @testset "custom vocab_size" begin
        m = PPMModel(2; vocab_size=128)
        @test m.vocab_size == 128
    end

    @testset "invalid construction" begin
        @test_throws ArgumentError PPMModel(-1)
        @test_throws ArgumentError PPMModel(9)
        @test_throws ArgumentError PPMModel(2; vocab_size=0)
    end

    # ── update! counts ────────────────────────────────────────────────

    @testset "update! single byte" begin
        m = PPMModel(2)
        update!(m, UInt8[0x41])
        # Order 0: context="" -> byte 0x41
        node = m.counts[1][UInt64(0)]
        @test node[0x41] == 1
    end

    @testset "update! multi-byte sequence" begin
        m = PPMModel(1)
        update!(m, UInt8[0x41, 0x42])
        # Order 0: "" -> 0x41 (count 1), "" -> 0x42 (count 1)
        @test m.counts[1][UInt64(0)][0x41] == 1
        @test m.counts[1][UInt64(0)][0x42] == 1
        # Order 1: 0x41 -> 0x42 (count 1)
        @test m.counts[2][UInt64(0x41)][0x42] == 1
    end

    @testset "update! accumulation across sequences" begin
        m = PPMModel(1)
        update!(m, UInt8[0x41, 0x42])
        update!(m, UInt8[0x41, 0x43])
        # Order 0: 0x41 seen twice, 0x42 once, 0x43 once
        @test m.counts[1][UInt64(0)][0x41] == 2
        @test m.counts[1][UInt64(0)][0x42] == 1
        @test m.counts[1][UInt64(0)][0x43] == 1
        # Order 1: context 0x41 -> 0x42 (1), 0x41 -> 0x43 (1)
        @test m.counts[2][UInt64(0x41)][0x42] == 1
        @test m.counts[2][UInt64(0x41)][0x43] == 1
    end

    @testset "update! delta=-1 removal" begin
        m = PPMModel(1)
        update!(m, UInt8[0x41, 0x42])
        update!(m, UInt8[0x41, 0x42]; delta=-1)
        @test m.counts[1][UInt64(0)][0x41] == 0
        @test m.counts[1][UInt64(0)][0x42] == 0
        @test m.counts[2][UInt64(0x41)][0x42] == 0
    end

    @testset "update! roundtrip restores state" begin
        m = PPMModel(3)
        seq1 = UInt8[0x10, 0x20, 0x30, 0x40]
        seq2 = UInt8[0x50, 0x60, 0x70, 0x80]
        update!(m, seq1)
        update!(m, seq2)
        # Snapshot counts
        counts_before = [Dict(k => Dict(pairs(v)...) for (k, v) in pairs(d)) for d in m.counts]
        # Remove and re-add seq1
        update!(m, seq1; delta=-1)
        update!(m, seq1; delta=+1)
        # Counts should match
        for order in 1:length(m.counts)
            for (ctx, node) in m.counts[order]
                for (byte, count) in node
                    @test counts_before[order][ctx][byte] == count
                end
            end
        end
    end

    # ── score_byte correctness ────────────────────────────────────────

    @testset "score_byte unigram fallback" begin
        # Model with only order-0 counts: "AB" trained
        m = PPMModel(0)
        update!(m, UInt8[0x41, 0x42])
        # Scoring A at position 1 of "A": no context
        # Order 0: seen = {A:1, B:1}, adjusted_total=2, distinct=2, denom=4
        # P(A) = 1/4
        seq = UInt8[0x41]
        @test score_byte(m, seq, 1) ≈ 1/4
    end

    @testset "score_byte order-1 match" begin
        # Train on "AB" with order 1
        m = PPMModel(1)
        update!(m, UInt8[0x41, 0x42])
        # Score B at position 2 of "AB"
        # Order 1: context=A, node={B:1}, seen={B}, adjusted_total=1, distinct=1, denom=2
        # P(B|A) = 1/2
        seq = UInt8[0x41, 0x42]
        @test score_byte(m, seq, 2) ≈ 1/2
    end

    @testset "score_byte exclusion cascade" begin
        # Train on "AB" and "AC" with order 1
        m = PPMModel(1)
        update!(m, UInt8[0x41, 0x42])
        update!(m, UInt8[0x41, 0x43])
        # Score D at position 2 of "AD"
        # Order 1: context=A, seen={B:1, C:1}, adjusted_total=2, distinct=2, denom=4
        # D not in seen, escape_prod = 2/4 = 0.5, excluded={B,C}
        # Order 0: node={A:2, B:1, C:1}, seen excluding {B,C} = {A:2}
        #   adjusted_total=2, distinct=1, denom=3
        #   D not in {A}, escape_prod *= 1/3 -> 0.5 * 1/3 = 1/6, excluded+={A}
        # Order -1: remaining=256-3=253, P = (1/6) / 253
        seq = UInt8[0x41, 0x44]
        expected = (1.0/6.0) / 253.0
        @test score_byte(m, seq, 2) ≈ expected
    end

    @testset "score_byte uniform order-0 fallback for novel byte" begin
        # Train on single byte A, score B at position 1
        m = PPMModel(2)
        update!(m, UInt8[0x41])
        # Order 0: seen={A:1}, adjusted_total=1, distinct=1, denom=2
        # B not seen, escape = 1/2, excluded={A}
        # Order -1: remaining=255, P = 0.5/255
        seq = UInt8[0x42]
        @test score_byte(m, seq, 1) ≈ 0.5 / 255
    end

    # ── score_sequence ────────────────────────────────────────────────

    @testset "score_sequence empty" begin
        m = PPMModel(2)
        @test score_sequence(m, UInt8[]) == 0.0
    end

    @testset "score_sequence single byte" begin
        m = PPMModel(0)
        update!(m, UInt8[0x41])
        # Score "A": P(A) at pos 1 -> 1/(1+1) = 1/2, bits = -log2(0.5) = 1.0
        @test score_sequence(m, UInt8[0x41]) ≈ 1.0
    end

    @testset "score_sequence hand-computed total" begin
        m = PPMModel(1)
        update!(m, UInt8[0x41, 0x42])
        # Score "AB":
        #   pos 1 (A): order 0 seen={A:1,B:1}, denom=4, P(A)=1/4 -> bits=2.0
        #   pos 2 (B): order 1 ctx=A seen={B:1}, denom=2, P(B|A)=1/2 -> bits=1.0
        # Total = 3.0
        @test score_sequence(m, UInt8[0x41, 0x42]) ≈ 3.0
    end

    # ── Probability invariants ────────────────────────────────────────

    @testset "probabilities sum to 1.0 (no context)" begin
        m = PPMModel(2)
        update!(m, UInt8[0x41, 0x42, 0x43])
        update!(m, UInt8[0x44, 0x45])
        # Sum P(b) for all 256 bytes at position 1 (no context)
        total = 0.0
        for b in 0x00:0xFF
            seq = UInt8[b]
            total += score_byte(m, seq, 1)
        end
        @test total ≈ 1.0 atol=1e-12
    end

    @testset "probabilities sum to 1.0 (with context)" begin
        m = PPMModel(2)
        update!(m, UInt8[0x41, 0x42, 0x43])
        update!(m, UInt8[0x41, 0x44, 0x45])
        # Sum P(b|0x41) for all 256 bytes at position 2
        total = 0.0
        for b in 0x00:0xFF
            seq = UInt8[0x41, b]
            total += score_byte(m, seq, 2)
        end
        @test total ≈ 1.0 atol=1e-12
    end

    @testset "probabilities sum to 1.0 (order-2 context)" begin
        m = PPMModel(3)
        update!(m, UInt8[0x41, 0x42, 0x43, 0x44])
        update!(m, UInt8[0x41, 0x42, 0x45, 0x46])
        # Sum P(b|0x41,0x42) at position 3
        total = 0.0
        for b in 0x00:0xFF
            seq = UInt8[0x41, 0x42, b]
            total += score_byte(m, seq, 3)
        end
        @test total ≈ 1.0 atol=1e-12
    end

    # ── Leave-one-out ─────────────────────────────────────────────────

    @testset "leave-one-out symmetry" begin
        # Two identical-structure messages should score the same
        m = PPMModel(2)
        s1 = UInt8[0x41, 0x42, 0x43]
        s2 = UInt8[0x44, 0x45, 0x46]
        update!(m, s1)
        update!(m, s2)

        # LOO score for s1
        update!(m, s1; delta=-1)
        score1 = score_sequence(m, s1)
        update!(m, s1; delta=+1)

        # LOO score for s2
        update!(m, s2; delta=-1)
        score2 = score_sequence(m, s2)
        update!(m, s2; delta=+1)

        @test score1 ≈ score2
    end

    @testset "single-message corpus gives uniform ~8 bits/byte" begin
        # With only one message, LOO leaves an empty model -> uniform 1/256 per byte
        m = PPMModel(4)
        seq = UInt8[0x48, 0x45, 0x4C, 0x4C, 0x4F]  # "HELLO"
        update!(m, seq)
        update!(m, seq; delta=-1)
        bits = score_sequence(m, seq)
        update!(m, seq; delta=+1)
        # Each byte: P = 1/256, bits = 8.0, total = 5 * 8.0 = 40.0
        @test bits ≈ 40.0
    end

    @testset "leave-one-out correct value" begin
        # Two messages sharing a prefix "AB"
        m = PPMModel(1)
        s1 = UInt8[0x41, 0x42, 0x43]  # ABC
        s2 = UInt8[0x41, 0x42, 0x44]  # ABD
        update!(m, s1)
        update!(m, s2)

        # LOO score for s1 (model has only s2 = ABD)
        update!(m, s1; delta=-1)
        score_s1 = score_sequence(m, s1)
        update!(m, s1; delta=+1)

        # Hand-compute: model trained only on "ABD"
        # Order 0: {A:1, B:1, D:1}
        # Order 1: A->B (1), B->D (1)
        #
        # pos 1, byte A:
        #   order 0: seen={A:1,B:1,D:1}, adj=3, dist=3, denom=6
        #   A in seen: P=1/6, bits=-log2(1/6)
        #
        # pos 2, byte B:
        #   order 1: ctx=A, seen={B:1}, adj=1, dist=1, denom=2
        #   B in seen: P=1/2, bits=1.0
        #
        # pos 3, byte C:
        #   order 1: ctx=B, seen={D:1}, adj=1, dist=1, denom=2
        #   C not in {D}, escape=1/2, excluded={D}
        #   order 0: seen excl {D} = {A:1,B:1}, adj=2, dist=2, denom=4
        #   C not in {A,B}, escape *= 2/4=1/2, excluded+={A,B}
        #   order -1: remaining=256-3=253, P=(1/4)/253
        #   bits=-log2(1/1012)

        expected = -log2(1/6) + 1.0 + (-log2(1.0/1012.0))
        @test score_s1 ≈ expected
    end

    # ── Entropy ordering ──────────────────────────────────────────────

    @testset "identical messages score lower than diverse" begin
        m = PPMModel(4)
        s_dup = UInt8[0x41, 0x42, 0x43, 0x44]
        s_uniq = UInt8[0x50, 0x51, 0x52, 0x53]
        # Add s_dup twice and s_uniq once
        update!(m, s_dup)
        update!(m, s_dup)
        update!(m, s_uniq)

        # LOO for one copy of s_dup (still one copy remains)
        update!(m, s_dup; delta=-1)
        score_dup = score_sequence(m, s_dup)
        update!(m, s_dup; delta=+1)

        # LOO for s_uniq (unique, model only has s_dup×2)
        update!(m, s_uniq; delta=-1)
        score_uniq = score_sequence(m, s_uniq)
        update!(m, s_uniq; delta=+1)

        @test score_dup < score_uniq
    end

    @testset "shared substrings score lower than no sharing" begin
        m = PPMModel(4)
        # Messages sharing prefix "ABCD"
        s1 = UInt8[0x41, 0x42, 0x43, 0x44, 0x01]
        s2 = UInt8[0x41, 0x42, 0x43, 0x44, 0x02]
        # Message with no shared content
        s3 = UInt8[0xF0, 0xF1, 0xF2, 0xF3, 0xF4]
        update!(m, s1)
        update!(m, s2)
        update!(m, s3)

        # LOO for s1 (s2 shares substring)
        update!(m, s1; delta=-1)
        score_shared = score_sequence(m, s1)
        update!(m, s1; delta=+1)

        # LOO for s3 (no shared content with s1/s2)
        update!(m, s3; delta=-1)
        score_noshare = score_sequence(m, s3)
        update!(m, s3; delta=+1)

        @test score_shared < score_noshare
    end

    # ── Model stability ──────────────────────────────────────────────

    @testset "full LOO cycle preserves total count" begin
        m = PPMModel(3)
        seqs = [UInt8[0x41, 0x42, 0x43],
                UInt8[0x44, 0x45, 0x46],
                UInt8[0x47, 0x48, 0x49]]
        for s in seqs
            update!(m, s)
        end

        # Snapshot total count at order 0
        total_before = sum(values(m.counts[1][UInt64(0)]))

        # Full LOO cycle
        for s in seqs
            update!(m, s; delta=-1)
            score_sequence(m, s)
            update!(m, s; delta=+1)
        end

        total_after = sum(values(m.counts[1][UInt64(0)]))
        @test total_before == total_after
    end

    # ── find_repeated_substrings ────────────────────────────────────

    @testset "find_repeated_substrings empty input" begin
        result = find_repeated_substrings(Vector{UInt8}[])
        @test isempty(result)
    end

    @testset "find_repeated_substrings no repeats" begin
        msgs = [UInt8[0x01,0x02,0x03,0x04,0x05,0x06,0x07],
                UInt8[0x08,0x09,0x0A,0x0B,0x0C,0x0D,0x0E]]
        result = find_repeated_substrings(msgs; min_len=6)
        @test isempty(result)
    end

    @testset "find_repeated_substrings exact min_len match" begin
        shared = UInt8[0x41,0x42,0x43,0x44,0x45,0x46]  # 6 bytes
        msg1 = vcat(shared, UInt8[0x01])
        msg2 = vcat(shared, UInt8[0x02])
        result = find_repeated_substrings([msg1, msg2]; min_len=6)
        @test length(result) == 1
        @test result[1].bytes == shared
        msg_indices = sort(unique(first.(result[1].occurrences)))
        @test msg_indices == [1, 2]
    end

    @testset "find_repeated_substrings below min_len not reported" begin
        shared = UInt8[0x41,0x42,0x43,0x44,0x45]  # 5 bytes
        msg1 = vcat(shared, UInt8[0x01,0x02])
        msg2 = vcat(shared, UInt8[0x03,0x04])
        result = find_repeated_substrings([msg1, msg2]; min_len=6)
        @test isempty(result)
    end

    @testset "find_repeated_substrings maximal filtering" begin
        # "ABCDEFGH" shared by msgs 1,2 — substring "ABCDEF" should be suppressed
        shared = UInt8[0x41,0x42,0x43,0x44,0x45,0x46,0x47,0x48]  # 8 bytes
        msg1 = vcat(shared, UInt8[0x01])
        msg2 = vcat(shared, UInt8[0x02])
        result = find_repeated_substrings([msg1, msg2]; min_len=6)
        @test length(result) == 1
        @test length(result[1].bytes) == 8
    end

    @testset "find_repeated_substrings shorter reported when more messages" begin
        # "ABCDEFGH" shared by msgs 1,2
        # "ABCDEF" shared by msgs 1,2,3 (msg 3 diverges after 6 bytes)
        shared8 = UInt8[0x41,0x42,0x43,0x44,0x45,0x46,0x47,0x48]
        msg1 = vcat(shared8, UInt8[0x01])
        msg2 = vcat(shared8, UInt8[0x02])
        msg3 = vcat(shared8[1:6], UInt8[0xF1,0xF2,0xF3])
        result = find_repeated_substrings([msg1, msg2, msg3]; min_len=6)
        # Should have the 8-byte match (msgs 1,2) and the 6-byte match is
        # covered for msgs 1,2 but NOT for msg 3, so it should appear
        lengths = sort([length(r.bytes) for r in result], rev=true)
        @test 8 in lengths
        @test 6 in lengths
    end

    @testset "find_repeated_substrings multiple independent substrings" begin
        # msg1 shares prefix with msg2, suffix with msg3
        msg1 = UInt8[0x41,0x42,0x43,0x44,0x45,0x46,0x01,0x02,0x03,0x04,0x05,0x06]
        msg2 = UInt8[0x41,0x42,0x43,0x44,0x45,0x46,0xF1,0xF2,0xF3,0xF4,0xF5,0xF6]
        msg3 = UInt8[0xE1,0xE2,0xE3,0xE4,0xE5,0xE6,0x01,0x02,0x03,0x04,0x05,0x06]
        result = find_repeated_substrings([msg1, msg2, msg3]; min_len=6)
        @test length(result) == 2
        all_bytes = Set([r.bytes for r in result])
        @test UInt8[0x41,0x42,0x43,0x44,0x45,0x46] in all_bytes
        @test UInt8[0x01,0x02,0x03,0x04,0x05,0x06] in all_bytes
    end

    @testset "find_repeated_substrings different positions" begin
        # Same 6 bytes at different positions in two messages
        sub = UInt8[0xAA,0xBB,0xCC,0xDD,0xEE,0xFF]
        msg1 = vcat(sub, UInt8[0x01,0x02])           # pos 1-6
        msg2 = vcat(UInt8[0x03,0x04], sub)           # pos 3-8
        result = find_repeated_substrings([msg1, msg2]; min_len=6)
        @test length(result) == 1
        @test result[1].bytes == sub
        positions = Dict(mi => sp for (mi, sp) in result[1].occurrences)
        @test positions[1] == 1
        @test positions[2] == 3
    end

    @testset "find_repeated_substrings sorted by length descending" begin
        msg1 = UInt8[0x41,0x42,0x43,0x44,0x45,0x46,0x47,0x48,0x01]
        msg2 = UInt8[0x41,0x42,0x43,0x44,0x45,0x46,0x47,0x48,0x02]
        msg3 = UInt8[0xF0,0xF1,0xF2,0xF3,0xF4,0xF5,0xF6,0xF7,0x01]
        msg4 = UInt8[0xF0,0xF1,0xF2,0xF3,0xF4,0xF5,0xF6,0xF7,0x02]
        # Force a shorter independent match too
        msg5 = UInt8[0xA0,0xA1,0xA2,0xA3,0xA4,0xA5,0x01,0x01,0x01]
        msg6 = UInt8[0xA0,0xA1,0xA2,0xA3,0xA4,0xA5,0x02,0x02,0x02]
        result = find_repeated_substrings([msg1, msg2, msg3, msg4, msg5, msg6]; min_len=6)
        @test length(result) >= 2
        for i in 1:length(result)-1
            @test length(result[i].bytes) >= length(result[i+1].bytes)
        end
    end

    # ── Higher order detection ───────────────────────────────────────

    @testset "higher order detects longer shared substrings" begin
        # Multiple messages needed so order-0 is noisy and higher-order
        # contexts actually help disambiguate the shared prefix.
        shared = UInt8[0x41, 0x42, 0x43, 0x44, 0x45]
        s1 = vcat(shared, UInt8[0x01, 0x02])
        s2 = vcat(shared, UInt8[0x03, 0x04])
        # "noise" messages that use some of the same bytes but not in the same order
        noise = [UInt8[0x42, 0x41, 0x44, 0x43, 0x46, 0x05, 0x06],
                 UInt8[0x43, 0x44, 0x41, 0x42, 0x47, 0x07, 0x08],
                 UInt8[0x44, 0x43, 0x42, 0x41, 0x48, 0x09, 0x0A]]

        # Order-1 model
        m1 = PPMModel(1)
        for s in [s1, s2, noise...]
            update!(m1, s)
        end
        update!(m1, s1; delta=-1)
        score_low = score_sequence(m1, s1)
        update!(m1, s1; delta=+1)

        # Order-4 model (can see 4-byte contexts within the shared prefix)
        m4 = PPMModel(4)
        for s in [s1, s2, noise...]
            update!(m4, s)
        end
        update!(m4, s1; delta=-1)
        score_high = score_sequence(m4, s1)
        update!(m4, s1; delta=+1)

        # Higher order should assign lower entropy to shared substring
        @test score_high < score_low
    end

end
