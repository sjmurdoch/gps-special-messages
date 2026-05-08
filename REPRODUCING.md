# Reproducing the article

Two paths through the repository, depending on what you want to reproduce.

- **Fast path** — verify every quantitative claim against the published database. ~1.5 GB download, ~1 minute of compute.
- **Full path** — rebuild the database from raw GFZ + NAVCEN archives, then verify. ~7 GB download, ~250 GB intermediate disk, hours of compute.

Both paths end with `verify/run_all.sh` exiting 0.

## Prerequisites

| Tool | Purpose | Tested with |
|---|---|---|
| Julia ≥ 1.10 | runtime for everything under `src/`, `pipeline/`, `analysis/`, `figures/`, `verify/` | 1.12.5 (via [juliaup](https://julialang.org/downloads/)) |
| Typst | rendering Figures 1 and 5 | 0.14.2 |
| `curl`, `tar`, `zstd`, `shasum` | `bin/fetch_zenodo.sh` artefact downloads | macOS / Linux defaults |
| `sips` (macOS) | optional — fixes PNG DPI metadata for Typst figures | macOS only |

Install Julia dependencies once:

```bash
julia --project -e 'using Pkg; Pkg.instantiate()'
```

`Manifest.toml` is committed — `Pkg.instantiate()` resolves to the exact dependency versions used to write the article.

## Fast path

```bash
git clone https://github.com/sjmurdoch/gps-special-messages
cd gps-special-messages
julia --project -e 'using Pkg; Pkg.instantiate()'

# Download the pre-built DuckDB from Zenodo (~1.5 GB compressed → ~3 GB decompressed).
# bin/fetch_zenodo.sh verifies SHA-256 against the manifest in DATA.md.
bin/fetch_zenodo.sh messages.duckdb

# Run all 7 claim-level verifiers.
verify/run_all.sh
```

Expected output (last lines):

```
Verifier summary: 7 / 7 passed
All verifiers passed.
```

Optional: rebuild the six article figures from `data/messages.duckdb` and the entropy-analysis output:

```bash
analysis/marginal_entropy_ppm.jl    # writes analysis/reports/marginal_entropy_ppm.md (~5 minutes)
figures/build_all.sh                # writes figures/output/{lnav_schematic,…}.{png,pdf,svg}
```

PNGs are 300 dpi; visually compare against the committed copies in `figures/output/` — Typst PDFs differ only in embedded timestamps; CairoMakie outputs vary by tens of bytes between runs (Cairo writes timestamps + font-cache ordering into the stream).

## Full path

A complete rebuild from raw GFZ navigation bits and NAVCEN Operational Advisories. The manual stage-by-stage sequence is shown first; for a one-command unattended run that captures progress markers and resumes from the last failed stage, see [Unattended rebuild with `bin/full_build.sh`](#unattended-rebuild-with-binfull_buildsh) below.

```bash
git clone https://github.com/sjmurdoch/gps-special-messages
cd gps-special-messages
julia --project -e 'using Pkg; Pkg.instantiate()'

# Step 0 — download raw archives from Zenodo (~7 GB total).
bin/fetch_zenodo.sh navbits      # → data/raw/   (~7.1 GB GFZ tars)
bin/fetch_zenodo.sh nanu         # → data/ops_advisories/   (~32 MB NAVCEN .oa1)

# Step 1–5 — raw → DuckDB.  Each script prints a checkpoint line on completion.
pipeline/run_all.sh

# Sanity check the rebuilt DB before running analyses against it:
julia --project -e '
using DuckDB
db = DuckDB.DB("data/messages.duckdb"; readonly=true)
n  = (DBInterface.execute(db, "SELECT COUNT(*) AS n FROM special_messages") |> first).n
@assert n == 12_163_006 "expected 12,163,006 rows; got $n"
println("OK: ", n, " rows")'

# Step 6 — populate analysis tables and write reports.
analysis/run_all.sh

# Step 7 — rebuild figures.
figures/build_all.sh

# Step 8 — verify every quantitative claim.
verify/run_all.sh
```

`pipeline/run_all.sh` runs five stages sequentially:

| Stage | Reads | Writes | Notes |
|---|---|---|---|
| `01_download_navbits` | (URLs) | `data/raw/` | skip if `bin/fetch_zenodo.sh navbits` already populated `data/raw/` |
| `02_decompress` | `data/raw/` | `data/processed/` (~136 GB intermediate NetCDF) | |
| `03_convert_to_arrow` | `data/processed/` | `data/arrow/` (~31 GB) | uses all CPU cores via `julia -t auto` |
| `04_build_database` | `data/arrow/` | `data/messages.duckdb` (~3 GB) | extracts SF4 P17, writes 11 tables |
| `05_download_ops_advisories` | (URLs) | `data/ops_advisories/` | skip if `bin/fetch_zenodo.sh nanu` already ran |

`analysis/run_all.sh` is idempotent — its first step deletes the analysis-table contents in foreign-key-safe order, then repopulates. Re-running against an already-populated `messages.duckdb` works.

### Unattended rebuild with `bin/full_build.sh`

`bin/full_build.sh` runs all seven stages of the full path (extract navbits → extract NANU → decompress → arrow → db → analysis → verify) end-to-end with one command, in a hermetic work directory outside the repo. It is resumable across restarts, writes per-stage markers and logs, and is the wrapper the migration plan's full-path gate was validated against on the production corpus (~11h 20m wall, 12,163,006 rows / 3,994 unique / 7-of-7 verifiers).

**Prerequisite — stage the raw archives.** Download both files from the [Zenodo deposit](https://doi.org/10.5281/zenodo.20073222) into `$ARCHIVE_DIR` (default: a sibling directory `../gps-special-messages-release/` next to the repo) under their original filenames:

- `gps-navbits-2026-01-26.tar.xz`
- `nanu-archive-2026-02-26.tar.xz`

`bin/fetch_zenodo.sh` is *not* a substitute here: it streams the archive into the repo's `data/` and discards the tarball, whereas `full_build.sh` re-extracts the archive into its own work directory.

**Run it:**

```bash
nohup bin/full_build.sh > /dev/null 2>&1 &       # fire-and-forget, ~hours
echo "$!" > /tmp/full_build.pid
```

**Other modes:**

```bash
bin/full_build.sh --dry-run      # validate prereqs, print the plan, do nothing
bin/full_build.sh --smoke        # tiny end-to-end on data/arrow_test fixtures (~1 min)
bin/full_build.sh --restart      # wipe markers + work dir; rebuild from scratch
```

**While it is running:**

```bash
cat ../gps-special-messages-fullbuild/_build/STATUS.md      # current stage table
tail -f ../gps-special-messages-fullbuild/_build/full.log   # live timestamped log
kill -0 $(cat /tmp/full_build.pid)                          # process alive check
```

**When it finishes**, `_build/RESULTS.md` summarises stage outcomes and the headline invariants. Per-stage logs are at `_build/logs/<id>.log`; per-stage markers (with measured invariants such as row counts) at `_build/markers/<id>.done`. Re-running after a failure skips stages whose markers already exist — only the failing stage and onwards re-execute.

**Environment overrides:**

| Variable | Default | Purpose |
|---|---|---|
| `WORK_DIR` | `../gps-special-messages-fullbuild` | hermetic work directory; intermediate data + logs land here |
| `ARCHIVE_DIR` | `../gps-special-messages-release` | where the two staged archives live |
| `REPO_DIR` | dirname of this script's parent | target repo root |
| `JULIA` | `julia` on `$PATH` | override the Julia binary |
| `THREADS` | `auto` | passed to `julia -t` |
| `OA_SOURCE_DIR` | `../gps-message/data/ops_advisories` | symlink target for ops_advisories in `--smoke` mode |

## Disk footprint

| Path | Full path | Fast path |
|---|---|---|
| `data/raw/` | ~7.1 GB | — |
| `data/processed/` | ~136 GB | — |
| `data/arrow/` | ~31 GB | — |
| `data/ops_advisories/` | ~32 MB | optional |
| `data/messages.duckdb` | ~3 GB | ~3 GB |
| `~/.julia/` (deps) | ~3 GB | ~3 GB |
| `figures/output/` (committed) | ~3 MB | ~3 MB |
| Total | ~180 GB | ~6 GB |

The intermediate `data/processed/` and `data/arrow/` directories can be deleted after `pipeline/04_build_database.jl` produces `data/messages.duckdb`.

## Troubleshooting

**Pipeline 04 takes much longer than expected**: by default `pipeline/run_all.sh` sets `THREADS=auto`. The DuckDB write step is single-threaded by design (writes are serialised after a parallel collect); if 04 looks single-threaded, that is the write phase, not a regression.

**Linux: figures' PNG DPI is wrong**: `figures/build_all.sh` uses `sips` (macOS) to fix PNG `pHYs` metadata for Typst-rendered images. The script guards `sips` with `command -v sips`, so on Linux Typst PNGs ship at typst's default of 72 dpi in their metadata even though the raster is rendered at the requested DPI. Affects `lnav_schematic.png` and `shared_substrings.png` only. The PDFs are unaffected.
