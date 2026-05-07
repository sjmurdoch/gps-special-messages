#!/usr/bin/env bash
# Re-generate the six article figures (PNG + PDF + SVG) from data/messages.duckdb
# and the PPM-D entropy text output produced by analysis/marginal_entropy_ppm.jl.
#
# Julia (CairoMakie) plots: PNG_PX_PER_UNIT = DPI/96 → matching dpi metadata.
# Typst plots: --ppi DPI; sips fixes the pHYs chunk afterwards.
#
# Usage:
#   figures/build_all.sh                # 300 dpi against default paths
#   figures/build_all.sh 600            # custom dpi
#
# Environment:
#   JULIA   override julia binary (default: `julia` on PATH)
#   DB      override DB path (default: data/messages.duckdb)
#   PPM     override PPM report input (default: analysis/reports/marginal_entropy_ppm.md)

set -euo pipefail

DPI="${1:-300}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

JULIA="${JULIA:-julia}"
if ! command -v "$JULIA" >/dev/null 2>&1; then
    if [[ -x "$HOME/.juliaup/bin/julia" ]]; then
        JULIA="$HOME/.juliaup/bin/julia"
    else
        echo "julia not found on PATH" >&2; exit 1
    fi
fi
command -v typst >/dev/null || { echo "typst not found" >&2; exit 1; }

DB="${DB:-data/messages.duckdb}"
PPM="${PPM:-analysis/reports/marginal_entropy_ppm.md}"
[[ -f "$DB" ]]  || { echo "missing $DB" >&2; exit 1; }
[[ -f "$PPM" ]] || { echo "missing $PPM" >&2; exit 1; }

OUT_DIR="figures/output"
mkdir -p "$OUT_DIR"

# Makie size= is in 96 dpi logical units; px_per_unit = DPI/96 yields the
# requested DPI in the saved PNG's pHYs chunk.
export PNG_PX_PER_UNIT
PNG_PX_PER_UNIT="$(awk -v d="$DPI" 'BEGIN{printf "%.6f", d/96.0}')"

run_julia() {
    local script="$1"; shift
    echo "==> $script" >&2
    HIGHLIGHT_TEXT=0 "$JULIA" --project "$script" "$@"
}

run_julia figures/fig2_entropy_distribution.jl "$PPM" "$DB"
run_julia figures/fig3_fleet_flash.jl          "$DB"
run_julia figures/fig4_rotation_rate.jl        "$DB"
run_julia figures/fig6_text_migration.jl       "$DB"

# Typst rasterises at the requested ppi but writes 72 dpi into the PNG pHYs
# chunk; sips (macOS) fixes the metadata so layout tools place the image at
# the intended physical size.
typst_png() {
    local src="$1" dst_png="$2"
    local dst_pdf="${dst_png%.png}.pdf"
    local dst_svg="${dst_png%.png}.svg"
    echo "==> $src" >&2
    typst compile --format png --ppi "$DPI" "$src" "$dst_png"
    typst compile --format pdf "$src" "$dst_pdf"
    typst compile --format svg "$src" "$dst_svg"
    if command -v sips >/dev/null; then
        sips -s dpiHeight "$DPI" -s dpiWidth "$DPI" "$dst_png" >/dev/null
    fi
}

typst_png figures/fig1_lnav_schematic.typ    "$OUT_DIR/lnav_schematic.png"
typst_png figures/fig5_shared_substrings.typ "$OUT_DIR/shared_substrings.png"

echo
echo "Done. DPI metadata of generated PNGs:"
for f in lnav_schematic entropy_distribution fleet_flash_2011 rotation_rate \
         shared_substrings text_migration; do
    if command -v sips >/dev/null && [[ -f "$OUT_DIR/$f.png" ]]; then
        sips -g dpiWidth -g pixelWidth -g pixelHeight "$OUT_DIR/$f.png" 2>/dev/null | \
            awk -v n="$f" 'NR==1{next} {printf "  %-22s %s\n", n, $0; n=""}'
    fi
done
