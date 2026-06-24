#!/usr/bin/env bash
# Build the article as an attractive, footnote-preserving PDF.
#
# Output: article/the-empty-field-that-wasnt.pdf — bottom-of-page footnotes
# with clickable, bidirectional hyperlinks (hyperref); figures embedded from
# ../figures/output/; STIX Two Text body + sans headings.
#
# Pipeline: pandoc (Markdown -> LaTeX) | xelatex, driven by four Lua filters
# (see links-pdf.lua, pdf-sup.lua, pdf-frontmatter.lua, pdf-footnotes.lua)
# and pdf-header.tex. Runs from the article/ directory so the source's
# ../figures/output/*.png paths resolve for embedding.
#
# Requires: pandoc >= 3, xelatex (MacTeX/TeX Live), STIX Two Text font.
#
# Usage:
#   article/build-pdf.sh                       # writes beside the source
#   article/build-pdf.sh /path/to/out.pdf      # explicit output path
#   ARTICLE_PDF=/path/to/out.pdf article/build-pdf.sh   # same, via env

set -euo pipefail
cd "$(dirname "$0")"
ART_DIR="$PWD"

SRC="the-empty-field-that-wasnt.md"
# Output path, in precedence order: CLI arg, then $ARTICLE_PDF, then beside the
# source. bin/full_build.sh points $ARTICLE_PDF at its work dir so an
# unattended build never writes into the tracked tree.
OUT="${1:-${ARTICLE_PDF:-$ART_DIR/the-empty-field-that-wasnt.pdf}}"
mkdir -p "$(dirname "$OUT")"
TITLE="The Empty Field That Wasn't: GPS, OTAD and Two Decades of Encrypted Broadcasts"
SUBTITLE="What 24 million GPS special messages reveal about military rekeying on a public channel"
AUTHOR="Steven J. Murdoch · University College London"
DATE="Version 2 · June 2026"

command -v pandoc  >/dev/null || { echo "Error: pandoc not found"  >&2; exit 2; }
command -v xelatex >/dev/null || { echo "Error: xelatex not found" >&2; exit 2; }

pandoc "$SRC" \
    --from markdown+footnotes+smart \
    --pdf-engine=xelatex \
    --lua-filter links-pdf.lua \
    --lua-filter pdf-sup.lua \
    --lua-filter pdf-frontmatter.lua \
    --lua-filter pdf-footnotes.lua \
    --include-in-header pdf-header.tex \
    --metadata title="$TITLE" \
    --metadata subtitle="$SUBTITLE" \
    --metadata author="$AUTHOR" \
    --metadata date="$DATE" \
    -V documentclass=article \
    -V fontsize=11pt \
    -V geometry:a4paper \
    -V geometry:left=2.6cm -V geometry:right=2.6cm \
    -V geometry:top=2.4cm  -V geometry:bottom=2.6cm \
    -V mainfont="STIX Two Text" \
    -V sansfont="Helvetica Neue" \
    -V monofont="Menlo" \
    -V monofontoptions="Scale=0.84" \
    -V linestretch=1.08 \
    -V colorlinks=true \
    -V linkcolor=linkblue \
    -V urlcolor=linkblue \
    -V citecolor=linkblue \
    -V toccolor=linkblue \
    --output "$OUT"

echo "Built $OUT ($(wc -c < "$OUT" | tr -d ' ') bytes)"
