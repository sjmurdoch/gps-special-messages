-- Pandoc filter for the PDF build: turn raw-HTML <sup>…</sup> / <sub>…</sub>
-- into real Superscript / Subscript inlines.
--
-- The source embeds a few raw-HTML superscripts (e.g. 1.3 × 10<sup>–15</sup>).
-- The HTML writer renders these directly, but the LaTeX writer drops unknown
-- raw HTML, which would silently flatten "10<sup>–15</sup>" to "10–15". This
-- filter rebuilds the markup as native pandoc Super/Subscript so it survives
-- into LaTeX (and any other) output.

local function is_open(el, tag)
  return el.t == "RawInline" and el.format:match("html")
     and el.text:gsub("%s", ""):lower() == "<" .. tag .. ">"
end

local function is_close(el, tag)
  return el.t == "RawInline" and el.format:match("html")
     and el.text:gsub("%s", ""):lower() == "</" .. tag .. ">"
end

local function rewrite(inlines)
  local out = pandoc.List()
  local i = 1
  while i <= #inlines do
    local el = inlines[i]
    local tag = nil
    if is_open(el, "sup") then tag = "sup"
    elseif is_open(el, "sub") then tag = "sub" end
    if tag then
      local inner = pandoc.List()
      i = i + 1
      while i <= #inlines and not is_close(inlines[i], tag) do
        inner:insert(inlines[i])
        i = i + 1
      end
      if tag == "sup" then
        out:insert(pandoc.Superscript(inner))
      else
        out:insert(pandoc.Subscript(inner))
      end
    else
      out:insert(el)
    end
    i = i + 1
  end
  return out
end

function Inlines(inlines)
  return rewrite(inlines)
end
