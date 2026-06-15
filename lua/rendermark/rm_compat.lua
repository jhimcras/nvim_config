-- Sole contact point with the external render-markdown.nvim plugin.
--
-- Everything that knows about render-markdown.nvim lives here: its setup config
-- and the two runtime internals pokes used by READ mode (anti-conceal and
-- concealcursor). When the rendermark plugin takes over the remaining rendering
-- (headings, checkboxes, link icons, code blocks), this is the only file to
-- delete and the only require to drop.

local M = {}

local saved_concealcursor = nil -- render-markdown concealcursor.rendered before READ

-- render-markdown.nvim setup. Tables are disabled here because the rendermark
-- wrap engine renders them (wrapped cells + proportional widths).
function M.setup()
    require'render-markdown'.setup{
        overrides = {
            buftype = {
                nofile = { enabled = false },
            },
        },
        indent = {
            enabled = false,
            render_modes = true,
            per_level = 4,
            skip_level = 0,
            skip_heading = true,
        },
        -- Prefix rendering belongs to render-markdown.nvim on real buffer lines.
        -- rendermark.wrap only preserves hanging-indent space on virtual rows.
        heading = {
            icons = { '󰲡 ', '󰲣 ', '󰲥 ', '󰲧 ', '󰲩 ', '󰲫 ' },
            signs = { '󰫎 ' },
            width = 'block',
            -- border = true,
            -- left_pad = 2,
            -- right_pad = 2,
        },
        bullet = {
            icons = { '●', '○', '◆', '◇' },
            ordered_icons = function(ctx)
                local value = vim.trim(ctx.value)
                local index = tonumber(value:sub(1, #value - 1))
                return ('%d.'):format(index > 1 and index or ctx.index)
            end,
            left_pad = 0,
            right_pad = 0,
            highlight = 'RenderMarkdownBullet',
            scope_highlight = {},
        },
        checkbox = {
            bullet = true,
            unchecked = { icon = ' ' },
            checked   = { icon = ' ' },
            custom = {
                todo = { raw = '[-]', rendered = ' ', highlight = 'RenderMarkdownTodo', scope_highlight = nil },
            },
        },
        link = {
            image     = ' ',
            email     = ' ',
            hyperlink = ' ',
            wiki      = { icon = ' ' },
            custom = {
                web       = { pattern = '^http',          icon = ' '  },
                github    = { pattern = 'github%.com',    icon = '  ' },
                google    = { pattern = 'google%.com',    icon = '  ' },
                reddit    = { pattern = 'reddit%.com',    icon = '  ' },
                wikipedia = { pattern = 'wikipedia%.org', icon = '  ' },
                youtube   = { pattern = 'youtube%.com',   icon = '󰗃 '  },
            },
        },
        code = {
            language = true,
            position = 'right',
            width = 'block',
            left_pad = 1,
            right_pad = 1,
            min_width = 50,
            border = 'thin',
        },
        -- Tables are rendered by the rendermark wrap engine (rendermark/wrap.lua).
        pipe_table = { enabled = false },
    }
end

-- Toggle render-markdown anti-conceal. Mirrors the plugin's own runtime mutation
-- (render-markdown/state.lua:modify_anti_conceal) then forces a re-render. This is
-- global but restored on exit, so normal editing keeps anti-conceal.
function M.set_anti_conceal(enabled)
    local ok, state = pcall(require, 'render-markdown.state')
    if not ok or not state.config or not state.config.anti_conceal then
        return
    end
    state.config.anti_conceal.enabled = enabled
    for _, cfg in pairs(state.cache or {}) do
        if cfg.anti_conceal then
            cfg.anti_conceal.enabled = enabled
        end
    end
    pcall(function() require('render-markdown.api').set(true) end)
end

-- Force render-markdown to conceal the cursor's own line too. By default it sets
-- the 'concealcursor' win option to '' on render, so the line under the cursor
-- shows raw concealed syntax (e.g. '- [ ]' keeps its '-'/'[ ]' instead of the
-- single checkbox glyph). Passing 'nvic' conceals in all modes; nil restores the
-- saved render value. Mutates state.config + every cached buffer config, like
-- set_anti_conceal, then forces a re-render.
function M.set_conceal_cursor(value)
    local ok, state = pcall(require, 'render-markdown.state')
    if not ok or not state.config or not state.config.win_options
        or not state.config.win_options.concealcursor then
        return
    end
    if saved_concealcursor == nil and value ~= nil then
        saved_concealcursor = state.config.win_options.concealcursor.rendered
    end
    local rendered = value ~= nil and value or (saved_concealcursor or '')
    state.config.win_options.concealcursor.rendered = rendered
    for _, cfg in pairs(state.cache or {}) do
        if cfg.win_options and cfg.win_options.concealcursor then
            cfg.win_options.concealcursor.rendered = rendered
        end
    end
    if value == nil then
        saved_concealcursor = nil
    end
    pcall(function() require('render-markdown.api').set(true) end)
end

return M
