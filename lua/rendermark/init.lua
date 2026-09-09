-- rendermark: home-grown markdown rendering.
--
--   deco  - headings, thematic breaks, checkboxes, bullets, quotes, code blocks
--   wrap  - browser-like soft-wrap (virtual lines) + boxed pipe tables
--   image - inline images and PlantUML previews via the neopp GUI backend
--
-- deco is driven by wrap's refresh rather than its own autocmds; see the header of
-- rendermark/deco.lua for why that ordering matters.

local M = {}

local deco = require('rendermark.deco')
local wrap = require('rendermark.wrap')
local image = require('rendermark.image')
local checkbox = require('rendermark.checkbox')

function M.setup(opts)
    -- Before wrap, so the highlight groups exist by the time it first draws.
    deco.setup(opts)
    wrap.setup(opts) -- soft-wrap + tables (registers its own autocmds/command)
    -- Markdown image + PlantUML rendering: parses buffers, computes placement,
    -- and drives the neopp GUI image backend via vim.ui.img (set/del). neopp only
    -- loads/renders/deletes.
    image.setup(opts)
    -- Tag-jump navigation for [text](link) / [[wikilink]]: disabled in favor of
    -- markdown-oxide's own go-to-definition, so <C-]>/<C-}> just use plain LSP.
    -- link.setup(opts)
    -- Obsidian-compatible checkbox toggle ([ ]/[x]) on <C-Space>.
    checkbox.setup(opts)
end

M.refresh = wrap.refresh
M.toggle = wrap.toggle

return M
