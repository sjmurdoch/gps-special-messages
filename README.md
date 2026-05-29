# The Empty Field That Wasn’t: GPS, OTAD and Two Decades of Encrypted Broadcasts

Code, data pipeline, analysis, figures, and claim-level verifiers for **"The Empty Field That Wasn't: GPS, OTAD, and Two Decades of Encrypted Broadcasts"** by Steven J. Murdoch (*Inside GNSS*, May/June 2026).

The 22-byte "special message" field of GPS LNAV Subframe 4, Page 17 has been broadcast on every operational satellite for nineteen years. This repository extracts those messages from the GFZ Potsdam navigation-bit archive, builds a queryable DuckDB database (12,163,006 observations, 3,994 unique payloads, 2007-06-19 → 2026-01-23), and reproduces every quantitative claim and figure in the article.

## Quickstart

Verify the article's claims against the published database (~190 MB download, ~2.8 GB on disk, ~1 minute of compute):

```bash
git clone https://github.com/sjmurdoch/gps-special-messages
cd gps-special-messages
julia --project -e 'using Pkg; Pkg.instantiate()'
bin/fetch_zenodo.sh messages.duckdb        # downloads ~190 MB, decompresses to ~2.8 GB
verify/run_all.sh                          # exits 0 iff every claim reproduces
```

To rebuild the database from raw GFZ + NAVCEN inputs (~hours, ~250 GB intermediate disk), or to rebuild the figures (Typst + CairoMakie), see [REPRODUCING.md](REPRODUCING.md).

## Layout

```
src/        GPSSpecialMessages.jl module: parser, decoder, DB writer, analysis primitives
pipeline/   raw GFZ tars + NAVCEN advisories → data/messages.duckdb (run order: 01..05)
analysis/   DuckDB → markdown reports (behavioral changes, NANU correlation, OTAD test, …)
figures/    DuckDB → six article figures (PNG + PDF)
verify/     DuckDB → claim-level pass/fail checks (one script per CLAIMS.md row)
test/       unit tests (1041 tests when ops_advisories present, 897 without)
data/       arrow_test/ committed; everything else fetched from Zenodo
```

## Citing this work

Cite the article (see [CITATION.cff](CITATION.cff)). The software and dataset are archived at <https://doi.org/10.5281/zenodo.20073222>.

## Further reading

- [REPRODUCING.md](REPRODUCING.md) — full reproduction instructions (fast and full paths)
- [DATA.md](DATA.md) — data sources, provenance, and reference materials
- [CLAIMS.md](CLAIMS.md) — every quantitative claim mapped to its verifier
- [LICENSE](LICENSE) — Apache 2.0
