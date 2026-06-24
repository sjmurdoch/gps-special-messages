include(joinpath(@__DIR__, "..", "src", "statistical_tests.jl"))
using .StatisticalTests

@testset "Statistical Tests" begin

    # ── Normal CDF ──────────────────────────────────────────────────────

    @testset "normal_cdf known values" begin
        @test normal_cdf(0.0) ≈ 0.5 atol=1e-7
        @test normal_cdf(1.96) ≈ 0.975 atol=1e-4
        @test normal_cdf(-1.96) ≈ 0.025 atol=1e-4
        @test normal_cdf(3.0) ≈ 0.99865 atol=1e-4
        @test normal_cdf(-3.0) ≈ 0.00135 atol=1e-4
    end

    @testset "normal_cdf symmetry" begin
        for z in [0.5, 1.0, 2.0, 2.5]
            @test normal_cdf(z) + normal_cdf(-z) ≈ 1.0 atol=1e-7
        end
    end

    @testset "normal_cdf extremes" begin
        @test normal_cdf(-10.0) == 0.0
        @test normal_cdf(10.0) == 1.0
    end

    @testset "normal_sf" begin
        @test normal_sf(0.0) ≈ 0.5 atol=1e-7
        @test normal_sf(1.96) ≈ 0.025 atol=1e-4
    end

    # ── Normal p-values ─────────────────────────────────────────────────

    @testset "normal_p_value_two_sided" begin
        @test normal_p_value_two_sided(1.96) ≈ 0.05 atol=1e-3
        @test normal_p_value_two_sided(0.0) ≈ 1.0 atol=1e-7
        @test normal_p_value_two_sided(2.576) ≈ 0.01 atol=1e-3
    end

    @testset "normal_p_value_one_sided" begin
        @test normal_p_value_one_sided(0.0; tail=:left) ≈ 0.5 atol=1e-7
        @test normal_p_value_one_sided(0.0; tail=:right) ≈ 0.5 atol=1e-7
        @test normal_p_value_one_sided(1.645; tail=:right) ≈ 0.05 atol=1e-3
        @test_throws ArgumentError normal_p_value_one_sided(0.0; tail=:both)
    end

    # ── Poisson ─────────────────────────────────────────────────────────

    @testset "poisson_pmf known values" begin
        # Poisson(1): P(0) = e^{-1} ≈ 0.3679
        @test poisson_pmf(0, 1.0) ≈ exp(-1.0) atol=1e-10
        # P(1) = e^{-1} ≈ 0.3679
        @test poisson_pmf(1, 1.0) ≈ exp(-1.0) atol=1e-10
        # P(2) = e^{-1}/2 ≈ 0.1839
        @test poisson_pmf(2, 1.0) ≈ exp(-1.0) / 2 atol=1e-10
    end

    @testset "poisson_pmf edge cases" begin
        @test poisson_pmf(-1, 1.0) == 0.0
        @test poisson_pmf(0, 0.0) == 1.0
        @test poisson_pmf(1, 0.0) == 0.0
        @test_throws DomainError poisson_pmf(0, -1.0)
    end

    @testset "poisson_pmf sums to ~1" begin
        lambda = 5.0
        total = sum(poisson_pmf(k, lambda) for k in 0:30)
        @test total ≈ 1.0 atol=1e-8
    end

    @testset "poisson_cdf" begin
        @test poisson_cdf(-1, 1.0) == 0.0
        @test poisson_cdf(0, 0.0) == 1.0
        # P(X<=2 | lambda=1) = e^{-1}(1 + 1 + 1/2) = 5e^{-1}/2
        @test poisson_cdf(2, 1.0) ≈ 5 * exp(-1.0) / 2 atol=1e-10
    end

    @testset "poisson_sf" begin
        # SF(k) = 1 - CDF(k)
        @test poisson_sf(2, 1.0) ≈ 1.0 - poisson_cdf(2, 1.0) atol=1e-10
        # SF(-1) = 1.0
        @test poisson_sf(-1, 1.0) == 1.0
    end

    # ── Birthday problem ────────────────────────────────────────────────

    @testset "birthday_expected_collisions classic" begin
        # Classic: 23 people, 365 days => P(collision) ≈ 0.507
        # lambda = 23*22/(2*365) ≈ 0.6932
        lambda = birthday_expected_collisions(23, 365)
        @test lambda ≈ 23 * 22 / (2 * 365) atol=1e-10
        # P(at least 1) = 1 - e^{-lambda} ≈ 0.500 (Poisson approximation)
        p_collision = 1.0 - exp(-lambda)
        @test p_collision ≈ 0.50 atol=0.02
    end

    @testset "birthday_expected_collisions edge cases" begin
        @test birthday_expected_collisions(0, 100) == 0.0
        @test birthday_expected_collisions(1, 100) == 0.0
        @test_throws DomainError birthday_expected_collisions(10, 0)
    end

    @testset "birthday_expected_collisions GPS sanity" begin
        # For 5009 unique messages (v2 corpus), 22-byte alphabet 45, substrings of length 9:
        # substrings_per_msg = 14, total = 5009*14 = 70126
        # slots = 45^9 ≈ 7.567e14
        # lambda = 70126*70125/(2*7.567e14) ≈ 3.2e-6
        N = 5009
        M = 22
        A = 45
        L = 9
        total = N * (M - L + 1)
        slots = Float64(A)^L
        lambda = birthday_expected_collisions(total, slots)
        @test lambda > 0
        @test lambda < 1.0  # should be small for L=9
    end

    # ── Binomial SF ─────────────────────────────────────────────────────

    @testset "binomial_sf fair coin" begin
        # P(X > 5 | Binomial(10, 0.5)) ≈ 0.377
        p = binomial_sf(5, 10, 0.5)
        @test p ≈ 0.377 atol=0.01
    end

    @testset "binomial_sf boundary values" begin
        @test binomial_sf(-1, 10, 0.5) == 1.0
        @test binomial_sf(10, 10, 0.5) == 0.0
    end

    @testset "binomial_sf extreme p" begin
        # p=0: X is always 0, so P(X > 0) = 0
        @test binomial_sf(0, 10, 0.0) == 0.0
        # p=1: X is always n=10, so P(X > 0) = 1
        @test binomial_sf(0, 10, 1.0) == 1.0
        # p=1: P(X > 9) = 1 since X=10 always
        @test binomial_sf(9, 10, 1.0) == 1.0
    end

    @testset "binomial_sf normal approximation" begin
        # Large n: P(X > 500 | Binomial(1000, 0.5)) ≈ 0.5
        p = binomial_sf(500, 1000, 0.5)
        @test p ≈ 0.5 atol=0.02
    end

    # ── KS statistic ────────────────────────────────────────────────────

    @testset "ks_statistic identical samples" begin
        s = Float64[1, 2, 3, 4, 5]
        @test ks_statistic(s, s) == 0.0
    end

    @testset "ks_statistic disjoint samples" begin
        s1 = Float64[1, 2, 3]
        s2 = Float64[4, 5, 6]
        @test ks_statistic(s1, s2) ≈ 1.0
    end

    @testset "ks_statistic known value" begin
        s1 = Float64[1, 2, 3, 4]
        s2 = Float64[1, 2, 3, 5]
        # ECDFs differ only at the last step
        D = ks_statistic(s1, s2)
        @test 0 < D < 1
    end

    @testset "ks_statistic empty throws" begin
        @test_throws ArgumentError ks_statistic(Float64[], Float64[1.0])
    end

    # ── KS p-value ──────────────────────────────────────────────────────

    @testset "ks_p_value small D → large p" begin
        p = ks_p_value(0.01, 100, 100)
        @test p > 0.9
    end

    @testset "ks_p_value large D → small p" begin
        p = ks_p_value(0.5, 100, 100)
        @test p < 0.001
    end

    @testset "ks_p_value edge cases" begin
        @test ks_p_value(0.0, 10, 10) == 1.0
        @test ks_p_value(1.0, 10, 10) == 0.0
    end

    # ── Wilcoxon rank-sum ───────────────────────────────────────────────

    @testset "wilcoxon identical distributions → high p" begin
        s1 = Float64[1, 3, 5, 7, 9]
        s2 = Float64[2, 4, 6, 8, 10]
        result = wilcoxon_rank_sum(s1, s2)
        @test result.p_value > 0.5
    end

    @testset "wilcoxon separated distributions → low p" begin
        s1 = Float64[1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
        s2 = Float64[100, 200, 300, 400, 500, 600, 700, 800, 900, 1000]
        result = wilcoxon_rank_sum(s1, s2)
        @test result.p_value < 0.01
    end

    @testset "wilcoxon with ties" begin
        s1 = Float64[1, 1, 2, 3]
        s2 = Float64[1, 2, 3, 3]
        result = wilcoxon_rank_sum(s1, s2)
        @test isfinite(result.z)
        @test 0 <= result.p_value <= 1
    end

    @testset "wilcoxon empty throws" begin
        @test_throws ArgumentError wilcoxon_rank_sum(Float64[], Float64[1.0])
    end

    # ── Chi-squared GOF ─────────────────────────────────────────────────

    @testset "chi_squared_gof_p_value uniform → high p" begin
        observed = fill(10.0, 45)
        expected = fill(10.0, 45)
        result = chi_squared_gof_p_value(observed, expected)
        @test result.chi2 ≈ 0.0 atol=1e-10
        @test result.df == 44
        @test result.p_value > 0.99
    end

    @testset "chi_squared_gof_p_value skewed → low p" begin
        observed = zeros(45)
        observed[1] = 450.0  # all counts in one bin
        expected = fill(10.0, 45)
        result = chi_squared_gof_p_value(observed, expected)
        @test result.chi2 > 1000
        @test result.p_value < 0.001
    end

    @testset "chi_squared_gof_p_value known reference" begin
        # chi2 = 60.0, df = 44 → p ≈ 0.054 (from chi-squared tables)
        # Build observed to give chi2 ≈ 60
        expected = fill(100.0, 45)
        # chi2 = sum((O-E)^2/E). With O_i = E_i + delta_i, chi2 = sum(delta_i^2/E_i)
        # We need sum(delta^2/100) = 60, so sum(delta^2) = 6000
        # Use 30 bins with delta = ±sqrt(200) ≈ ±14.14
        observed = copy(expected)
        delta = sqrt(200.0)
        for i in 1:15
            observed[i] = 100.0 + delta
            observed[i+15] = 100.0 - delta
        end
        result = chi_squared_gof_p_value(observed, expected)
        @test result.chi2 ≈ 60.0 atol=0.1
        @test result.df == 44
        # Wilson-Hilferty approximation for chi2=60, df=44 → p ≈ 0.054
        @test 0.03 < result.p_value < 0.08
    end

    @testset "chi_squared_gof_p_value input validation" begin
        @test_throws ArgumentError chi_squared_gof_p_value([1.0], [1.0])  # need >= 2
        @test_throws ArgumentError chi_squared_gof_p_value([1.0, 2.0], [1.0])  # length mismatch
        @test_throws ArgumentError chi_squared_gof_p_value([1.0, 2.0], [0.0, 1.0])  # zero expected
    end

    # ── _log_factorial ──────────────────────────────────────────────────

    @testset "_log_factorial" begin
        @test StatisticalTests._log_factorial(0) == 0.0
        @test StatisticalTests._log_factorial(1) == 0.0
        @test StatisticalTests._log_factorial(5) ≈ log(120.0) atol=1e-10
        @test StatisticalTests._log_factorial(10) ≈ log(3628800.0) atol=1e-8
        @test_throws DomainError StatisticalTests._log_factorial(-1)
    end

end
