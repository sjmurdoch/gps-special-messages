-- Pandoc filter for the PDF build: lift the title block out of the body and
-- drop the web-only "Notes" lead-in.
--
-- Front matter: the Markdown opens with an H1 title, a one-line tagline, and
-- the author/affiliation line, all as ordinary body content (so it renders on
-- plain GitHub). For the PDF these are supplied as metadata instead and
-- rendered by \maketitle, so we drop them from the body to avoid duplication.
--
-- Back matter: the trailing "## Notes" heading and its lead-in paragraph
-- describe an endnotes/margin-note layout ("the notes appear in the margin …
-- tap a footnote marker"). In the PDF the notes are real bottom-of-page
-- footnotes, so that section is both empty (Pandoc has already consumed the
-- [^n]: definitions into footnotes) and inaccurate — drop it too.
--
-- Matching is by content, not position, so it is robust to reordering.

local dropped_title   = false
local dropped_tagline = false
local dropped_author  = false
local dropped_notes_h = false
local dropped_notes_p = false

function Header(el)
  if not dropped_title and el.level == 1 then
    dropped_title = true
    return {}
  end
  if not dropped_notes_h and el.level == 2
     and pandoc.utils.stringify(el) == "Notes" then
    dropped_notes_h = true
    return {}
  end
end

function Para(el)
  local txt = pandoc.utils.stringify(el)
  if not dropped_tagline and txt:find("What 24 million") then
    dropped_tagline = true
    return {}
  end
  if not dropped_author
     and txt:find("Steven J%. Murdoch")
     and txt:find("University College London") then
    dropped_author = true
    return {}
  end
  if not dropped_notes_p and txt:find("Each note records what supports") then
    dropped_notes_p = true
    return {}
  end
end
