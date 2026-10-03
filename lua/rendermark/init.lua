-- rendermark: markdown rendering.
--   deco  - headings, breaks, checkboxes, bullets, quotes, code blocks
--   wrap  - soft-wrap (virtual lines) + pipe tables; drives deco
--   image - inline images and PlantUML previews via neopp

local M = {}

local deco = require('rendermark.deco')
local wrap = require('rendermark.wrap')
local image = require('rendermark.image')
local checkbox = require('rendermark.checkbox')
local html = require('rendermark.html')

function M.setup(opts)
    -- Before wrap, so highlight groups exist on first draw.
    deco.setup(opts)
    html.setup()
    wrap.setup(opts) -- soft-wrap + tables
    image.setup(opts)
    -- Disabled in favor of markdown-oxide's go-to-definition.
    -- link.setup(opts)
    -- Checkbox toggle on <C-Space>.
    checkbox.setup(opts)
end

M.refresh = wrap.refresh
M.toggle = wrap.toggle

return M
