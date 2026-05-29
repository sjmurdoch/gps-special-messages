# Data sources and reference materials

This repository's pipeline consumes two upstream archives plus produces a derived database. All three artefacts are mirrored on a single Zenodo deposit so they share one DOI and citation. Reference materials cited by the article (the article PDF itself, ICDs, briefings) are linked rather than redistributed.

## 1. Pipeline inputs (consumed by `pipeline/`)

All three artefacts live on the project's Zenodo deposit:

**Zenodo deposit DOI: <https://doi.org/10.5281/zenodo.20073222>**

The release source tarball is auto-archived by GitHub→Zenodo when a release tag is pushed. The three large data artefacts below are uploaded manually to the same deposit so they share one DOI.

`bin/fetch_zenodo.sh` knows about all three artefacts and verifies SHA-256 against the manifest embedded in that script.

### `gps-navbits-2026-01-26.tar.xz`

Frozen GFZ navbit snapshot (~7.1 GB) consumed by `pipeline/02_decompress.jl`.

| Field | Value |
|---|---|
| Filename on Zenodo | `gps-navbits-2026-01-26.tar.xz` |
| Snapshot date | 2026-01-26 |
| Compressed size | 7.1 GB (7,585,585,232 bytes) |
| SHA-256 | `0b41c9cad323b6f55e497eb4555af42b24e621723347690531f302297992f25c` |
| Tar files | 6,786 daily tars (one per `(year, day-of-year)`) |
| Year range | 2007 (from day 170) — 2026 (to day 023) |
| Upstream DOI | <https://doi.org/10.1594/GFZ.ISDC.GNSS/GNSS-GPS-1-NAVBIT> (cite as primary source) |

The Zenodo copy is a frozen mirror for reproducibility; cite the GFZ DOI for the original archive and the Zenodo deposit for the snapshot used in this analysis.

### `nanu-archive-2026-02-26.tar.xz`

NAVCEN GPS Operational Advisory `.oa1` snapshot (~165 KB compressed → ~32 MB extracted) consumed by `analysis/nanu_correlation.jl` and `analysis/sentinel_nanu.jl`. Optional input to `pipeline/05_download_ops_advisories.jl` (which can also fetch live from NAVCEN if you want the most recent records).

| Field | Value |
|---|---|
| Filename on Zenodo | `nanu-archive-2026-02-26.tar.xz` |
| Snapshot date | 2026-02-26 |
| Compressed size | 165 KB (169,172 bytes) |
| SHA-256 | `58e1816719ea83db4d55ad9154e855c42b3c7bbb614554851dd8fde77de674f8` |
| Files | 6,905 daily `.oa1` snapshots (heavily redundant; xz compresses ~200×) |
| Year range | 2007 — 2026 (last file 2026-02-26) |
| Upstream | <https://www.navcen.uscg.gov/archives/gps/oa> (NAVCEN OA archive) |

### `messages.duckdb.zst`

Fully-built DuckDB (~190 MB compressed → ~2.8 GB decompressed) consumed by `analysis/`, `figures/`, `verify/`. Reproducible from the two upstream archives by running `pipeline/run_all.sh` then `analysis/run_all.sh`.

| Field | Value |
|---|---|
| Filename on Zenodo | `messages.duckdb.zst` |
| Build date | 2026-04-12 |
| Compressed size | 192 MB (201,005,454 bytes); decompresses to 2.8 GB |
| zstd level | 19 (max) |
| SHA-256 (compressed) | `da28b588d7c516479c39822be4820c8658fe9768e20c128ccff132f0346e18a7` |
| Rows in `special_messages` | 12,163,006 |
| Unique message hashes | 3,994 |
| Tables | 11 (`special_messages`, `behavioral_metrics`, `behavioral_change_points`, `change_point_nanu_correlations`, `day_of_week_patterns`, `duplicate_observations`, `identical_duplicates`, `message_durations`, `message_transitions`, `nanu_records`, `sentinel_nanu_correlations`) |
| Built from | `gps-navbits-2026-01-26.tar.xz` SHA-256 `0b41c9cad…` on 2026-04-12 by `pipeline/run_all.sh` |

### Identical-duplicate finding

The build pipeline records 17,004 cases where the same `(datetime, prn, message_hash)` triple appears in more than one source `.arrow` file (tracked in the `identical_duplicates` table). These are not pipeline bugs: the GFZ archive contains both an original and a reprocessed version of some daily files (notably days 91–97 of 2008). Analysis confirmed entire 300-bit subframes are byte-for-byte identical between the two copies. The `analysis/duplicates_audit.jl` script recomputes the headline figure from the DB and writes `analysis/reports/duplicates_audit.md`.

There are **zero** conflicting duplicates (same `(datetime, prn)`, different message content). This is evidence against geographic targeting on the L1 C/A special-message field.

## 2. Reference materials (cited; not redistributed)

The article and the documents it cites are not vendored in this repository. Use the links below.

### The article

Murdoch, S.J. (2026). "The Empty Field That Wasn't: GPS, OTAD, and Two Decades of Encrypted Broadcasts." *Inside GNSS*, May/June 2026 (magazine code `IGM_MJ26_XX-XX_Tech_Subframe`). Publisher page: <https://insidegnss.com/> (TBC at publication).

### Tyley 2015 OTAD briefing

Tyley, S. (2015). "Over-the-Air Distribution (OTAD) Update." Briefing presented at the 2015 GPS Partnership Conference, 29 April 2015. SMC/GPEP. Unclassified, approved for public release.

Wayback snapshot: <https://web.archive.org/web/20250608164932/https://www.gps.gov/multimedia/presentations/2015/04/partnership/tyley.pdf>

### IS-GPS-200 (current revision)

The L1 C/A signal Interface Control Document. The relevant section is §20.3.3.5.1.8 ("Special Messages"). Available from <https://navcen.uscg.gov/gps-technical-references>.

The article cites IS-GPS-200N (01 August 2022).

### ICD-GPS-240 (current revision)

GPS interface control reference for the SAASM/Type-1 user equipment side. The article cites ICD-GPS-240D. Available from the same NAVCEN page; linked rather than redistributed in this repository.

### Walter et al. (2021) — September 2020 SVN 74 anomaly

Walter, T., Liu, Z., Blanch, J., Pham, K., Mick, J., and Wanner, W. (2021). "Investigation into September 2020 GPS SVN 74 Performance Anomaly." *Proceedings of the 2021 International Technical Meeting of The Institute of Navigation* (ION ITM 2021), pp. 671–687. <https://web.stanford.edu/group/scpnt/gpslab/pubs/papers/Walter_ION_ITM_2021_SVN74.pdf>
