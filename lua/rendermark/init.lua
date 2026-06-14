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
local read = require('rendermark.read')
local plantuml = require('rendermark.plantuml')

function M.setup(opts)
    wrap.setup(opts) -- soft-wrap + tables (registers its own autocmds/command)
    read.setup()     -- READ mode (registers its own autocmds/keymaps)
    plantuml.setup(opts and opts.plantuml or nil)
end

M.refresh = wrap.refresh
M.toggle = wrap.toggle
M.plantuml_refresh = plantuml.refresh

return M
