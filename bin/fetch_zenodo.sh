#!/usr/bin/env bash
# Fetch the data artefacts from the project's Zenodo deposit and verify SHA-256
# checksums.
#
# DOI: https://doi.org/10.5281/zenodo.20073223
#
# Available artefacts (set in the table below; SHA-256 values are filled in
# at release time and live in DATA.md):
#
#   messages.duckdb     fully-built DuckDB (~1–1.5 GB compressed)
#   navbits             frozen GFZ navbit snapshot (~7 GB)
#   nanu                NAVCEN OA archive (~10–15 MB)
#
# Usage:
#   bin/fetch_zenodo.sh <artefact>
#
#   bin/fetch_zenodo.sh messages.duckdb   # decompresses to data/messages.duckdb
#   bin/fetch_zenodo.sh navbits           # extracts to data/raw/
#   bin/fetch_zenodo.sh nanu              # extracts to data/ops_advisories/
#
# Environment:
#   ZENODO_BASE  override base URL (default: https://zenodo.org/records/20073223/files)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

ZENODO_BASE="${ZENODO_BASE:-https://zenodo.org/records/20073223/files}"

# ── Manifest ────────────────────────────────────────────────────────────────
# Format: name|filename|sha256|destination|extract-cmd
# SHA-256 placeholders are TBD-on-release; populate from DATA.md.
manifest() {
    cat <<'EOF'
messages.duckdb|messages.duckdb.zst|da28b588d7c516479c39822be4820c8658fe9768e20c128ccff132f0346e18a7|data/messages.duckdb|zstd -d -o data/messages.duckdb
navbits|gps-navbits-2026-01-26.tar.xz|0b41c9cad323b6f55e497eb4555af42b24e621723347690531f302297992f25c|data|tar -xJf
nanu|nanu-archive-2026-02-26.tar.xz|58e1816719ea83db4d55ad9154e855c42b3c7bbb614554851dd8fde77de674f8|data|tar -xJf
EOF
}

usage() {
    echo "Usage: bin/fetch_zenodo.sh <artefact>" >&2
    echo "Available artefacts:" >&2
    manifest | awk -F'|' '{printf "  %-18s %s -> %s\n", $1, $2, $4}' >&2
    exit 1
}

[[ $# -eq 1 ]] || usage
target="$1"

row="$(manifest | awk -F'|' -v key="$target" '$1 == key {print; exit}')"
[[ -n "$row" ]] || { echo "Unknown artefact: $target" >&2; usage; }

IFS='|' read -r name file sha256 dest cmd <<< "$row"

mkdir -p "$(dirname "$dest")"
download="$(mktemp -t fetch_zenodo.XXXXXX)"
trap 'rm -f "$download"' EXIT

echo "==> Downloading $file from $ZENODO_BASE/$file" >&2
curl -L --fail -o "$download" "$ZENODO_BASE/$file"

if [[ "$sha256" == "TBD-SHA256" ]]; then
    echo "WARNING: SHA-256 not yet recorded in this script; integrity NOT verified." >&2
    echo "Update bin/fetch_zenodo.sh and DATA.md with the upload checksum." >&2
else
    echo "==> Verifying SHA-256" >&2
    actual="$(shasum -a 256 "$download" | awk '{print $1}')"
    if [[ "$actual" != "$sha256" ]]; then
        echo "SHA-256 mismatch:" >&2
        echo "  expected $sha256" >&2
        echo "  actual   $actual" >&2
        exit 2
    fi
    echo "    ok ($actual)" >&2
fi

echo "==> Extracting to $dest" >&2
case "$cmd" in
    "tar -xJf")
        mkdir -p "$dest"
        tar -xJf "$download" -C "$dest" --strip-components=0
        ;;
    "zstd "*)
        # zstd -d -o <output> <input>
        zstd -d -o "$dest" "$download"
        ;;
    *)
        eval "$cmd $download"
        ;;
esac

echo "==> Done: $dest" >&2
