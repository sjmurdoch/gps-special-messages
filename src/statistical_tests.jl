"""
    StatisticalTests

Pure-math statistical testing helpers for GPS special message analysis.

Provides distribution functions (normal, Poisson, binomial), combinatorial
calculations (birthday problem), and non-parametric tests (KS, Wilcoxon).

This is a standalone module (not part of GPSSpecialMessages).
"""
module StatisticalTests

export normal_cdf, normal_sf, normal_p_value_two_sided, normal_p_value_one_sided
export poisson_pmf, poisson_cdf, poisson_sf
export binomial_sf
export birthday_expected_collisions
export ks_statistic, ks_p_value
export wilcoxon_rank_sum
export chi_squared_gof_p_value

# ── Normal distribution ─────────────────────────────────────────────────

"""
    normal_cdf(z) -> Float64

Standard normal CDF using the Abramowitz & Stegun approximation (formula 26.2.17).
Maximum error < 7.5e-8.
"""
function normal_cdf(z::Real)::Float64
    z = Float64(z)
    if z < -8.0
        return 0.0
    elseif z > 8.0
        return 1.0
    end
    az = abs(z)
    t = 1.0 / (1.0 + 0.2316419 * az)
    d = 0.3989422804014327 * exp(-az * az / 2.0)
    p = d * t * (0.319381530 + t * (-0.356563782 + t * (1.781477937 + t * (-1.821255978 + t * 1.330274429))))
    return z >= 0 ? 1.0 - p : p
end

"""
    normal_sf(z) -> Float64

Standard normal survival function: 1 - CDF(z).
"""
normal_sf(z::Real)::Float64 = 1.0 - normal_cdf(z)

"""
    normal_p_value_two_sided(z) -> Float64

Two-sided p-value: P(|Z| >= |z|) = 2 * SF(|z|).
"""
normal_p_value_two_sided(z::Real)::Float64 = 2.0 * normal_sf(abs(z))

"""
    normal_p_value_one_sided(z; tail=:left) -> Float64

One-sided p-value. `tail=:left` returns P(Z <= z), `tail=:right` returns P(Z >= z).
"""
function normal_p_value_one_sided(z::Real; tail::Symbol=:left)::Float64
    if tail === :left
        return normal_cdf(z)
    elseif tail === :right
        return normal_sf(z)
    else
        throw(ArgumentError("tail must be :left or :right, got :$tail"))
    end
end

# ── Poisson distribution ────────────────────────────────────────────────

"""
    _log_factorial(n) -> Float64

Log-factorial via direct summation. Suitable for small n (n <= ~30).
"""
function _log_factorial(n::Integer)::Float64
    n < 0 && throw(DomainError(n, "n must be non-negative"))
    n <= 1 && return 0.0
    s = 0.0
    for i in 2:n
        s += log(Float64(i))
    end
    s
end

"""
    poisson_pmf(k, lambda) -> Float64

Poisson probability mass function computed in log-space to avoid overflow.
"""
function poisson_pmf(k::Integer, lambda::Real)::Float64
    lambda = Float64(lambda)
    k < 0 && return 0.0
    lambda < 0 && throw(DomainError(lambda, "lambda must be non-negative"))
    lambda == 0.0 && return k == 0 ? 1.0 : 0.0
    log_pmf = k * log(lambda) - lambda - _log_factorial(k)
    exp(log_pmf)
end

"""
    poisson_cdf(k, lambda) -> Float64

Poisson CDF: P(X <= k).
"""
function poisson_cdf(k::Integer, lambda::Real)::Float64
    k < 0 && return 0.0
    lambda = Float64(lambda)
    lambda == 0.0 && return 1.0
    s = 0.0
    for i in 0:k
        s += poisson_pmf(i, lambda)
    end
    min(s, 1.0)
end

"""
    poisson_sf(k, lambda) -> Float64

Poisson survival function: P(X > k) = 1 - P(X <= k).
"""
poisson_sf(k::Integer, lambda::Real)::Float64 = 1.0 - poisson_cdf(k, lambda)

# ── Binomial distribution ───────────────────────────────────────────────

"""
    binomial_sf(k, n, p) -> Float64

Binomial survival function: P(X > k) where X ~ Binomial(n, p).
Uses normal approximation for large n*p*(1-p), direct computation otherwise.
"""
function binomial_sf(k::Integer, n::Integer, p::Real)::Float64
    p = Float64(p)
    (p < 0 || p > 1) && throw(DomainError(p, "p must be in [0,1]"))
    n < 0 && throw(DomainError(n, "n must be non-negative"))
    k < 0 && return 1.0
    k >= n && return 0.0

    # Edge cases for degenerate distributions
    if p == 0.0
        # X is always 0, so P(X > k) = 0 for k >= 0
        return 0.0
    end
    if p == 1.0
        # X is always n, so P(X > k) = 1 if k < n, 0 if k >= n
        return k < n ? 1.0 : 0.0
    end

    mu = n * p
    sigma2 = n * p * (1 - p)

    if sigma2 > 25.0
        # Normal approximation with continuity correction
        z = (k + 0.5 - mu) / sqrt(sigma2)
        return normal_sf(z)
    end

    # Direct computation in log-space
    # P(X > k) = sum_{i=k+1}^{n} C(n,i) * p^i * (1-p)^(n-i)
    sf = 0.0
    log_p = log(p)
    log_q = log(1 - p)
    log_n_fact = _log_factorial(n)

    for i in (k+1):n
        log_binom = log_n_fact - _log_factorial(i) - _log_factorial(n - i)
        log_term = log_binom + i * log_p + (n - i) * log_q
        sf += exp(log_term)
    end
    min(sf, 1.0)
end

# ── Birthday problem ────────────────────────────────────────────────────

"""
    birthday_expected_collisions(n_items, n_slots) -> Float64

Expected number of collisions under the birthday problem model.
Returns lambda = n_items * (n_items - 1) / (2 * n_slots).
"""
function birthday_expected_collisions(n_items::Integer, n_slots::Real)::Float64
    n_slots = Float64(n_slots)
    n_slots <= 0 && throw(DomainError(n_slots, "n_slots must be positive"))
    Float64(n_items) * Float64(n_items - 1) / (2.0 * n_slots)
end

# ── Kolmogorov-Smirnov test ─────────────────────────────────────────────

"""
    ks_statistic(sample1, sample2) -> Float64

Two-sample Kolmogorov-Smirnov test statistic D (maximum absolute difference
between empirical CDFs), computed via merged ECDF walk.
"""
function ks_statistic(sample1::AbstractVector{<:Real}, sample2::AbstractVector{<:Real})::Float64
    n1 = length(sample1)
    n2 = length(sample2)
    (n1 == 0 || n2 == 0) && throw(ArgumentError("samples must be non-empty"))

    s1 = sort(sample1)
    s2 = sort(sample2)

    D = 0.0
    i = 1
    j = 1
    ecdf1 = 0.0
    ecdf2 = 0.0

    while i <= n1 && j <= n2
        if s1[i] < s2[j]
            ecdf1 = i / n1
            i += 1
        elseif s1[i] > s2[j]
            ecdf2 = j / n2
            j += 1
        else
            # Tied values: advance both pointers past all ties
            val = s1[i]
            while i <= n1 && s1[i] == val
                i += 1
            end
            while j <= n2 && s2[j] == val
                j += 1
            end
            ecdf1 = (i - 1) / n1
            ecdf2 = (j - 1) / n2
        end
        d = abs(ecdf1 - ecdf2)
        d > D && (D = d)
    end

    # Drain remaining
    while i <= n1
        ecdf1 = i / n1
        i += 1
        d = abs(ecdf1 - ecdf2)
        d > D && (D = d)
    end
    while j <= n2
        ecdf2 = j / n2
        j += 1
        d = abs(ecdf1 - ecdf2)
        d > D && (D = d)
    end

    D
end

"""
    ks_p_value(D, n1, n2) -> Float64

Approximate p-value for the two-sample KS test using the Kolmogorov series
with Stephens' finite-sample correction.

P(D_n > d) ≈ 2 * sum_{k=1}^{inf} (-1)^{k+1} * exp(-2 k^2 lambda^2)

where lambda = (sqrt(n_e) + 0.12 + 0.11/sqrt(n_e)) * D  (Stephens correction)
and n_e = n1*n2 / (n1+n2).
"""
function ks_p_value(D::Real, n1::Integer, n2::Integer)::Float64
    D = Float64(D)
    D <= 0 && return 1.0
    D >= 1 && return 0.0

    n_e = Float64(n1) * Float64(n2) / Float64(n1 + n2)
    sqrt_ne = sqrt(n_e)

    # Stephens correction
    lambda = (sqrt_ne + 0.12 + 0.11 / sqrt_ne) * D

    # Kolmogorov series: P = 2 * sum_{k=1}^{inf} (-1)^{k+1} * exp(-2*k^2*lambda^2)
    p = 0.0
    for k in 1:100
        term = (-1.0)^(k + 1) * exp(-2.0 * k^2 * lambda^2)
        p += term
        abs(term) < 1e-15 && break
    end
    p *= 2.0
    clamp(p, 0.0, 1.0)
end

# ── Wilcoxon rank-sum test ──────────────────────────────────────────────

"""
    wilcoxon_rank_sum(sample1, sample2) -> (z=Float64, p_value=Float64)

Two-sided Wilcoxon rank-sum (Mann-Whitney U) test via normal approximation
with tie-averaged ranks. Returns z-statistic and two-sided p-value.
"""
function wilcoxon_rank_sum(sample1::AbstractVector{<:Real}, sample2::AbstractVector{<:Real})
    n1 = length(sample1)
    n2 = length(sample2)
    (n1 == 0 || n2 == 0) && throw(ArgumentError("samples must be non-empty"))

    N = n1 + n2

    # Combine with group labels, sort, assign average ranks
    combined = Vector{Tuple{Float64, Int}}(undef, N)
    for i in 1:n1
        combined[i] = (Float64(sample1[i]), 1)
    end
    for i in 1:n2
        combined[n1 + i] = (Float64(sample2[i]), 2)
    end
    sort!(combined, by=first)

    # Assign average ranks for ties
    ranks = Vector{Float64}(undef, N)
    i = 1
    while i <= N
        j = i
        while j <= N && combined[j][1] == combined[i][1]
            j += 1
        end
        avg_rank = (i + j - 1) / 2.0
        for k in i:j-1
            ranks[k] = avg_rank
        end
        i = j
    end

    # Sum of ranks for sample 1
    R1 = 0.0
    for k in 1:N
        if combined[k][2] == 1
            R1 += ranks[k]
        end
    end

    # Expected value and variance under H0
    mu_R = n1 * (N + 1) / 2.0

    # Tie correction for variance
    tie_correction = 0.0
    i = 1
    while i <= N
        j = i
        while j <= N && combined[j][1] == combined[i][1]
            j += 1
        end
        t = j - i
        if t > 1
            tie_correction += t^3 - t
        end
        i = j
    end

    sigma_R = sqrt(Float64(n1) * Float64(n2) / 12.0 * (N + 1 - tie_correction / (N * (N - 1))))

    if sigma_R == 0.0
        return (z=0.0, p_value=1.0)
    end

    z = (R1 - mu_R) / sigma_R
    p = normal_p_value_two_sided(z)
    (z=z, p_value=p)
end

# ── Chi-squared goodness-of-fit ────────────────────────────────────────

"""
    chi_squared_gof_p_value(observed, expected) -> (chi2=Float64, df=Int, p_value=Float64)

Chi-squared goodness-of-fit test. `observed` and `expected` are vectors of counts
(same length). Returns the chi-squared statistic, degrees of freedom (length - 1),
and p-value via the Wilson-Hilferty normal approximation to the chi-squared distribution.
"""
function chi_squared_gof_p_value(observed::AbstractVector{<:Real}, expected::AbstractVector{<:Real})
    length(observed) == length(expected) || throw(ArgumentError("observed and expected must have the same length"))
    length(observed) >= 2 || throw(ArgumentError("need at least 2 categories"))

    chi2 = 0.0
    for i in eachindex(observed, expected)
        expected[i] > 0 || throw(ArgumentError("expected counts must be positive"))
        chi2 += (Float64(observed[i]) - Float64(expected[i]))^2 / Float64(expected[i])
    end

    df = length(observed) - 1

    # Wilson-Hilferty normal approximation: z = ((chi2/df)^(1/3) - (1 - 2/(9*df))) / sqrt(2/(9*df))
    k = Float64(df)
    z = (cbrt(chi2 / k) - (1.0 - 2.0 / (9.0 * k))) / sqrt(2.0 / (9.0 * k))
    p = normal_sf(z)

    (chi2=chi2, df=df, p_value=p)
end

end # module
