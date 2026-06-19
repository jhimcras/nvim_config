-- rendermark: home-grown markdown rendering.
--
--   wrap  - browser-like soft-wrap (virtual lines) + boxed pipe tables
--   read  - distraction-free READ mode
--
-- All coupling to the external render-markdown.nvim plugin is isolated in
-- rendermark.rm_compat; see that file. render-markdown.nvim still draws headings,
-- checkboxes, link icons and code blocks today and is set up via its own pckr
-- `config` hook (rm_compat.setup), kept separate from this entry point.

local M = {}

local wrap = require('rendermark.wrap')

function M.setup(opts)
    wrap.setup(opts) -- soft-wrap + tables (registers its own autocmds/command)
    -- READ mode and PlantUML rendering are intentionally disabled here.
    -- PlantUML is now owned by the neopp GUI (it converts ```plantuml blocks to
    -- images directly); READ mode is disabled pending rework.
end

M.refresh = wrap.refresh
M.toggle = wrap.toggle

return M
