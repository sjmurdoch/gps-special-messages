# Article claims and verifiers

Every quantitative claim in [feature-article.md](https://github.com/sjmurdoch/gps-special-messages) (link TBC at publication) is mapped here to either a script under `verify/` (run via `verify/run_all.sh`) or to an external citation.

This file is the contract: a claim that isn't here either gets a verifier or gets cut.

## Claims with automated verifiers

`verify/run_all.sh` runs all of the below in turn and exits non-zero on divergence.

| Article footnote | Claim | Verifier | Tolerance |
|---|---|---|---|
| `[^2]` | 12,163,006 observations / 3,994 unique messages / 32 PRNs / 2007-06-19 → 2026-01-23 | `verify/corpus_totals.jl` | exact equality |
| `[^17]` | χ² test against uniform 45-symbol alphabet: z = 1.84 | `verify/chi_squared.jl` | ±0.01 |
| `[^29]` | 31 PRNs (2..32) entered all-¬ on 2011-05-26 (PRN 1 absent) | `verify/fleet_flash_2011.jl` | exact PRN list |
| `[^33]` (chart-metric subset) | rotation rate ≈ 3.7 / 1.8 / 4.3 days for 2007–2010 / 2012–2021 / 2022+ (uniq/sat/wk inverted to days) | `verify/rotation_regimes.jl` | ±0.1–0.5 d per era |
| `[^33]` (qualitative) | post-2022 era rotates strictly slower than pre-2011 era | `verify/rotation_regimes.jl` | ≥ 0.2 d gap |
| `[^38]` | May 2022 reversion: coordinated change point detected on weekly `unique_message_count` | `verify/rotation_regimes.jl` | within 2022-04-15 to 2022-06-30 |
| `[^41]` | 2014-10-08 pair sharing 10-char `.'HX-+7UX ` | `verify/shared_substrings.jl` | exactly 2 distinct messages |
| `[^42]` | 2020-09-19 / 2021-06-05 pair sharing 9-char `LY47IRP16` | `verify/shared_substrings.jl` | exactly 2 distinct messages |
| `[^43]` | 2019-11-20 / 2019-12-11 pair sharing 9-char `:U'5PSF8T` (article says 8) | `verify/shared_substrings.jl` | exactly 2 distinct messages |
| (companion to `[^43]`) | 2024-04-07 / 2024-04-11 pair sharing 9-char `ZU°SGZ8PJ` | `verify/shared_substrings.jl` | exactly 2 distinct messages |
| `[^44]` | 2019-06-19 / 2019-09-14 pair sharing 7-char `S°6L.D°` | `verify/shared_substrings.jl` | exactly 2 distinct messages |
| `[^49]`, `[^50]` | 26 unique TEXT-prefix messages / 38 (PRN, day) combos / 2,398 observations | `verify/text_migration.jl` | exact equality |
| `[^27]` | NANU 2010113 USABINIT for PRN 25 on 2010-08-27 | `verify/prn25_timeline.jl` | exact NANU id + date |
| (PRN 25 lifecycle) | NANU 2009130 UNUSUFN on 2009-12-18; 2010098 LAUNCH on 2010-05-28 | `verify/prn25_timeline.jl` | exact NANU id + date |
| (PRN 25 sentinel obs) | PRN 25 broadcast all-¬ in 2010 (≥1 obs) | `verify/prn25_timeline.jl` | non-empty |

## Claims with external citations (no DB verifier needed)

These are sourced to primary documents; run the cited link, not a script.

| Article footnote | Claim | Source |
|---|---|---|
| `[^1]` | IS-GPS-200 reserves SF4 P17 for special messages | IS-GPS-200N §20.3.3.5.1.8, p. 122 |
| `[^4]` | L1 C/A 50 bps; 1500-bit frame; 5 × 300-bit subframes | IS-GPS-200N §20.3.1, §20.3.2 |
| `[^5]` | Page 17 visible every 12.5 minutes | IS-GPS-200N §20.3.2 (`25 frames × 30 s`) |
| `[^8]` | (32, 26) Hamming parity code | IS-GPS-200N §20.3.5.1, Table 20-XIV |
| `[^11]` | 45-symbol alphabet | IS-GPS-200N §20.3.3.5.1.8 |
| `[^26]` | PRN 25 Block IIA decommissioned Dec 2009; first IIF May 2010 | <https://en.wikipedia.org/wiki/List_of_GPS_satellites> |
| `[^31]`, `[^32]`, `[^35]` | OTAD/OTAR mechanism, mission constellations, March 2011 operational start | Tyley 2015 briefing (see [DATA.md](DATA.md)) |
| `[^36]` | September 2020 SVN 74 / PRN 04 anomaly; ADS-B effects | Walter et al. 2021 (see [DATA.md](DATA.md)) |
| `[^48]` | IS-GPS-200 specifies envelope only, not type-identifier protocol | IS-GPS-200N §20.3.3.5.1.8 |

## Claims derivable from cited material (math only; not separately verified)

| Article footnote | Claim | Derivation |
|---|---|---|
| `[^6]` | ~3,700 special-message payloads per day fleet-wide | 32 satellites × (24 × 60 / 12.5 min/visibility) ≈ 3,686 |
| `[^16]` | Expected uniform frequency ≈ 2.22% | 1 / 45 symbols |
| `[^24]` | 0xAA = `0b10101010` | mathematical identity |
| `[^45]` | Probability of a 9-char match by chance ≈ 1 / 45⁹ ≈ 1.3 × 10⁻¹⁵ | 45⁻⁹ direct |

## Claims supported by automatically-generated reports (not yet wrapped in verifiers)

These are computed once by `analysis/run_all.sh` and committed under `analysis/reports/`. A future verifier could wrap each as a one-liner SQL check; for now the published report is the artefact.

| Article footnote | Claim | Report |
|---|---|---|
| `[^19]` | PPM-D order-8 marginal entropy: μ = 131.51 bits, σ = 7.56 | `analysis/reports/marginal_entropy_ppm.md` |
| `[^21]` | 3 zero-entropy messages in the corpus | `analysis/reports/marginal_entropy_ppm.md`, also implied by entropy range in `analysis/reports/statistical_significance.md` |
| `[^22]` | three sentinel byte values: 0x20 (space), 0x00 (NUL), 0xAA (¬) | `analysis/reports/sentinel_nanu.md` |
| `[^23]` | all-¬ first appears 2010-02-14 on PRN 25; covers all 32 PRNs over 10+ years | `analysis/reports/sentinel_nanu.md` |
| `[^25]` | sentinel-NANU correlation **not** statistically significant (p = 0.4360) | `analysis/reports/sentinel_nanu.md` |
| `[^28]` | only 2 messages (both all-¬ sentinel) appear in more than 2 calendar months for any PRN | `analysis/reports/behavioral_changes.md` |
| `[^34]` | H1 2011 cascade of 4 coordinated change points (Jan, Feb, May, Jun) | `analysis/reports/otad_hypothesis.md` §"H1 2011 detailed change points" |
| `[^38]` (full) | May 2022 reversion: 17–32 PRNs depending on metric, no NANU within correlation window | `analysis/reports/behavioral_changes.md` §2; `analysis/reports/nanu_correlation.md` §4 |
| `[^39]` | 2022 reversion attributed (speculatively) to OCX deployment / M-code transition / policy change | `analysis/reports/otad_hypothesis.md` §"OTAD Era Summary"; flagged as speculative there |

## Interpretive / authorial claims (no verifier; flagged in the article)

`[^3]`, `[^9]`, `[^14]`, `[^15]`, `[^18]`, `[^20]`, `[^30]`, `[^46]`, `[^47]` — see article footnotes for the source of each. These are interpretive readings or author's notes, not numeric assertions.

## Open follow-ups

- **PPM-D verification**: `verify/shared_substrings.jl` confirms each named substring via SQL `LIKE` but doesn't re-run the PPM-D model, so a *new* shared substring at length ≥ 7 would slip past. Cost is ~5 min CPU; deferred for now.
