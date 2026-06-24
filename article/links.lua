-- Pandoc filter for the GitHub Pages build.
--
-- The article source uses repo-relative paths (../figures/output/...,
-- ../verify/..., ../CHANGELOG.md) so it reads and renders correctly on
-- plain GitHub. On the published page those paths would 404, so:
--   * figure images are rewritten to the figures/ copy that build.sh
--     stages next to index.html;
--   * every other repo-relative link is absolutised to the GitHub blob
--     URL for the main branch.

local REPO_BLOB = "https://github.com/sjmurdoch/gps-special-messages/blob/main/"

function Image(el)
  local rewritten = el.src:gsub("^%.%./figures/output/", "figures/")
  el.src = rewritten
  return el
end

function Link(el)
  if el.target:match("^%.%./") then
    el.target = REPO_BLOB .. el.target:gsub("^%.%./", "")
  end
  return el
end
