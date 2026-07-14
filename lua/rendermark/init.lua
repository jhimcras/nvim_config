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
local image = require('rendermark.image')
local link = require('rendermark.link')

function M.setup(opts)
    wrap.setup(opts) -- soft-wrap + tables (registers its own autocmds/command)
    -- Markdown image + PlantUML rendering: parses buffers, computes placement,
    -- and drives the neopp GUI image backend via vim.ui.img (set/del). neopp only
    -- loads/renders/deletes. READ mode is disabled pending rework.
    image.setup(opts)
    -- Tag-jump style navigation for [text](link): <C-]>/<C-}> follow the link
    -- under the cursor (current window / vertical split).
    -- link.setup(opts)
end

M.refresh = wrap.refresh
M.toggle = wrap.toggle

return M
