-- Pandoc filter for the PDF build: deduplicate reused footnotes for LaTeX.
--
-- Plain Pandoc inlines a fresh Note at every [^label] reference, so a label
-- cited twice emits two identical \footnote calls — two bottom-of-page notes
-- with different numbers, and every later footnote shifted up by one. (In
-- this article only [^16] is reused; see the footnote pitfall in
-- ../CLAUDE.md.) footnotes.lua solves this for HTML; this is the LaTeX twin.
--
-- Strategy, relying on LaTeX footnote numbering being driven by \footnote
-- (which steps the counter) while \footnotemark[n] only prints n:
--   * First time a note body is seen, keep the Note. The LaTeX writer emits
--     \footnote{…}; surviving notes step the counter 1..N in document order,
--     so a kept note's printed number equals its rank among unique notes.
--   * Each later identical Note becomes \footnotemark[n], pointing at the
--     first occurrence's number without stepping the counter.
-- Content identity uses the native (AST) serialisation, so only genuinely
-- identical notes merge.

local seen = {}
local count = 0

function Note(el)
  local key = pandoc.write(pandoc.Pandoc(el.content), "native")
  local n = seen[key]
  if n == nil then
    count = count + 1
    seen[key] = count
    return nil  -- keep the Note; writer numbers it `count`
  end
  return pandoc.RawInline("latex", string.format("\\footnotemark[%d]", n))
end
