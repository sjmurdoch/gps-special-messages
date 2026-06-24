-- Pandoc filter: deduplicate reused footnotes.
--
-- Plain Pandoc has no multi-reference footnote support. Citing the same
-- `[^label]` twice emits two separate Note elements with identical content,
-- and the HTML writer numbers them as two different notes — the second gets
-- a fresh number and a duplicate body appended at the end (so the article
-- rendered 59 notes for 57 labels: `[^17]` and `[^48]` are each cited
-- twice). See the Pandoc-footnotes pitfall in ../CLAUDE.md.
--
-- This filter merges notes whose content is identical so a reused footnote
-- renders once and every reference shares the first occurrence's number:
--
--   * Walk Notes in document order. The first time a given note body is
--     seen, keep the Note. The HTML writer numbers the surviving Notes
--     1..N in document order, so a kept note's number equals its rank among
--     unique notes — which is exactly the counter we assign here.
--   * Replace every later Note with identical content by a footnote-ref
--     link to the first occurrence's `#fnN` body, showing number N. This is
--     the same markup Pandoc emits for a reference, so both sidenotes.js
--     (clones the `#fnN` body beside the ref) and the no-JS endnote
--     fallback (jumps to `#fnN`) resolve it.
--
-- Content identity uses the native (AST) serialisation of the note body, so
-- only genuinely identical notes merge; distinct notes never collide. (The
-- article reuses a label only to cite the very same note, so this is safe;
-- two deliberately-distinct notes would need to differ in at least one
-- character, which they always do here.)
--
-- Run this AFTER links.lua so the surviving notes carry the rewritten repo
-- links; the reused copies are byte-identical either way.

local seen = {}        -- note body (native AST string) -> number among uniques
local unique_count = 0 -- running count of distinct notes kept
local dup_seq = 0      -- global counter giving each duplicate ref a unique id

function Note(el)
  local key = pandoc.write(pandoc.Pandoc(el.content), "native")
  local n = seen[key]
  if n == nil then
    unique_count = unique_count + 1
    seen[key] = unique_count
    return nil  -- keep the Note; the writer will number it unique_count
  end
  dup_seq = dup_seq + 1
  local html = string.format(
    '<a href="#fn%d" class="footnote-ref" id="fnref-dup-%d" role="doc-noteref"><sup>%d</sup></a>',
    n, dup_seq, n)
  return pandoc.RawInline("html", html)
end
