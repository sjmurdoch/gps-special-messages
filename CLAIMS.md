# Article claims and verifiers

Every quantitative claim in [The Empty Field That Wasn't: GPS, OTAD and Two Decades of Encrypted Broadcasts](article/the-empty-field-that-wasnt.md) (v2; originally published in [*Inside GNSS*, May/June 2026](https://lsc-pagepro.mydigitalpublication.com/publication/?i=865273)) is mapped here to either a script under `verify/` (run via `verify/run_all.sh`) or to an external citation.

This file is the contract: a claim that isn't here either gets a verifier or gets cut.

> **v1 → v2 transition.** The published (v1) article reflects a corpus halved by the D30* page-identification bug, fixed in the v2 decoder. The values below are the corrected (v2) numbers and match the regenerated database, reports, and the v2 article text. Footnote keys are the article's sequential numbering (the printed *Inside GNSS* article carried no footnotes; the corrected values and the claims withdrawn outright are in [CHANGELOG.md](CHANGELOG.md)).

## Claims with automated verifiers

`verify/run_all.sh` runs all of the below in turn and exits non-zero on divergence.

| Footnote | Claim | Verifier | Tolerance |
|---|---|---|---|
| `[^2]` | 24,087,691 observations / 5,009 unique messages / 32 PRNs / 2007-06-19 → 2026-01-23 | `verify/corpus_totals.jl` | exact equality |
| `[^13]` | χ² test against uniform 45-symbol alphabet: χ² = 58.99, df = 44, z = 1.598; expected 1/45 ≈ 2.22% per symbol | `verify/chi_squared.jl` | ±0.01 on z |
| `[^50]` (capacity) | field obeys the 45-symbol envelope (99.96% of bytes in-alphabet; only out-of-alphabet bytes are sentinels 0x00 & 0xAA); usable capacity 22·log₂45 ≈ 120.8 bits < 128 (a 128-bit key needs 24 symbols) | `verify/field_capacity.jl` | exact out-of-alphabet byte set; capacity ±0.02 bits |
| `[^25]` | only 1 message (the all-¬ sentinel) appears in more than 2 calendar months for any PRN (max 6 months) | `verify/calendar_months.jl` | exact |
| `[^26]` | July 2020 sentinel event: 29 PRNs / 1,438 obs on 2020-07-22; last sentinel observation in the corpus | `verify/sentinel_event_2020.jl` | exact |
| `[^24]` | NANU 2010113 USABINIT for PRN 25 on 2010-08-27 | `verify/prn25_timeline.jl` | exact NANU id + date |
| (PRN 25 lifecycle) | NANU 2009130 UNUSUFN on 2009-12-18; 2010098 LAUNCH on 2010-05-28 | `verify/prn25_timeline.jl` | exact NANU id + date |
| (PRN 25 sentinel obs) | PRN 25 broadcast all-¬ in 2010 (≥1 obs) | `verify/prn25_timeline.jl` | non-empty |
| `[^32]` | January 2011 sentinel onset: 32 PRNs entered all-¬ on 2011-01-11 (none in the prior week), exited 2011-01-13; first-ever all-¬ for 28 PRNs | `verify/sentinel_onset_2011.jl` | exact |
| `[^33]` | 31 PRNs (2..32) entered all-¬ on 2011-05-26 (PRN 1 absent) | `verify/fleet_flash_2011.jl` | exact PRN list |
| `[^40]` | May 2022 reversion: coordinated change point detected on weekly `unique_message_count` | `verify/rotation_regimes.jl` | within 2022-04-15 to 2022-06-30 |
| `[^41]` (chart metric) | rotation rate ≈ 2.50 / 0.96 / 2.31 days for 2007–2010 / 2012–2021 / 2022+ (uniq/sat/wk inverted to days) | `verify/rotation_regimes.jl` | ±0.05–0.1 d per era |
| `[^41]` (qualitative) | ~~post-2022 era rotates strictly slower than pre-2011 era~~ — **withdrawn in v2** (2.31 vs 2.50 d: indistinguishable, slightly faster; see [CHANGELOG.md](CHANGELOG.md)). Replaced by: the operational era rotates >2× faster than both outer eras | `verify/rotation_regimes.jl` | factor-2 gap |
| `[^39]` (diversity) | per-year unique messages: 50–114 in 2007–2010, 368–404 in 2012–2021 | `verify/message_diversity.jl` | exact min/max per era |
| `[^44]` | 2014-10-08 pair sharing 10-char `.'HX-+7UX ` (Figure 5 Group B) | `verify/shared_substrings.jl` | exactly 2 distinct messages |
| `[^45]` | 2020-09-19 / 2021-06-05 pair sharing 9-char `LY47IRP16` (Group D) | `verify/shared_substrings.jl` | exactly 2 distinct messages |
| `[^46]` | 2019-11-20 / 2019-12-11 pair sharing 9-char `:U'5PSF8T` (Group A; v1 article and figure said 8 — label error, corrected in v2) | `verify/shared_substrings.jl` | exactly 2 distinct messages |
| `[^47]` | 2024-04-07 / 2024-04-10 pair sharing 9-char `ZU°SGZ8PJ` (Group C) and 2014-08-28 / 2014-11-26 pair sharing 7-char `HG"2'CA` (Group E — partner message absent from the v1 corpus) | `verify/shared_substrings.jl` | exactly 2 distinct messages each |
| `[^48]` | 2019-06-19 / 2019-09-14 pair sharing 7-char `S°6L.D°` (Group F) | `verify/shared_substrings.jl` | exactly 2 distinct messages |
| `[^52]` | fleet-wide TEXT inception: 2023-12-12 (9 PRNs, 1 payload) → 2023-12-13 (32 PRNs, 2 payloads), 2,737 obs | `verify/text_inception_2023.jl` | exact |
| `[^52]`, `[^56]` | 55 unique TEXT-prefix messages / 122 (PRN, day) combos / 8,248 observations | `verify/text_migration.jl` | exact equality |
| `[^52]` (timeline) | TEXT migration (Figure 6): 2024 distribution events 10 / 9 / 9 / 4 PRNs on Mar 18 / Mar 25 / Jul 31 / Oct 10; sustained daily bursts PRN 1 (17 d, distinct payload/day), PRN 21 (17 + 10 d), PRN 20 (5 d) | `verify/text_timeline.jl` | exact |

The v1 body's May-2011 section quoted a second rotation-rate set under a different metric (per-message duration); the v2 article standardises on the chart metric throughout and cites the duration metric only for the 23-hour operational-era median (footnote `[^41]`, report row below).

## Claims with external citations (no DB verifier needed)

These are sourced to primary documents; run the cited link, not a script.

| Footnote | Claim | Source |
|---|---|---|
| `[^1]` | IS-GPS-200 reserves SF4 P17 for special messages | IS-GPS-200N §20.3.3.5.1.8, p. 122 |
| `[^4]` | L1 C/A 50 bps; 1500-bit frame; 5 × 300-bit subframes | IS-GPS-200N §20.3.1, §20.3.2 |
| `[^5]` | Page 17 visible every 12.5 minutes | IS-GPS-200N §20.3.2 (`25 frames × 30 s`) |
| `[^9]` | (32, 26) Hamming parity code | IS-GPS-200N §20.3.5.1, Table 20-XIV |
| `[^12]` | 45-symbol alphabet | IS-GPS-200N §20.3.3.5.1.8 |
| `[^10]` | source data: GFZ Potsdam ISDC navigation-bit archive, 2007–present | upstream DOI <https://doi.org/10.1594/GFZ.ISDC.GNSS/GNSS-GPS-1-NAVBIT>; frozen mirror per [DATA.md](DATA.md) |
| `[^23]` | PRN 25 Block IIA decommissioned Dec 2009; first IIF May 2010 (same PRN slot) | <https://en.wikipedia.org/wiki/List_of_GPS_satellites> |
| `[^31]`, `[^36]`, `[^38]` | OTAD/OTAR mechanism, mission constellations, March 2011 operational start, "next black key", DAGR | Tyley 2015 briefing (see [DATA.md](DATA.md)) |
| `[^55]` | September 2020 SVN 74 / PRN 04 anomaly; ADS-B effects | Walter et al. 2021 (see [DATA.md](DATA.md)) |
| `[^53]` | IS-GPS-200 specifies envelope only, not type-identifier protocol | IS-GPS-200N §20.3.3.5.1.8 |
| `[^27]` | Anti-Spoofing activated early 1994; Y-code = encrypted P-code on L1/L2 | Y-code relationship: <https://en.wikipedia.org/wiki/GPS_signals>. The widely cited 31 January 1994 date is not yet confirmed from a primary source (GPS.gov / NAVCEN); the v2 body says "early 1994" |
| `[^28]` | M-code introduced with the Block IIR-M satellites from 2005 (first IIR-M launch 2005-09-26) | <https://en.wikipedia.org/wiki/GPS_Block_IIR-M> |
| `[^42]` | M-Code operates on L1/L2 on modernized (GPS III) satellites — the factual basis for the speculative reading that the 2022 reversion migrated OTAD traffic off L1 C/A; the OCX/policy/M-code attribution itself is unfootnoted authorial speculation, flagged inconclusive in the body | <https://en.wikipedia.org/wiki/GPS_Block_III#Military_(M-code)> |
| `[^29]` | SAASM mandated for newly fielded U.S. military receivers from October 2006; AN/PSN-13 DAGR | <https://en.wikipedia.org/wiki/Selective_availability_anti-spoofing_module>, <https://en.wikipedia.org/wiki/Defense_Advanced_GPS_Receiver> |
| `[^30]` | pre-OTAD key distribution: physical key-fill devices and NSA courier logistics | <https://en.wikipedia.org/wiki/AN/CYZ-10> (Data Transfer Device), <https://en.wikipedia.org/wiki/AN/PYQ-10> (Simple Key Loader) |
## Claims derivable from cited material (math only; not separately verified)

| Footnote | Claim | Derivation |
|---|---|---|
| `[^6]` | ~3,700 special-message payloads per day fleet-wide | 32 satellites × (24 × 60 / 12.5 min/visibility) ≈ 3,686 |
| `[^7]` | special message ≈ 12% of every full LNAV frame | 176 / 1500 = 11.7% (v1 said "of every Subframe 4 broadcast" — wrong denominator, fixed in v2) |
| `[^21]` | 0xAA = `0b10101010` | mathematical identity |
| `[^49]` | Probability of a 9-char match by chance ≈ 1 / 45⁹ ≈ 1.3 × 10⁻¹⁵ per pair; corpus-level expectation 3.25 × 10⁻⁶ vs 4 observed | 45⁻⁹ direct; `analysis/reports/statistical_significance.md` §Test 1 |

## Claims supported by automatically-generated reports (not yet wrapped in verifiers)

These are computed by `analysis/run_all.sh` and committed under `analysis/reports/`. A future verifier could wrap each as a one-liner SQL check; for now the published report is the artefact.

| Footnote | Claim | Report |
|---|---|---|
| `[^14]` | PPM-D order-8 marginal entropy: μ = 132.78 bits, σ = 7.50, median 133.00, min 96.56, max 416.70 | `analysis/reports/marginal_entropy_ppm.md` §1 |
| `[^15]` | GPS vs random baseline: means 132.78 vs 133.57 bits; KS D = 0.068 (p ≈ 2 × 10⁻²⁰) but Cohen's d ≈ −0.13 (negligible) | `analysis/reports/statistical_significance.md` §Test 5 |
| `[^17]` | 3 zero-entropy (all-same-byte) messages in the corpus | `analysis/reports/statistical_significance.md` §Test 4; observation windows in `analysis/reports/sentinel_nanu.md` §2 |
| `[^18]` | three sentinel byte values: 0x20 (space), 0x00 (NUL), 0xAA (¬), with corpus totals 1,025 / 3,844 / 19,377 | `analysis/reports/statistical_significance.md` §Test 4. (¬'s on-air CP437 byte is 0xAA; 0xAC is its Unicode codepoint U+00AC, not the broadcast byte.) |
| `[^20]` | all-¬ first appears 2010-02-14 on PRN 25; covers all 32 PRNs over 10+ years | `analysis/reports/sentinel_nanu.md` §2 |
| `[^22]` | sentinel-NANU correlation **not** statistically significant (p = 0.8650; 7 lifecycle matches, 3.3% vs 5.0% expected) | `analysis/reports/sentinel_nanu.md` §1 |
| `[^34]` | zero conflicting duplicates among 24.09M observations (multi-receiver agreement; no geographic targeting) | `analysis/reports/duplicates_audit.md` |
| `[^37]` | H1 2011 cascade: coordinated change points span January–May 2011 densely, opening with the 32-PRN sentinel onset of Jan 11–13 (v1 described four discrete months) | `analysis/reports/otad_hypothesis.md` §"Detailed H1 2011 change points" |
| `[^39]` | CUSUM change-point parameters: slack k = 0.5, threshold h = 5.0, reference period = first 20% of valid observations; coordination = ≥8 PRNs within ±3 days | `analysis/reports/behavioral_changes.md` (parameters block at end) |
| `[^40]` (full) | May 2022 reversion: 8–25 PRNs depending on metric (2022-05-23 / 2022-05-30), no NANU within correlation window (v1 said 17–32 PRNs) | `analysis/reports/behavioral_changes.md` §2; `analysis/reports/nanu_correlation.md` §4 |
| `[^41]` (23 h median) | operational-era median per-message lifetime 23.0 h | `analysis/reports/otad_hypothesis.md` §Test 4 |
| `[^43]` | shared substrings identified via the PPM-D order-8 marginal-entropy model; 10 maximal substrings ≥6 chars, 6 pairs ≥7 | `analysis/reports/marginal_entropy_ppm.md` §5; `analysis/reports/statistical_significance.md` §Test 1; implementation `src/ppm_model.jl` |
| `[^54]` | TEXT messages: 4-byte prefix + 18-byte payload, rotating daily (distinct payload every burst day); per-message Shannon entropy 3.53–4.28 bits/byte; population marginal entropy 121.44 vs 132.90 bits (prefix-driven) | `analysis/reports/statistical_significance.md` §§Test 2–3; Shannon range and per-day uniqueness re-derived on v2 by direct DB query 2026-06-12 (v1's 3.66–4.28 range superseded) |
| `[^56]` | staged deployment: PRN 21 alone carries 30 of 122 (PRN, day) combinations (p ≈ 10⁻¹⁸ under uniform assignment) | `analysis/reports/statistical_significance.md` §Test 2 |

## Interpretive / authorial claims (no verifier; flagged in the article)

| Footnote | Nature |
|---|---|
| `[^3]` | OTAD as the field's purpose — interpretive; only Test 4 of `analysis/reports/otad_hypothesis.md` is STRONG |
| `[^8]` | extraction layout — implementation, `src/lnav_decoder.jl` |
| `[^11]` | pipeline performance characterization |
| `[^16]` | "no readable English 2007–2023" — qualitative reading of the entropy/alphabet results |
| `[^19]` | CP437 0xAA = ¬ mapping — implementation, `src/ascii_decoder.jl` |
| `[^35]` | "no NANU announces the fleet-wide event" — precise wording note |
| `[^50]` (key size) | the key-size/header *split* is an informed inference, not sourced (the briefing names the mechanism, never a key length); the underlying capacity is now verified by `verify/field_capacity.jl` (see the row above) |
| `[^51]` | monitoring/fingerprinting capability — interpretation, anchored to the fixed-offset matches (`verify/shared_substrings.jl`) and tempered by the null sentinel-NANU test ([^22]) |
