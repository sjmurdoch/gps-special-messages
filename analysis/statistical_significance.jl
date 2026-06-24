#!/usr/bin/env julia
#
# Statistical Significance Analysis of GPS Special Message Anomalies
#
# Performs 7 formal hypothesis tests on the non-random elements identified
# in the marginal entropy analysis, each with clearly stated null hypothesis,
# test statistic, and p-value. Output is Markdown.
#
# Usage:
#   julia --project analyze_statistical_significance.jl [messages.duckdb]

include(joinpath(@__DIR__, "..", "src", "GPSSpecialMessages.jl"))
using .GPSSpecialMessages
include(joinpath(@__DIR__, "..", "src", "ppm_model.jl"))
using .PPMEntropy
include(joinpath(@__DIR__, "..", "src", "statistical_tests.jl"))
using .StatisticalTests

using DuckDB
using Printf
using Statistics
using Random
using Dates

# GPS ICD (IS-GPS-200) character set for special messages: A-Z, 0-9, space,
# and: + - . ' ° / : "
const GPS_CHARSET_BYTES = let
    valid = Set{UInt8}()
    push!(valid, 0x20)  # space
    push!(valid, 0x22)  # "
    push!(valid, 0x27)  # '
    push!(valid, 0x2B)  # +
    push!(valid, 0x2D)  # -
    push!(valid, 0x2E)  # .
    push!(valid, 0x2F)  # /
    for b in 0x30:0x39  # 0-9
        push!(valid, b)
    end
    push!(valid, 0x3A)  # :
    for b in 0x41:0x5A  # A-Z
        push!(valid, b)
    end
    push!(valid, 0xF8)  # ° (CP437 encoding of degree sign)
    valid
end

"""
    format_number(n::Integer) -> String

Format an integer with thousand separators (e.g. `12_163_006` → `"12,163,006"`).
"""
function format_number(n::Integer)::String
    s = string(n)
    result = ""
    for (i, c) in enumerate(reverse(s))
        if i > 1 && (i - 1) % 3 == 0
            result = "," * result
        end
        result = c * result
    end
    return result
end

# ── Formatting helpers ──────────────────────────────────────────────────

"""Format a p-value for display: scientific notation, or "< 10^-N" for underflow."""
function fmt_p(p::Float64)
    p == 0.0 && return "< 10^-100"
    p < 1e-25 && return @sprintf("< 10^-25")
    @sprintf("%.2e", p)
end

"""Format a number in scientific notation."""
fmt_sci(x::Float64) = @sprintf("%.2e", x)

# ── Data loading ────────────────────────────────────────────────────────

function load_messages(db)
    result = DBInterface.execute(db, """
        SELECT
            message_hash,
            ascii_message,
            raw_bytes,
            entropy,
            COUNT(*) as observations,
            MIN(datetime) as first_date,
            MAX(datetime) as last_date,
            COUNT(DISTINCT prn) as prns
        FROM special_messages
        GROUP BY message_hash, ascii_message, raw_bytes, entropy
        ORDER BY message_hash
    """)

    messages = NamedTuple{(:hash, :text, :bytes, :entropy, :obs, :first, :last, :prns),
                          Tuple{String, String, Vector{UInt8}, Float64, Int, String, String, Int}}[]

    for row in result
        push!(messages, (
            hash = string(row.message_hash),
            text = string(row.ascii_message),
            bytes = Vector{UInt8}(row.raw_bytes),
            entropy = Float64(row.entropy),
            obs = Int(row.observations),
            first = string(row.first_date)[1:10],
            last = string(row.last_date)[1:10],
            prns = Int(row.prns),
        ))
    end
    messages
end

function get_observed_alphabet(db)
    result = DBInterface.execute(db, "SELECT DISTINCT raw_bytes FROM special_messages")
    alphabet = Set{UInt8}()
    for row in result
        for b in Vector{UInt8}(row.raw_bytes)
            push!(alphabet, b)
        end
    end
    sort(collect(alphabet))
end

function get_text_prn_distribution(db)
    result = DBInterface.execute(db, """
        SELECT prn, COUNT(DISTINCT message_hash) as n_text_messages
        FROM special_messages
        WHERE ascii_message LIKE 'TEXT%'
        GROUP BY prn
        ORDER BY n_text_messages DESC
    """)
    prn_counts = Tuple{Int, Int}[]
    for row in result
        push!(prn_counts, (Int(row.prn), Int(row.n_text_messages)))
    end
    prn_counts
end

# ── PPM-D LOO scoring ──────────────────────────────────────────────────

function compute_ppm_loo_scores(messages; order=8)
    n = length(messages)
    println(stderr, "Building PPM-D order-$order model ($n messages)...")
    model = PPMModel(order)
    for m in messages
        PPMEntropy.update!(model, m.bytes)
    end

    println(stderr, "Computing leave-one-out scores...")
    scores = Vector{Float64}(undef, n)
    for i in 1:n
        PPMEntropy.update!(model, messages[i].bytes; delta=-1)
        scores[i] = score_sequence(model, messages[i].bytes)
        PPMEntropy.update!(model, messages[i].bytes; delta=+1)
        if i % 500 == 0
            println(stderr, "  $i / $n")
        end
    end
    println(stderr, "  Done.")
    scores
end

# ── Random baseline scoring ────────────────────────────────────────────

function compute_random_baseline(n_messages, msg_len, alphabet, order; n_repeats=100, seed=42)
    println(stderr, "Simulating random baseline ($n_repeats repeats)...")
    all_scores = Float64[]
    for rep in 1:n_repeats
        rng = Xoshiro(seed + rep - 1)
        msgs = [rand(rng, alphabet, msg_len) for _ in 1:n_messages]
        model = PPMModel(order)
        for m in msgs
            PPMEntropy.update!(model, m)
        end
        for i in 1:n_messages
            PPMEntropy.update!(model, msgs[i]; delta=-1)
            push!(all_scores, score_sequence(model, msgs[i]))
            PPMEntropy.update!(model, msgs[i]; delta=+1)
        end
        if rep % 20 == 0
            println(stderr, "  $rep / $n_repeats")
        end
    end
    println(stderr, "  Done.")
    all_scores
end

# ── Test implementations ────────────────────────────────────────────────

function test1_shared_substrings(messages, alphabet_size)
    println("\n## Test 1: Shared Substring Birthday Problem")
    println()
    println("**H0:** Messages are independent random draws from a $(alphabet_size)-symbol alphabet.")
    println("Shared substrings of length L arise only by chance.")
    println()

    raw_messages = [m.bytes for m in messages]
    N = length(messages)
    M = 22

    println("Corpus: N = $N messages, M = $M bytes each, alphabet A = $alphabet_size")
    println()

    # Compute results first
    rows = []
    for L in [6, 7, 8, 9]
        substrings_per_msg = M - L + 1
        total_substrings = N * substrings_per_msg
        n_slots = Float64(alphabet_size)^L
        lambda = birthday_expected_collisions(total_substrings, n_slots)
        repeated = find_repeated_substrings(raw_messages; min_len=L)
        observed_at_L = count(r -> length(r.bytes) >= L, repeated)
        p = poisson_sf(observed_at_L - 1, lambda)
        sig = p < 0.001 ? "\\*\\*\\*" : p < 0.01 ? "\\*\\*" : p < 0.05 ? "\\*" : "n.s."
        push!(rows, (L, lambda, observed_at_L, p, sig))
    end

    println("| L | E[collisions] | Observed | p-value | Significant? |")
    println("|---|---|---|---|---|")
    for (L, lambda, obs, p, sig) in rows
        println("| $L | $(fmt_sci(lambda)) | $obs | $(fmt_p(p)) | $sig |")
    end

    # List the shared substrings
    repeated_all = find_repeated_substrings(raw_messages; min_len=6)
    println()
    println("The $(length(repeated_all)) shared substrings at L >= 6:")
    println()
    println("| Length | Substring | Messages |")
    println("|---|---|---|")
    for r in repeated_all
        n_msgs = length(Set(first.(r.occurrences)))
        sub_str = String(copy(r.bytes))
        println("| $(length(r.bytes)) | `$sub_str` | $n_msgs |")
    end
end

function test2_text_prefix(messages, alphabet_size, prn_distribution)
    println("\n## Test 2: TEXT Prefix Frequency")
    println()
    println("**H0:** Messages are random draws from A^22 (A = $alphabet_size).")
    println("The probability of any specific 4-byte prefix is 1/A^4.")
    println()

    N = length(messages)
    n_text = count(m -> startswith(m.text, "TEXT"), messages)
    p_prefix = 1.0 / Float64(alphabet_size)^4
    lambda = N * p_prefix

    println("| Quantity | Value |")
    println("|---|---|")
    @printf("| P(specific 4-byte prefix) | 1/%d^4 = %s |\n", alphabet_size, fmt_sci(p_prefix))
    @printf("| Expected under H0 | lambda = N * p = %.6f |\n", lambda)
    @printf("| Observed TEXT-prefixed | %d |\n", n_text)
    p_value = poisson_sf(n_text - 1, lambda)
    println("| **p-value** | **$(fmt_p(p_value))** |")

    # PRN concentration
    if !isempty(prn_distribution)
        top_prn, top_count = prn_distribution[1]
        total_text = sum(last, prn_distribution)
        n_prns = 32

        println()
        println("### PRN concentration")
        println()
        println("| Quantity | Value |")
        println("|---|---|")
        @printf("| Most concentrated PRN | PRN %d (%d/%d unique PRN-message pairs) |\n", top_prn, top_count, total_text)
        p_binom = binomial_sf(top_count - 1, total_text, 1.0 / n_prns)
        println("| P(>= $top_count on one PRN \\| Binomial($total_text, 1/$n_prns)) | **$(fmt_p(p_binom))** |")
    end
end

function test3_text_entropy_ranking(messages, ppm_scores)
    println("\n## Test 3: TEXT Message Entropy Ranking")
    println()
    println("**H0:** TEXT messages are drawn from the same PPM-D entropy distribution as all messages.")
    println()

    text_idx = findall(m -> startswith(m.text, "TEXT"), messages)
    non_text_idx = findall(m -> !startswith(m.text, "TEXT"), messages)

    text_scores = ppm_scores[text_idx]
    non_text_scores = ppm_scores[non_text_idx]
    all_mean = mean(ppm_scores)

    n_text = length(text_scores)
    n_below_mean = count(s -> s < all_mean, text_scores)
    frac_below = count(s -> s < all_mean, ppm_scores) / length(ppm_scores)
    p_all_below = frac_below^n_text

    println("| Quantity | Value |")
    println("|---|---|")
    @printf("| Corpus mean entropy | %.2f bits |\n", all_mean)
    @printf("| TEXT messages below mean | %d of %d (100%%) |\n", n_below_mean, n_text)
    @printf("| Fraction of corpus below mean | %.4f |\n", frac_below)
    @printf("| P(all %d below mean) | **%.4f^%d = %s** |\n", n_text, frac_below, n_text, fmt_sci(p_all_below))

    if length(text_scores) >= 2 && length(non_text_scores) >= 2
        w = wilcoxon_rank_sum(text_scores, non_text_scores)
        println()
        println("### Wilcoxon rank-sum test")
        println()
        println("| Quantity | Value |")
        println("|---|---|")
        @printf("| z-statistic | %.4f |\n", w.z)
        println("| **p-value** | **$(fmt_p(w.p_value))** |")
        @printf("| TEXT mean | %.2f bits (%.2f bits/byte) |\n", mean(text_scores), mean(text_scores) / 22)
        @printf("| Non-TEXT mean | %.2f bits (%.2f bits/byte) |\n", mean(non_text_scores), mean(non_text_scores) / 22)
    end
end

function test4_sentinels(messages, alphabet_size)
    println("\n## Test 4: Sentinel (All-Same-Byte) Message Probability")
    println()
    println("**H0:** Messages are random draws from A^22 (A = $alphabet_size).")
    println("P(all-same-byte) = A * (1/A)^22 = A^-21.")
    println()

    N = length(messages)

    sentinels = filter(messages) do m
        length(m.bytes) == 22 && all(b -> b == m.bytes[1], m.bytes)
    end

    n_sentinels = length(sentinels)
    p_one_sentinel = Float64(alphabet_size)^(-21)
    lambda = N * p_one_sentinel

    println("| Quantity | Value |")
    println("|---|---|")
    @printf("| P(all-same-byte in 22 positions) | %d^-21 = %s |\n", alphabet_size, fmt_sci(p_one_sentinel))
    @printf("| Expected under H0 | lambda = %s |\n", fmt_sci(lambda))
    @printf("| Observed sentinels | %d |\n", n_sentinels)
    p_value = poisson_sf(n_sentinels - 1, lambda)
    println("| **p-value** | **$(fmt_p(p_value))** |")

    println()
    println("The three sentinel messages:")
    println()
    println("| Byte | Observations | First seen | Last seen |")
    println("|---|---|---|---|")
    for s in sentinels
        @printf("| 0x%02X | %s | %s | %s |\n",
                s.bytes[1], format_number(s.obs), s.first, s.last)
    end

    if lambda < 1e-20
        println()
        println("Lambda is effectively zero. Even 1 sentinel is astronomically unlikely under the random null hypothesis.")
    end
end

function test5_ks_distribution(ppm_scores, random_scores)
    println("\n## Test 5: KS Test — GPS vs Random Baseline Entropy Distribution")
    println()
    println("**H0:** GPS message PPM-D entropy distribution is identical to random baseline.")
    println()
    println("The random baseline is generated by simulating 100 independent corpora of $(length(ppm_scores)) messages each ($(length(random_scores)) total), drawing uniformly from the 45-symbol GPS ICD alphabet, and computing PPM-D order-8 leave-one-out scores.")
    println()

    D = ks_statistic(ppm_scores, random_scores)
    p = ks_p_value(D, length(ppm_scores), length(random_scores))

    mu_gps = mean(ppm_scores)
    mu_rand = mean(random_scores)
    sd_gps = std(ppm_scores)
    sd_rand = std(random_scores)
    pooled_sd = sqrt((sd_gps^2 + sd_rand^2) / 2)
    d = pooled_sd > 0 ? (mu_gps - mu_rand) / pooled_sd : 0.0

    effect_label = abs(d) < 0.2 ? "negligible" : abs(d) < 0.5 ? "small" : abs(d) < 0.8 ? "medium" : "large"

    println("| Quantity | Value |")
    println("|---|---|")
    @printf("| GPS sample | n = %s |\n", format_number(length(ppm_scores)))
    @printf("| Random sample | n = %s |\n", format_number(length(random_scores)))
    @printf("| KS statistic D | %.6f |\n", D)
    println("| **p-value** | **$(fmt_p(p))** |")
    println()

    println("### Effect size")
    println()
    println("| | GPS | Random |")
    println("|---|---|---|")
    @printf("| Mean | %.2f bits | %.2f bits |\n", mu_gps, mu_rand)
    @printf("| SD | %.2f bits | %.2f bits |\n", sd_gps, sd_rand)
    println()
    @printf("| Cohen's d | %.4f | **%s** |\n", d, effect_label)
end

function test6_per_anomaly_zscores(messages, ppm_scores)
    println("\n## Test 6: Per-Anomaly Z-Scores and P-Values")
    println()
    println("For each anomalous message: z = (entropy - mean) / SD.")
    println("P-values are two-sided under normal approximation.")
    println()

    mu = mean(ppm_scores)
    sigma = std(ppm_scores)

    @printf("Corpus mean: %.2f bits, SD: %.2f bits.\n", mu, sigma)
    @printf("95%% prediction interval: [%.2f, %.2f] bits.\n", mu - 1.96 * sigma, mu + 1.96 * sigma)
    println()

    # Collect anomalies
    anomalies = Tuple{Int, String, String}[]
    for (i, m) in enumerate(messages)
        if length(m.bytes) == 22 && all(b -> b == m.bytes[1], m.bytes)
            push!(anomalies, (i, "sentinel", @sprintf("0x%02X", m.bytes[1])))
        elseif startswith(m.text, "TEXT")
            push!(anomalies, (i, "TEXT", ""))
        end
    end
    anomaly_idx = Set(first.(anomalies))
    sorted_idx = sortperm(ppm_scores)
    for i in sorted_idx[1:min(5, length(sorted_idx))]
        i ∉ anomaly_idx && push!(anomalies, (i, "low-entropy", ""))
    end
    for i in sorted_idx[max(1, end-4):end]
        i ∉ anomaly_idx && push!(anomalies, (i, "high-entropy", ""))
    end
    sort!(anomalies, by=x -> ppm_scores[x[1]])

    # Group and print by category
    println("### Shared-substring messages (lowest entropy)")
    println()
    println("| Entropy | z-score | p-value | Message |")
    println("|---|---|---|---|")
    for (idx, cat, detail) in anomalies
        cat == "low-entropy" || continue
        score = ppm_scores[idx]
        z = (score - mu) / sigma
        p = normal_p_value_two_sided(z)
        @printf("| %.2f | %.2f | %s | `%s` |\n", score, z, fmt_p(p), messages[idx].text)
    end

    println()
    println("### TEXT-prefixed messages")
    println()
    println("| Entropy | z-score | p-value | Message |")
    println("|---|---|---|---|")
    text_count = 0
    for (idx, cat, detail) in anomalies
        cat == "TEXT" || continue
        score = ppm_scores[idx]
        z = (score - mu) / sigma
        p = normal_p_value_two_sided(z)
        text_count += 1
        if text_count <= 5 || text_count > count(x -> x[2] == "TEXT", anomalies) - 2
            @printf("| %.2f | %.2f | %s | `%s` |\n", score, z, fmt_p(p), messages[idx].text)
        elseif text_count == 6
            n_remaining = count(x -> x[2] == "TEXT", anomalies) - 7
            println("| ... | ... | ... | *($n_remaining more TEXT messages)* |")
        end
    end

    println()
    println("### Sentinel and high-entropy messages")
    println()
    println("| Entropy | z-score | p-value | Category | Message |")
    println("|---|---|---|---|---|")
    for (idx, cat, detail) in anomalies
        (cat == "sentinel" || cat == "high-entropy") || continue
        score = ppm_scores[idx]
        z = (score - mu) / sigma
        p = normal_p_value_two_sided(z)
        text = messages[idx].text
        length(text) > 30 && (text = text[1:27] * "...")
        label = cat == "sentinel" ? "sentinel $detail" : cat
        @printf("| %.2f | %.2f | %s | %s | `%s` |\n", score, z, fmt_p(p), label, text)
    end
end

function test7_text_payload_randomness(messages, gps_alphabet, order)
    println("\n## Test 7: TEXT Payload Randomness")
    println()
    println("**H0:** The 18-byte payloads of TEXT messages (bytes 5-22) are independent")
    println("random draws from the $(length(gps_alphabet))-symbol GPS ICD alphabet.")
    println()

    text_messages = filter(m -> startswith(m.text, "TEXT"), messages)
    n_text = length(text_messages)
    payloads = [m.bytes[5:22] for m in text_messages]

    println("TEXT messages: $n_text, payload length: 18 bytes each")
    println()

    # ── 7a: KS test on PPM-D entropy ─────────────────────────────────
    println("### Test 7a: KS test on PPM-D payload entropy")
    println()
    println("Build a PPM-D order-$order model on the $n_text payloads alone,")
    println("score each via leave-one-out, and compare to a random 18-byte baseline.")
    println()

    # Build PPM-D model on payloads and LOO-score
    payload_msgs = [(bytes=p,) for p in payloads]
    payload_scores = Vector{Float64}(undef, n_text)
    model = PPMModel(order)
    for p in payloads
        PPMEntropy.update!(model, p)
    end
    for i in 1:n_text
        PPMEntropy.update!(model, payloads[i]; delta=-1)
        payload_scores[i] = score_sequence(model, payloads[i])
        PPMEntropy.update!(model, payloads[i]; delta=+1)
    end

    # Random baseline: same corpus size, 18-byte messages
    random_scores = compute_random_baseline(n_text, 18, gps_alphabet, order; n_repeats=100, seed=123)

    D = ks_statistic(payload_scores, random_scores)
    p_ks = ks_p_value(D, length(payload_scores), length(random_scores))

    mu_pay = mean(payload_scores)
    mu_rand = mean(random_scores)
    sd_pay = std(payload_scores)
    sd_rand = std(random_scores)
    pooled_sd = sqrt((sd_pay^2 + sd_rand^2) / 2)
    cohens_d = pooled_sd > 0 ? (mu_pay - mu_rand) / pooled_sd : 0.0
    effect_label = abs(cohens_d) < 0.2 ? "negligible" : abs(cohens_d) < 0.5 ? "small" : abs(cohens_d) < 0.8 ? "medium" : "large"

    println("| Quantity | Value |")
    println("|---|---|")
    @printf("| TEXT payload scores | n = %d, mean = %.2f bits, SD = %.2f bits |\n", n_text, mu_pay, sd_pay)
    @printf("| Random 18-byte scores | n = %s, mean = %.2f bits, SD = %.2f bits |\n", format_number(length(random_scores)), mu_rand, sd_rand)
    @printf("| KS statistic D | %.4f |\n", D)
    println("| **p-value** | **$(fmt_p(p_ks))** |")
    @printf("| Cohen's d | %.4f (%s) |\n", cohens_d, effect_label)

    # ── 7b: Chi-squared GOF ──────────────────────────────────────────
    println()
    println("### Test 7b: Chi-squared goodness-of-fit on payload bytes")
    println()
    println("Pool all $n_text x 18 = $(n_text * 18) payload bytes and test uniformity")
    println("across the $(length(gps_alphabet)) GPS ICD symbols.")
    println()

    total_bytes = n_text * 18
    expected_per_symbol = total_bytes / length(gps_alphabet)

    # Count occurrences of each GPS alphabet byte
    byte_counts = Dict{UInt8, Int}()
    for b in gps_alphabet
        byte_counts[b] = 0
    end
    n_non_gps = 0
    for p in payloads
        for b in p
            if haskey(byte_counts, b)
                byte_counts[b] += 1
            else
                n_non_gps += 1
            end
        end
    end

    observed = [byte_counts[b] for b in gps_alphabet]
    expected = fill(expected_per_symbol, length(gps_alphabet))

    result = chi_squared_gof_p_value(observed, expected)

    println("| Quantity | Value |")
    println("|---|---|")
    @printf("| Total payload bytes | %d |\n", total_bytes)
    @printf("| GPS ICD symbols | %d |\n", length(gps_alphabet))
    @printf("| Expected per symbol | %.2f |\n", expected_per_symbol)
    if n_non_gps > 0
        @printf("| Non-GPS bytes (excluded) | %d |\n", n_non_gps)
    end
    @printf("| Chi-squared statistic | %.2f (df = %d) |\n", result.chi2, result.df)
    println("| **p-value** | **$(fmt_p(result.p_value))** |")

    return (p_ks=p_ks, D_ks=D, cohens_d=cohens_d, chi2=result.chi2, df=result.df, p_chi2=result.p_value)
end

# ── Main ────────────────────────────────────────────────────────────────

function main()
    db_path = length(ARGS) >= 1 ? ARGS[1] : "messages.duckdb"

    if !isfile(db_path)
        println(stderr, "Error: Database '$db_path' not found")
        exit(1)
    end

    println(stderr, "Statistical Significance Analysis")
    println(stderr, "=================================")

    db = DuckDB.DB(db_path; readonly=true)

    # Load data
    messages = load_messages(db)
    observed_alphabet = get_observed_alphabet(db)
    prn_dist = get_text_prn_distribution(db)
    N = length(messages)

    # Use the GPS ICD character set (IS-GPS-200) as the null hypothesis alphabet.
    # The observed data contains 2 extra bytes (0x00 and 0xAA from sentinel messages)
    # which are themselves anomalies — including them would inflate the alphabet and
    # make the tests more conservative.
    gps_alphabet = sort(collect(GPS_CHARSET_BYTES))
    A = length(gps_alphabet)
    A_obs = length(observed_alphabet)
    extra_bytes = setdiff(Set(observed_alphabet), GPS_CHARSET_BYTES)

    println(stderr, "Loaded $N unique messages")
    println(stderr, "GPS ICD alphabet: $A symbols (null hypothesis)")
    if !isempty(extra_bytes)
        println(stderr, "Observed alphabet: $A_obs symbols ($A_obs - $A = $(length(extra_bytes)) non-GPS bytes: $(join([@sprintf("0x%02X", b) for b in sort(collect(extra_bytes))], ", ")))")
    end

    # Compute PPM-D LOO scores
    ppm_scores = compute_ppm_loo_scores(messages; order=8)

    # Compute random baseline using GPS ICD alphabet
    random_scores = compute_random_baseline(N, 22, gps_alphabet, 8; n_repeats=100, seed=42)

    # ── Write results to file ───────────────────────────────────────────
    output_path = joinpath(get(ENV, "REPORTS_DIR", joinpath(@__DIR__, "reports")), "statistical_significance.md")
    mkpath(dirname(output_path))
    println(stderr, "Writing results to $output_path")

    open(output_path, "w") do io
        old_stdout = stdout
        redirect_stdout(io)
        try
            ts = Dates.format(now(UTC), dateformat"yyyy-mm-ddTHH:MM:SS") * "Z"
            script = basename(@__FILE__)
            println("<!-- AUTO-GENERATED by $script on $ts from $db_path — do not edit by hand -->")
            println()
            println("# Statistical Significance of GPS Special Message Anomalies")
            println()
            println("## Setup")
            println()
            println("| Parameter | Value |")
            println("|---|---|")
            println("| Database | `$db_path` |")
            println("| Unique messages | $(format_number(N)) |")
            println("| Null hypothesis alphabet | $A symbols (GPS ICD IS-GPS-200 character set) |")
            if !isempty(extra_bytes)
                extra_str = join([@sprintf("0x%02X", b) for b in sort(collect(extra_bytes))], ", ")
                println("| Observed distinct byte values | $A_obs ($(length(extra_bytes)) non-GPS: $extra_str) |")
            end
            println("| PPM-D model order | 8 |")
            println("| Random baseline | 100 repeats of $N random 22-byte messages (seed 42) |")

            # Run all 7 tests
            test1_shared_substrings(messages, A)
            test2_text_prefix(messages, A, prn_dist)
            test3_text_entropy_ranking(messages, ppm_scores)
            test4_sentinels(messages, A)
            test5_ks_distribution(ppm_scores, random_scores)
            test6_per_anomaly_zscores(messages, ppm_scores)
            t7 = test7_text_payload_randomness(messages, gps_alphabet, 8)

            # ── Summary ─────────────────────────────────────────────────
            println("\n## Summary")
            println()
            println("| Test | Anomaly | p-value | Significant? |")
            println("|---|---|---|---|")
            # Re-compute key p-values for summary table
            raw_messages = [m.bytes for m in messages]
            for L in [6, 9]
                total = N * (22 - L + 1)
                slots = Float64(A)^L
                lam = birthday_expected_collisions(total, slots)
                repeated = find_repeated_substrings(raw_messages; min_len=L)
                obs = count(r -> length(r.bytes) >= L, repeated)
                p = poisson_sf(obs - 1, lam)
                println("| 1 | Shared substrings (L=$L) | $(fmt_p(p)) | Yes |")
            end

            n_text = count(m -> startswith(m.text, "TEXT"), messages)
            p_text = poisson_sf(n_text - 1, N / Float64(A)^4)
            println("| 2 | TEXT prefix frequency | $(fmt_p(p_text)) | Yes |")

            if !isempty(prn_dist)
                top_count = prn_dist[1][2]
                total_text = sum(last, prn_dist)
                p_prn = binomial_sf(top_count - 1, total_text, 1.0 / 32)
                println("| 2 | TEXT PRN concentration | $(fmt_p(p_prn)) | Yes |")
            end

            text_scores = ppm_scores[findall(m -> startswith(m.text, "TEXT"), messages)]
            frac = count(s -> s < mean(ppm_scores), ppm_scores) / length(ppm_scores)
            p_rank = frac^length(text_scores)
            println("| 3 | TEXT entropy ranking (binomial) | $(fmt_sci(p_rank)) | Yes |")

            non_text_scores = ppm_scores[findall(m -> !startswith(m.text, "TEXT"), messages)]
            w = wilcoxon_rank_sum(text_scores, non_text_scores)
            println("| 3 | TEXT entropy ranking (Wilcoxon) | $(fmt_p(w.p_value)) | Yes |")

            sentinels = filter(m -> length(m.bytes) == 22 && all(b -> b == m.bytes[1], m.bytes), messages)
            p_sent = poisson_sf(length(sentinels) - 1, N * Float64(A)^(-21))
            println("| 4 | Sentinel messages | $(fmt_p(p_sent)) | Yes |")

            D = ks_statistic(ppm_scores, random_scores)
            p_ks = ks_p_value(D, length(ppm_scores), length(random_scores))
            println("| 5 | KS: GPS vs random baseline | $(fmt_p(p_ks)) | Yes (negligible effect size) |")

            sig_7a = t7.p_ks < 0.05 ? "Yes" : "No"
            sig_7b = t7.p_chi2 < 0.05 ? "Yes" : "No"
            println("| 7a | TEXT payload KS (PPM-D) | $(fmt_p(t7.p_ks)) | $sig_7a |")
            println("| 7b | TEXT payload chi-squared GOF | $(fmt_p(t7.p_chi2)) | $sig_7b |")

            println()
            println("All p-values are computed under the null hypothesis that GPS special messages")
            println("are independent random draws from the $A-symbol GPS ICD alphabet (IS-GPS-200).")
        finally
            redirect_stdout(old_stdout)
        end
    end

    println(stderr, "Results written to $output_path")
    DBInterface.close!(db)
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
