// LNAV Frame Schematic — where the GPS special message lives
//
// A multi-level zoom showing:
//   Level 1: LNAV frame = 5 subframes, highlight Subframe 4
//   Level 2: Subframe 4 = 25 pages (multiplexed), highlight Page 17
//   Level 3: Page 17 = 10 words, bit extraction from Words 3–10
//   Level 4: The 22-byte decoded message (CP437 → UTF-8)
//
// Usage:
//   typst compile plot_lnav_schematic.typ analysis_output/lnav_schematic.png --ppi 300
//   typst compile plot_lnav_schematic.typ analysis_output/lnav_schematic.pdf

#set page(width: 280mm, height: auto, margin: 8mm)
#set text(font: "Helvetica Neue", size: 8pt, fill: rgb("333333"))

// ── Colors ──────────────────────────────────────────────────────────────────
#let frame-bg     = rgb("f0f0f0")
#let header-bg    = rgb("bfbfbf")
#let parity-bg    = rgb("d9d1c7")
#let highlight-bg = rgb("2d4e86")
#let highlight-fg = white
#let accent-light = rgb("c0d0f0")
#let border-light = rgb("c7c7c7")
#let border-dark  = rgb("1c3868")
#let text-mid     = rgb("737373")
#let text-light   = rgb("a6a6a6")
#let arrow-color  = rgb("737373")
#let other-bg     = rgb("c8cdd6")

// ── Layout constants ────────────────────────────────────────────────────────
#let content-w = 280mm - 2 * 8mm   // page width minus margins

// Level 1: subframes
#let sf-width = 42mm
#let sf-gap   = 4pt
#let sf-n     = 5

// Level 2: pages
#let page-width = 30mm
#let page-gap   = 5pt
#let page-n     = 7

// Level 3: words
#let l3-width       = 25mm
#let l3-gap         = 2pt
#let l3-n           = 10
#let l3-msg-height  = 18mm
#let l3-parity-height = 5.5mm

// Level 4: message characters
#let cell-size   = 9.5mm
#let cell-gap    = 0.8pt
#let cell-height = 10mm
#let msg-n       = 22

// ── Position helpers ────────────────────────────────────────────────────────
// Center-x of item i (0-indexed) in a centered row of n items
#let item-cx(i, w, gap, n) = {
  let total = n * w + (n - 1) * gap
  (content-w - total) / 2 + i * (w + gap) + w / 2
}
// Left edge of a centered row
#let row-left(w, gap, n) = {
  let total = n * w + (n - 1) * gap
  (content-w - total) / 2
}
// Right edge of a centered row
#let row-right(w, gap, n) = {
  let total = n * w + (n - 1) * gap
  (content-w + total) / 2
}

// ── Reusable components ─────────────────────────────────────────────────────

// A labelled box with optional sub-label
#let word-box(label, sublabel: none, bg: frame-bg, fg: rgb("333333"),
              sub-fg: text-mid, width: 22mm, height: 12mm,
              border: border-light, stroke-width: 0.5pt,
              label-size: 12pt, sub-size: 11pt) = {
  box(width: width, height: height, fill: bg,
      stroke: stroke-width + border, radius: 0pt,
      inset: (x: 1.5pt, y: 2.5pt),
    align(center + horizon,
      stack(dir: ttb, spacing: 3pt,
        text(size: label-size, fill: fg, label),
        if sublabel != none { text(size: sub-size, fill: sub-fg, sublabel) },
      )
    )
  )
}

// Branch curve: vertical stem → quarter-circle → horizontal line → quarter-circle → vertical drop.
// Both corners use identical quarter-circle curves; only the horizontal length varies.
#let branch-curve(from-x, to-x, h, r, k) = {
  let mid = h / 2
  let dir = if to-x > from-x { 1 } else { -1 }
  (
    curve.move((from-x, 0pt)),
    // Vertical stem
    curve.line((from-x, mid - r)),
    // Corner: vertical → horizontal (quarter-circle)
    curve.cubic(
      (from-x, mid - r * (1 - k)),
      (from-x + dir * r * (1 - k), mid),
      (from-x + dir * r, mid)),
    // Horizontal line
    curve.line((to-x - dir * r, mid)),
    // Corner: horizontal → vertical (quarter-circle, identical shape)
    curve.cubic(
      (to-x - dir * r * (1 - k), mid),
      (to-x, mid + r * (1 - k)),
      (to-x, mid + r)),
    // Vertical drop
    curve.line((to-x, h)),
  )
}

// Connector constants
#let conn-h = 22pt    // connector height
#let conn-r = 5pt     // corner radius
#let conn-k = 0.552   // cubic bezier quarter-circle approximation

// Tree connector: stem splits into two branches with identical corner curves.
#let tree-connector(stem-x, bar-l, bar-r, annotation) = {
  let s = 0.7pt + arrow-color
  v(1pt)
  block(width: content-w, height: conn-h, {
    place(left + top,
      box(width: content-w, height: conn-h,
        curve(stroke: s,
          ..branch-curve(stem-x, bar-l, conn-h, conn-r, conn-k),
          ..branch-curve(stem-x, bar-r, conn-h, conn-r, conn-k),
        )
      )
    )
    place(left + top, dx: stem-x + 8pt, dy: 0pt,
      text(size: 12pt, fill: text-mid, annotation))
  })
  v(1pt)
}

// Mapping connector: two independent branches with identical corner curves.
#let mapping-connector(top-l, top-r, bot-l, bot-r, annotation) = {
  let s = 0.7pt + arrow-color
  v(2pt)
  block(width: content-w, height: conn-h, {
    place(left + top,
      box(width: content-w, height: conn-h,
        curve(stroke: s,
          ..branch-curve(top-l, bot-l, conn-h, conn-r, conn-k),
          ..branch-curve(top-r, bot-r, conn-h, conn-r, conn-k),
        )
      )
    )
    place(center + horizon,
      text(size: 12pt, fill: text-mid, annotation))
  })
  v(2pt)
}

// Section heading
#let section-title(body) = {
  v(4pt)
  align(center, text(size: 14pt, fill: rgb("333333"), body))
  v(3pt)
}

// ── KEY POSITIONS ───────────────────────────────────────────────────────────
// Subframe 4 is item index 3 in level 1
#let sf4-x     = item-cx(3, sf-width, sf-gap, sf-n)
// Pages row edges
#let pages-l   = row-left(page-width, page-gap, page-n)
#let pages-r   = row-right(page-width, page-gap, page-n)
// Page 17 is item index 3 in level 2
#let p17-x     = item-cx(3, page-width, page-gap, page-n)
// Words row edges
#let words-l   = row-left(l3-width, l3-gap, l3-n)
#let words-r   = row-right(l3-width, l3-gap, l3-n)
// Blue message bits: left edge of Word 3's msg portion to right edge of Word 10's msg portion
#let msg-bits-l = words-l + 2 * (l3-width + l3-gap) + l3-width / 3
#let msg-bits-r = words-l + 9 * (l3-width + l3-gap) + l3-width * 2 / 3
// Character cells row edges
#let chars-l   = row-left(cell-size, cell-gap, msg-n)
#let chars-r   = row-right(cell-size, cell-gap, msg-n)

// ── LAYOUT ──────────────────────────────────────────────────────────────────

// Main title
#align(center,
  text(size: 18pt, fill: rgb("333333"),
    [GPS L1 C/A Navigation Message --- Locating the Special Message])
)

#v(6pt)

// ── LEVEL 1: LNAV frame = 5 subframes ─────────────────────────────────────
#section-title[LNAV frame --- 1500 bits (5 subframes #sym.times 300 bits), transmitted in 30 seconds]

#align(center,
  grid(columns: sf-n, column-gutter: sf-gap,
    word-box([Subframe 1], sublabel: [clock & health],   width: sf-width),
    word-box([Subframe 2], sublabel: [ephemeris I],      width: sf-width),
    word-box([Subframe 3], sublabel: [ephemeris II],     width: sf-width),
    word-box([Subframe 4], sublabel: [almanac & misc.],
             bg: highlight-bg, fg: highlight-fg, sub-fg: accent-light,
             width: sf-width, border: border-dark, stroke-width: 1.2pt),
    word-box([Subframe 5], sublabel: [almanac],          width: sf-width),
  )
)

// ── Connector: Subframe 4 → Pages ──────────────────────────────────────────
#tree-connector(sf4-x, pages-l, pages-r,
  [25 pages, one per frame (12.5 min cycle)])

// ── LEVEL 2: Subframe 4 = 25 pages ───────────────────────────────────────
#align(center,
  grid(columns: page-n, column-gutter: page-gap,
    word-box([Page 1],  sublabel: [SV ID 57],     width: page-width),
    word-box([Page 2],  sublabel: [SV ID 25--32], width: page-width),
    word-box([#sym.dots.h], width: page-width),
    word-box([Page 17], sublabel: [SV ID 55],
             bg: highlight-bg, fg: highlight-fg, sub-fg: accent-light,
             width: page-width, border: border-dark, stroke-width: 1.2pt),
    word-box([Page 18], sublabel: [SV ID 56],     width: page-width),
    word-box([#sym.dots.h], width: page-width),
    word-box([Page 25], sublabel: [SV ID 63],     width: page-width),
  )
)

// ── Connector: Page 17 → Words ─────────────────────────────────────────────
#tree-connector(p17-x, words-l, words-r,
  [10 words #sym.times 30 bits --- 176 message bits (22 bytes) from Words 3--10])

// ── LEVEL 3: Page 17 = 10 words, bit extraction ─────────────────────────
// Word data: (label, content-label, bit-info, role)
#let l3-words = (
  ("Word 1",  "TLM",       none,       "header"),
  ("Word 2",  "HOW",       none,       "header"),
  ("Word 3",  "bits 9–24", "16 bits",  "partial-before"),
  ("Word 4",  "bits 1–24", "24 bits",  "msg"),
  ("Word 5",  "bits 1–24", "24 bits",  "msg"),
  ("Word 6",  "bits 1–24", "24 bits",  "msg"),
  ("Word 7",  "bits 1–24", "24 bits",  "msg"),
  ("Word 8",  "bits 1–24", "24 bits",  "msg"),
  ("Word 9",  "bits 1–24", "24 bits",  "msg"),
  ("Word 10", "bits 1–16", "16 bits",  "partial-after"),
)

#align(center,
  grid(columns: l3-n, column-gutter: l3-gap,
    ..for (wlabel, content-label, bit-info, role) in l3-words {
      // Parity border must match the data box above so it doesn't cover
      // the bottom border with a different color
      let parity-border = if role == "header" { rgb("b8b8b8") } else { border-dark }
      (
        stack(dir: ttb, spacing: 0pt,
          if role == "header" {
            word-box(wlabel, sublabel: [#content-label],
              bg: header-bg,
              width: l3-width, height: l3-msg-height,
              border: border-light, stroke-width: 0.5pt)
          } else if role == "msg" {
            word-box(wlabel, sublabel: [#content-label \ #bit-info],
              bg: highlight-bg, fg: highlight-fg, sub-fg: accent-light,
              width: l3-width, height: l3-msg-height,
              border: border-dark, stroke-width: 0.5pt)
          } else if role == "partial-before" {
            let msg-frac = 16/24
            stack(dir: ltr, spacing: 0pt,
              word-box([SV ID],
                bg: other-bg, fg: text-mid,
                width: l3-width * (1 - msg-frac), height: l3-msg-height,
                border: border-dark, stroke-width: 0.5pt,
                label-size: 9pt),
              word-box(wlabel, sublabel: [#content-label \ #bit-info],
                bg: highlight-bg, fg: highlight-fg, sub-fg: accent-light,
                width: l3-width * msg-frac, height: l3-msg-height,
                border: border-dark, stroke-width: 0.5pt,
                label-size: 11pt, sub-size: 9pt),
            )
          } else {
            let msg-frac = 16/24
            stack(dir: ltr, spacing: 0pt,
              word-box(wlabel, sublabel: [#content-label \ #bit-info],
                bg: highlight-bg, fg: highlight-fg, sub-fg: accent-light,
                width: l3-width * msg-frac, height: l3-msg-height,
                border: border-dark, stroke-width: 0.5pt,
                label-size: 11pt, sub-size: 9pt),
              word-box([rsvd],
                bg: other-bg, fg: text-mid,
                width: l3-width * (1 - msg-frac), height: l3-msg-height,
                border: border-dark, stroke-width: 0.5pt,
                label-size: 9pt),
            )
          },
          word-box([parity], bg: parity-bg, fg: text-mid,
                   width: l3-width, height: l3-parity-height,
                   border: parity-border, stroke-width: 0.5pt,
                   label-size: 9pt),
        ),
      )
    },
  )
)

// ── Connector: Words → Message ─────────────────────────────────────────────
#mapping-connector(msg-bits-l, msg-bits-r, chars-l, chars-r,
  [Decode 22 bytes as CP437])

// ── LEVEL 4: Decoded 22-byte message ──────────────────────────────────────

#let msg-chars = "Q°5HY1:U'5PSF8T78J97IY"

#align(center,
  grid(columns: msg-n, column-gutter: cell-gap, row-gutter: 4pt,
    ..for ch in msg-chars.clusters() {
      (
        box(width: cell-size, height: cell-height, fill: highlight-bg,
            stroke: 0.5pt + border-dark, inset: 1pt,
          align(center + horizon,
            text(size: 18pt, fill: highlight-fg, ch)
          )
        ),
      )
    },
    ..for i in range(1, msg-n + 1) {
      (
        align(center, text(size: 10pt, fill: text-light, str(i))),
      )
    },
  )
)

// ── Caption & Footer ────────────────────────────────────────────────────────
#v(2pt)
#align(center,
  text(size: 12pt, fill: text-mid, [Example: PRN 31, 2019-11-20]))
