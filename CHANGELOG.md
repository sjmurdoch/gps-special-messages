# Changelog

This file records the corrections between version 1 of this repository and dataset (accompanying Murdoch, "The Empty Field That Wasn't: GPS, OTAD, and Two Decades of Encrypted Broadcasts", *Inside GNSS*, May/June 2026) and version 2. Version 1 numbers remain reproducible from the archived v1 Zenodo artefacts (see [Dataset versions](#dataset-versions) below); a from-raw rebuild with the current code intentionally does **not** reproduce them, because the decoder bug they reflect is fixed.

## v2.0 — 2026-06-24

### The D30* page-identification bug

The v1 decoder silently skipped every special message in NAVBIT streams that retain on-air D30* parity complementing — roughly half of all observations. In the GPS LNAV format, when the last parity bit (D30) of the preceding word is 1, the data bits of the next word are transmitted complemented. In affected streams the v1 decoder's time-of-week consistency check misread this complementing as whole-frame inversion, under which Subframe 4 Page 17's identifying SV ID of 55 reads as its 6-bit complement, 8 — so the page was never identified and its message never extracted. The bug did not corrupt any extracted message; it excluded whole streams, so the v1 corpus was a roughly half-sized, station-biased sample of the true broadcast record.

Fixed by parity-verified recovery of D30*-complemented Page 17 frames, with subsequent identification hardening: a week-rollover TOW wrap; confirmation of both SV ID 55 and aliased SV ID 8 readings under the parity-verified stream interpretation; and a TLM-preamble gate on parity-unverifiable frames, stored with `parity_ok = FALSE`.

Rebuilding the database from the unchanged raw GFZ archive with the fixed decoder yields **24,087,691 observations of 5,009 unique messages** (v1: 12,163,006 of 3,994). The raw `navbits` and `nanu` Zenodo artefacts are unaffected — the bug was entirely downstream of the raw archive — so only the derived `messages.duckdb` artefact changes in v2.

### Corrected numbers (v1 → v2)

All v1 values below appeared in the published article (see CLAIMS.md for the claim-by-claim mapping to verifiers); v2 values are derived from the corrected corpus.

| Quantity | v1 (published) | v2 (corrected) |
|---|---|---|
| Total observations | 12,163,006 | 24,087,691 |
| Unique messages | 3,994 | 5,009 |
| Date range / PRN count | 2007-06-19 → 2026-01-23, 32 PRNs | unchanged |
| χ² z-score vs the 45-symbol alphabet (df = 44) | 1.84 | 1.598 |
| Rotation rate, 2007–2010 pre-OTAD era (days/message) | 3.7 | 2.50 |
| Rotation rate, 2012–2021 operational era (days/message) | 1.8 | 0.96 |
| Rotation rate, 2022+ modern era (days/message) | 4.3 | 2.31 |
| TEXT migration: unique messages / (PRN, day) combinations / observations | 26 / 38 / 2,398 | 55 / 122 / 8,248 |
| Marginal entropy of unique messages, μ / σ (bits) | 131.51 / 7.56 | 132.78 / 7.50 |
| Sentinel–NANU correlation, one-sided p | 0.4360 (not significant) | 0.8650 (still not significant) |
| Messages observed in more than two calendar months | 2 | 1 (the all-¬ sentinel) |
| Shared substrings of ≥7 characters | 5 pairs | 6 pairs |
| Identical-duplicate `(datetime, prn, hash)` keys in the build | 17,004 | 19,832 |

The May 2022 coordinated change point survives (2022-05-30, 25 PRNs), as does the first-half-2011 activation cascade (denser in the corrected data: it now spans January–May rather than four discrete months).

### Withdrawn claims

Three minor v1 statements are retracted rather than numerically corrected:

- **"The post-2022 era rotates more slowly than the pre-2011 era."** Falsified by the corrected data: 2.31 vs 2.50 days/message — statistically indistinguishable, and slightly *faster* if anything. The surviving qualitative claim, now asserted by `verify/rotation_regimes.jl`, is that the operational OTAD era (2012–2021) rotates more than twice as fast as both outer eras.
- **The "rare message" anomaly class (messages with ≤5 observations).** An artifact of the half-sized v1 corpus: most v1 "rare" messages gained observations once the D30*-skipped streams were recovered. The handful of genuinely rare uniques remaining in v2 are explained — parity-verified midnight-rotation transients or coverage-edge artifacts, not an unexplained message class.
- **The "tentative single-satellite TEXT trial" reading.** The TEXT-prefix format launched fleet-wide on 12–13 December 2023; the single-satellite framing was an artifact of the biased sample.

### Figure 5 (shared substrings): label corrections and new groups

Two v1 label errors are independent of the D30* bug: Group A's label said 8 shared characters where the aligned count is 9 (`:U'5PSF8T`), and Group C said 7 + 4 where the aligned count is 9 + 4 (`ZU°SGZ8PJ` plus `:IM `). The v2 figure also adds two groups: **Group E** (`HG"2'CA`, 7 characters, 2014-08-28 / 2014-11-26) — the only genuinely new pair in the corrected corpus; the 2014-08-28 partner message was wholly absent from v1 because its streams were D30*-skipped — and **Group F** (`S°6L.D°`, 7 characters plus one incidental aligned `M` at byte 11), which was verified in v1 but never plotted. Group letters A–D keep their v1 assignments so cross-references survive; E and F are the only new names.

### Newly visible findings in the corrected corpus

Previously invisible or mis-framed in the half-sized v1 sample (each now pinned by its own verifier):

- A fleet-wide sentinel onset on 11–13 January 2011 (all 32 PRNs entered all-¬ on 2011-01-11 and exited on 2011-01-13; first-ever all-¬ for 28 of them), reframing the 26 May 2011 flash as the culmination of a phased January–May activation. Verifier: `verify/sentinel_onset_2011.jl`.
- A fleet-wide sentinel event on 22 July 2020 (29 PRNs, 1,438 observations, all on that single day — the last sentinel observation in the corpus). Verifier: `verify/sentinel_event_2020.jl`.
- The fleet-wide TEXT inception of 12–13 December 2023 (9 PRNs, then all 32; see the withdrawn single-satellite reading above). Verifier: `verify/text_inception_2023.jl`.
- The calendar-month replacement claim (only the all-¬ sentinel spans more than two calendar months on any PRN), previously cited to a report that never contained it, now has a verifier: `verify/calendar_months.jl`.

### Field capacity (key-size bound)

The v2 article adds a capacity argument absent from v1. The Page 17 field is physically 176 data bits (22 × 8), but the payloads are confined to the 45-symbol alphabet IS-GPS-200 specifies — across the unique corpus the only out-of-alphabet bytes are the two degenerate sentinels (all-`0x00` and all-`0xAA`). A format-preserving cipher over 45 symbols carries only 22·log₂45 ≈ 120.8 usable bits, so a 128-bit key — which would need 24 symbols — does not fit the field. Verifier: `verify/field_capacity.jl`.

### Article v2

The corrected article is now a tracked artifact at `article/the-empty-field-that-wasnt.md`. It presents itself as a new version of the original *Inside GNSS* article and is published via GitHub Pages, built from that Markdown source by `article/build.sh`. The printed *Inside GNSS* article carried no footnotes; this web version adds them, every quantitative claim mapped to a verifier or source in CLAIMS.md. The build renders a standalone page with margin sidenotes (`sidenotes.js`, `style.css`, `template.html`), de-duplicates reused footnote references (`footnotes.lua`), rewrites cross-references (`links.lua`), and is validated by `article/check_footnotes.sh`; `.github/workflows/pages.yml` deploys it on push.

### Repository changes since v1.0

- **Decoder** — recover Page 17 frames in D30*-complemented streams (+ regression tests); fix TOW wraparound at the week rollover; remove a dead word-1 read; identify Page 17 under the parity-verified stream interpretation; gate parity-unverifiable identifications on the TLM preamble; add a stream-state round-trip test matrix.
- **Schema** — add a `parity_ok` column to `special_messages`; present only in databases rebuilt with the fixed decoder.
- **Analysis** — OTAD-report summary values computed from the data instead of hard-coded; all reports regenerated against the corrected corpus.
- **Figures** — v1-corpus artifacts fixed in figures 2–6 and all outputs regenerated; Figure 5 label corrections and Groups E/F (six pairs).
- **Verifiers** — the suite grew to **fourteen** claim-level verifiers. Seven are new in v2: `sentinel_onset_2011`, `sentinel_event_2020`, `text_inception_2023`, `calendar_months`, `field_capacity`, `message_diversity` (per-year unique-message diversity: 50–114 distinct payloads/year pre-operational, 368–404/year operational), and `text_timeline` (the post-inception TEXT migration in Figure 6 — four multi-PRN one-day events through 2024, then single-PRN daily bursts migrating PRN 1 → 21 → 20). The shared-substrings verifier gained the recovered Group E pair; the diverged v1 verifiers (`corpus_totals`, `chi_squared`, `rotation_regimes`, `fleet_flash_2011`, `text_migration`) were re-pinned to the corrected corpus; and `prn25_timeline` carried over unchanged. All fourteen pass against a rebuilt database; they fail against the v1 Zenodo database until the v2 upload.
- **Docs** — README, REPRODUCING.md, DATA.md, and CITATION.cff (now 2.0.0) re-pinned to the v2 artefact under the concept-DOI strategy, along with the `bin/fetch_zenodo.sh` manifest; transitional-state and identification documentation added to CLAUDE.md.
- **Build & reproducibility** — analysis scripts honor `REPORTS_DIR` and stamp UTC report headers so a full build stays hermetic; `behavioral_changes` report sorts are total-ordered for run-to-run reproducibility; `bin/full_build.sh` records the measured ~19.4 h end-to-end wall time.

### Dataset versions

The Zenodo concept DOI <https://doi.org/10.5281/zenodo.20073222> always resolves to the latest version, so it is the only identifier this repository cites. The v1 artefacts remain archived as the deposit's earlier version, so every v1 number stays reproducible from the archived v1 `messages.duckdb` (pin that version via `ZENODO_RECORD_ID`, see `bin/fetch_zenodo.sh`) — but only from that artefact: the fixed decoder cannot regenerate the v1 database from raw. The corrected v2 `messages.duckdb` is uploaded as a new version of the same deposit (the raw `navbits` and `nanu` artefacts are unchanged and not re-uploaded).

## v1.0 — 2026-06-02

Initial public release accompanying the *Inside GNSS* May/June 2026 article: pipeline, analysis, figures, claim-level verifiers, and the Zenodo data deposit.
