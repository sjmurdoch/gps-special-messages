#!/usr/bin/env bash
# Build the article web page from the Markdown source.
#
# Output: article/site/ — a self-contained static page (index.html,
# style.css, sidenotes.js, figures/) ready for GitHub Pages. The same
# script runs locally and in .github/workflows/pages.yml.
#
# Requires: pandoc ≥ 3 (with Lua filter support).
#
# Usage:
#   article/build.sh

set -euo pipefail
cd "$(dirname "$0")"

SITE="site"
SRC="the-empty-field-that-wasnt.md"
TITLE="The Empty Field That Wasn't: GPS, OTAD and Two Decades of Encrypted Broadcasts"

command -v pandoc >/dev/null || { echo "Error: pandoc not found" >&2; exit 2; }

rm -rf "$SITE"
mkdir -p "$SITE/figures"

# Stage the figures the article embeds (links.lua rewrites the srcs).
for fig in lnav_schematic entropy_distribution fleet_flash_2011 \
           rotation_rate shared_substrings text_migration; do
    cp "../figures/output/$fig.png" "$SITE/figures/"
done

pandoc "$SRC" \
    --from markdown+footnotes+smart \
    --to html5 \
    --template template.html \
    --lua-filter links.lua \
    --lua-filter footnotes.lua \
    --metadata pagetitle="$TITLE" \
    --output "$SITE/index.html"

cp style.css sidenotes.js "$SITE/"

echo "Built $SITE/index.html ($(wc -c < "$SITE/index.html" | tr -d ' ') bytes)"
