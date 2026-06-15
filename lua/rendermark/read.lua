-- Markdown READ mode: a distraction-free reading view for markdown buffers.
--
-- The cursor and cursorline are hidden, and no line ever falls back to its raw
-- representation regardless of where the (hidden) cursor sits. This requires
-- neutralising the two raw fallbacks that exist in normal editing:
--   * render-markdown "anti-conceal" (reveals raw syntax on the cursor line)
--   * the wrap engine leaving the cursor line unwrapped on a single row
-- Navigation is pure scrolling; editing is blocked via 'nomodifiable'.
--
-- Markdown opens in READ mode by default. <leader>r enters from Normal mode and
-- <Esc> returns to Normal.

local ut = require 'util'
local wrap = require 'rendermark.wrap'
local rm = require 'rendermark.rm_compat'
local M = {}

local saved_guicursor = nil          -- 'guicursor' before the first READ enter
local saved_modifiable = {}          -- buf -> previous 'modifiable'
local saved_relativenumber = {}      -- win -> previous 'relativenumber'
local saved_scrolloff = {}           -- win -> previous 'scrolloff'
local cursor_au = {}                 -- buf -> CursorMoved autocmd id
local visuals_active = {}            -- win -> true while READ window/global visuals applied

-- Anti-conceal / concealcursor toggles live in rendermark.rm_compat (the sole
-- render-markdown.nvim contact point): rm.set_anti_conceal / rm.set_conceal_cursor.

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
-- makes the wrap engine bail out and show raw text (rendermark/wrap.lua refresh).
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

-- Window-local + global READ visuals. Kept separate from the persistent
-- per-buffer read_mode flag so they can be suspended when a non-READ buffer is
-- shown in the window (e.g. a <C-o> jump) and resumed on return. Idempotent via
-- visuals_active[win].
local function apply_visuals(buf, win)
    if visuals_active[win] then
        return
    end
    visuals_active[win] = true
    vim.wo[win].cursorline = false
    -- No cursor in READ mode, so relative numbers are meaningless: force them off
    -- (number stays as configured). Restored on suspend/exit.
    saved_relativenumber[win] = vim.wo[win].relativenumber
    vim.wo[win].relativenumber = false
    -- scrolloff keeps the (hidden, pinned) cursor a margin from the edge, which
    -- fights <C-e>/<C-y> when a wrapped line sits at the window edge (k snaps back).
    saved_scrolloff[win] = vim.wo[win].scrolloff
    vim.wo[win].scrolloff = 0
    hide_cursor()
    rm.set_anti_conceal(false)
    rm.set_conceal_cursor('nvic')
    pcall(function() wrap.refresh(win) end)
end

local function clear_visuals(win)
    if not visuals_active[win] then
        return
    end
    visuals_active[win] = nil
    if vim.api.nvim_win_is_valid(win) then
        vim.wo[win].cursorline = true
        if saved_relativenumber[win] ~= nil then
            vim.wo[win].relativenumber = saved_relativenumber[win]
        end
        if saved_scrolloff[win] ~= nil then
            vim.wo[win].scrolloff = saved_scrolloff[win]
        end
    end
    saved_relativenumber[win] = nil
    saved_scrolloff[win] = nil
    restore_cursor()
    rm.set_anti_conceal(true)
    rm.set_conceal_cursor(nil)
end

-- Reconcile the window's visuals with whether its current buffer is in READ
-- mode. Fires on buffer/window switches so a same-window <C-o> jump to a
-- non-markdown buffer suspends the visuals, and a <C-i> back resumes them.
local function sync()
    local win = vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_get_current_buf()
    for active_win in pairs(visuals_active) do
        if active_win ~= win then
            clear_visuals(active_win)
        end
    end
    if vim.b[buf].read_mode then
        apply_visuals(buf, win)
    else
        clear_visuals(win)
    end
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

    vim.b[buf].markdown_read_mode = true
    apply_visuals(buf, win)

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
    pcall(function() wrap.refresh(win) end)

    if saved_modifiable[buf] ~= nil then
        vim.bo[buf].modifiable = saved_modifiable[buf]
        saved_modifiable[buf] = nil
    else
        vim.bo[buf].modifiable = true
    end

    clear_visuals(win)
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
    -- Suspend/resume READ visuals when the window's current buffer changes.
    -- BufEnter catches same-window <C-o>/<C-i> jumps (no WinEnter fires there);
    -- WinEnter catches window switches.
    vim.api.nvim_create_autocmd({ 'BufEnter', 'WinEnter' }, {
        callback = sync,
    })

    vim.api.nvim_create_autocmd('FileType', {
        pattern = 'markdown',
        callback = function(args)
            local buf = args.buf
            ut.nnoremap('<leader>r', function() M.enter() end, { buffer = buf })
            -- Markdown opens in READ mode by default. Defer so the wrap engine and
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
