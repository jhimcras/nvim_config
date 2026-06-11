-- Markdown READ mode: a distraction-free reading view for markdown buffers.
--
-- The cursor and cursorline are hidden, and no line ever falls back to its raw
-- representation regardless of where the (hidden) cursor sits. This requires
-- neutralising the two raw fallbacks that exist in normal editing:
--   * render-markdown "anti-conceal" (reveals raw syntax on the cursor line)
--   * wrap.lua leaving the cursor line unwrapped on a single row
-- Navigation is pure scrolling; editing is blocked via 'nomodifiable'.
--
-- Markdown opens in READ mode by default. <leader>r enters from Normal mode and
-- <Esc> returns to Normal.

local ut = require 'util'
local M = {}

local saved_guicursor = nil          -- 'guicursor' before the first READ enter
local saved_concealcursor = nil      -- render-markdown concealcursor.rendered before READ
local saved_modifiable = {}          -- buf -> previous 'modifiable'
local saved_relativenumber = {}      -- buf -> previous 'relativenumber'
local saved_scrolloff = {}           -- buf -> previous 'scrolloff'
local cursor_au = {}                 -- buf -> CursorMoved autocmd id

-- Toggle render-markdown anti-conceal. Mirrors the plugin's own runtime mutation
-- (render-markdown/state.lua:modify_anti_conceal) then forces a re-render. This is
-- global but restored on exit, so normal editing keeps anti-conceal.
local function set_anti_conceal(enabled)
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
local function set_conceal_cursor(value)
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

-- Point the cursor highlight at the editor background so the cursor is invisible.
-- GUI/Neovide-targeted; this is the spot most likely to need per-terminal tuning.
local function hide_cursor()
    if saved_guicursor == nil then
        saved_guicursor = vim.o.guicursor
    end
    local normal = vim.api.nvim_get_hl(0, { name = 'Normal' })
    local hl = { blend = 100 }
    if normal.bg then
        hl.fg = normal.bg
        hl.bg = normal.bg
    end
    vim.api.nvim_set_hl(0, 'ReadModeHiddenCursor', hl)
    vim.o.guicursor = 'a:block-blinkon0-ReadModeHiddenCursor'
end

local function restore_cursor()
    if saved_guicursor ~= nil then
        vim.o.guicursor = saved_guicursor
        saved_guicursor = nil
    end
end

-- Keep the hidden cursor pinned to column 0 with no horizontal scroll: leftcol > 0
-- makes wrap.lua bail out and show raw text (wrap.lua:508).
local function pin_cursor(buf)
    return vim.api.nvim_create_autocmd('CursorMoved', {
        buffer = buf,
        callback = function()
            local view = vim.fn.winsaveview()
            if view.col ~= 0 or view.leftcol ~= 0 then
                view.col = 0
                view.leftcol = 0
                vim.fn.winrestview(view)
            end
        end,
    })
end

function M.enter(buf, win)
    buf = buf or vim.api.nvim_get_current_buf()
    win = win or vim.api.nvim_get_current_win()
    if vim.b[buf].read_mode then
        return
    end
    vim.b[buf].read_mode = true

    saved_modifiable[buf] = vim.bo[buf].modifiable
    vim.bo[buf].modifiable = false
    vim.wo[win].cursorline = false
    -- No cursor in READ mode, so relative numbers are meaningless: force them off
    -- (number stays as configured). Restored on exit.
    saved_relativenumber[buf] = vim.wo[win].relativenumber
    vim.wo[win].relativenumber = false
    -- scrolloff keeps the (hidden, pinned) cursor a margin from the edge, which
    -- fights <C-e>/<C-y> when a wrapped line sits at the window edge (k snaps back).
    saved_scrolloff[buf] = vim.wo[win].scrolloff
    vim.wo[win].scrolloff = 0
    hide_cursor()
    set_anti_conceal(false)
    set_conceal_cursor('nvic')

    vim.b[buf].markdown_read_mode = true
    pcall(function() require('wrap').refresh(win) end)

    ut.nnoremap('j', '<C-e>', { buffer = buf })
    ut.nnoremap('k', '<C-y>', { buffer = buf })
    ut.nnoremap('<esc>', function() M.exit(buf, win) end, { buffer = buf })

    cursor_au[buf] = pin_cursor(buf)
    local view = vim.fn.winsaveview()
    view.col = 0
    view.leftcol = 0
    vim.fn.winrestview(view)
end

function M.exit(buf, win)
    buf = buf or vim.api.nvim_get_current_buf()
    win = win or vim.api.nvim_get_current_win()
    if not vim.b[buf].read_mode then
        return
    end
    vim.b[buf].read_mode = false

    if cursor_au[buf] then
        pcall(vim.api.nvim_del_autocmd, cursor_au[buf])
        cursor_au[buf] = nil
    end

    pcall(vim.keymap.del, 'n', 'j', { buffer = buf })
    pcall(vim.keymap.del, 'n', 'k', { buffer = buf })
    pcall(vim.keymap.del, 'n', '<esc>', { buffer = buf })

    vim.b[buf].markdown_read_mode = false
    pcall(function() require('wrap').refresh(win) end)
    set_anti_conceal(true)
    set_conceal_cursor(nil)

    if saved_modifiable[buf] ~= nil then
        vim.bo[buf].modifiable = saved_modifiable[buf]
        saved_modifiable[buf] = nil
    else
        vim.bo[buf].modifiable = true
    end
    if saved_relativenumber[buf] ~= nil then
        vim.wo[win].relativenumber = saved_relativenumber[buf]
        saved_relativenumber[buf] = nil
    end
    if saved_scrolloff[buf] ~= nil then
        vim.wo[win].scrolloff = saved_scrolloff[buf]
        saved_scrolloff[buf] = nil
    end
    vim.wo[win].cursorline = true
    restore_cursor()
end

function M.toggle(buf, win)
    buf = buf or vim.api.nvim_get_current_buf()
    if vim.b[buf].read_mode then
        M.exit(buf, win)
    else
        M.enter(buf, win)
    end
end

function M.setup()
    vim.api.nvim_create_autocmd('FileType', {
        pattern = 'markdown',
        callback = function(args)
            local buf = args.buf
            ut.nnoremap('<leader>r', function() M.enter() end, { buffer = buf })
            -- Markdown opens in READ mode by default. Defer so wrap.lua and
            -- render-markdown have finished attaching to the buffer.
            vim.schedule(function()
                if vim.api.nvim_buf_is_valid(buf)
                    and vim.api.nvim_get_current_buf() == buf then
                    M.enter(buf, vim.api.nvim_get_current_win())
                end
            end)
        end,
    })
end

return M
