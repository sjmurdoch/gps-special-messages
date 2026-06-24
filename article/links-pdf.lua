-- Pandoc filter for the PDF build.
--
-- The article source uses repo-relative paths (../figures/output/...,
-- ../verify/..., ../CHANGELOG.md). In the PDF:
--   * image targets are LEFT as relative filesystem paths so pandoc embeds
--     the actual PNGs (build runs from the article/ directory, so
--     ../figures/output/... resolves);
--   * every other repo-relative link is absolutised to the GitHub blob URL
--     so it stays clickable in the PDF.
--
-- (Contrast links.lua, the web build's variant, which rewrites image srcs to
-- the staged figures/ copy beside index.html.)

local REPO_BLOB = "https://github.com/sjmurdoch/gps-special-messages/blob/main/"

function Link(el)
  if el.target:match("^%.%./") then
    el.target = REPO_BLOB .. el.target:gsub("^%.%./", "")
  end
  return el
end
