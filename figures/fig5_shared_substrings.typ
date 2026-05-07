// Shared Substring Alignment Diagram
//
// Shows message pairs that share long identical substrings at fixed positions.
// Highlights matching characters to reveal structural patterns within the "noise".
//
// Usage:
//   typst compile plot_shared_substrings.typ analysis_output/shared_substrings.png --ppi 300
//   typst compile plot_shared_substrings.typ analysis_output/shared_substrings.pdf

#set page(width: 240mm, height: 180mm, margin: 12mm)
#set text(font: "Helvetica Neue", size: 9pt, fill: rgb("333333"))
#show math.equation: set text(font: "Helvetica Neue")

// ── Colors ──────────────────────────────────────────────────────────────────
#let match-bg    = rgb("2d4e86")   // Deep blue (matches lnav_schematic highlight)
#let match-fg    = white
#let diff-bg     = rgb("f4f4f4")   // Very light gray
#let diff-fg     = rgb("808080")   // Muted gray
#let border-dark = rgb("1c3868")
#let border-lite = rgb("e0e0e0")
#let text-mid    = rgb("505050")
#let text-lite   = rgb("a0a0a0")

// ── Layout Constants ────────────────────────────────────────────────────────
#let cell-size   = 7.2mm
#let cell-gap    = 0.6pt
#let row-gap     = 2.5pt
#let group-gap   = 22pt
#let msg-n       = 22
#let date-w      = 60pt
#let prn-w       = 40pt
#let label-spacing = 10pt

// ── Data ────────────────────────────────────────────────────────────────────
#let groups = (
  (
    label:  "Group B — 10 shared characters, same day",
    msg1:   "T3\"EHSDS\"I4H.'HX-+7UX ",
    msg2:   "\"JY32Q8/S'°5.'HX-+7UX ",
    date1:  "2014-10-08",
    date2:  "2014-10-08",
    prn1:   "32",
    prn2:   "29"
  ),
  (
    label:  "Group D — 9 shared characters, 9 months apart",
    msg1:   "Q\"O:TKLY47IRP16AC024BA",
    msg2:   "OH6°S3LY47IRP16K XD.4L",
    date1:  "2021-06-05",
    date2:  "2020-09-19",
    prn1:   "31",
    prn2:   "30"
  ),
  (
    label:  "Group A — 8 shared characters, 3 weeks apart",
    msg1:   "2CK0E6:U'5PSF8TJ90FDX'",
    msg2:   "Q°5HY1:U'5PSF8T78J97IY",
    date1:  "2019-12-11",
    date2:  "2019-11-20",
    prn1:   "1",
    prn2:   "31"
  ),
  (
    label:  "Group C — 7 + 4 shared characters, 4 days apart",
    msg1:   "43PA :ZU°SGZ8PJDL-:IM ",
    msg2:   ": 2NKMZU°SGZ8PJEGB:IM ",
    date1:  "2024-04-07",
    date2:  "2024-04-11",
    prn1:   "3",
    prn2:   "3"
  ),
)

// ── Components ──────────────────────────────────────────────────────────────

#let char-cell(ch, is-match) = {
  box(width: cell-size, height: cell-size, 
      fill: if is-match { match-bg } else { diff-bg },
      stroke: 0.4pt + if is-match { border-dark } else { border-lite },
      radius: 0.5pt,
    align(center + horizon,
      text(size: 10pt, weight: "bold", 
           fill: if is-match { match-fg } else { diff-fg }, 
           ch)
    )
  )
}

#let message-row(msg, matches, date, prn) = {
  stack(dir: ltr, spacing: label-spacing,
    align(horizon, box(width: date-w, text(size: 8pt, fill: text-mid, date))),
    grid(columns: msg-n, column-gutter: cell-gap,
      ..for (i, ch) in msg.clusters().enumerate() {
        (char-cell(ch, matches.at(i)),)
      }
    ),
    align(horizon, box(width: prn-w, text(size: 8pt, fill: text-mid, [PRN #prn]))),
  )
}

#let substring-group(g) = {
  let chars1 = g.msg1.clusters()
  let chars2 = g.msg2.clusters()
  let matches = range(msg-n).map(i => chars1.at(i) == chars2.at(i))
  
  block(width: 100%, inset: (bottom: group-gap), {
    stack(dir: ttb, spacing: 6pt,
      // Group header
      stack(dir: ltr, spacing: label-spacing,
        box(width: date-w), // indent to align with cells
        text(size: 9pt, weight: "medium", fill: rgb("222222"), g.label),
      ),
      // Two message rows
      stack(dir: ttb, spacing: row-gap,
        message-row(g.msg1, matches, g.date1, g.prn1),
        message-row(g.msg2, matches, g.date2, g.prn2),
      )
    )
  })
}

// ── Title ───────────────────────────────────────────────────────────────────

#align(center, 
  stack(dir: ttb, spacing: 6pt,
    text(size: 14pt, weight: "bold", [Shared Substring Alignment]),
    text(size: 9pt, fill: text-mid, [Identifying recurring structure within the encrypted GPS special messages])
  )
)

#v(18pt)

// ── Main Content ─────────────────────────────────────────────────────────────

#stack(dir: ttb, ..groups.map(substring-group))

// ── Column Headers (Byte Positions) ──────────────────────────────────────────
// Correctly aligned with character grid: date-w offset + spacing
#v(-group-gap + 4pt)
#stack(dir: ltr, spacing: label-spacing,
  box(width: date-w),
  grid(columns: msg-n, column-gutter: cell-gap,
    ..range(1, msg-n + 1).map(i => box(width: cell-size, align(center, text(size: 6pt, fill: text-lite, str(i)))))
  )
)
#v(2pt)
#stack(dir: ltr, spacing: label-spacing,
  box(width: date-w),
  box(width: msg-n * cell-size + (msg-n - 1) * cell-gap, align(center, text(size: 7pt, fill: text-lite, [Byte position])))
)

#v(24pt)

// ── Legend ──────────────────────────────────────────────────────────────────
#align(center,
  stack(dir: ltr, spacing: 30pt,
    stack(dir: ltr, spacing: 6pt,
      box(width: 10pt, height: 10pt, fill: match-bg, stroke: 0.4pt + border-dark, radius: 1pt),
      align(horizon, text(size: 8pt, fill: text-mid, [Identical character at same position]))
    ),
    stack(dir: ltr, spacing: 6pt,
      box(width: 10pt, height: 10pt, fill: diff-bg, stroke: 0.4pt + border-lite, radius: 1pt),
      align(horizon, text(size: 8pt, fill: text-mid, [Differing character]))
    )
  )
)

#v(1fr)
