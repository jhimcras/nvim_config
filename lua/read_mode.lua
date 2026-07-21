-- READ mode: a distraction-free reading view, per window, for any buffer.
--
-- The cursor and cursorline are hidden, editing is blocked, navigation is pure
-- scrolling. Works on any filetype; when the current buffer is rendered by the
-- rendermark plugin, its raw-fallback reveals (wrap unfolding the cursor line,
-- render-markdown anti-conceal, image-link reveal, PlantUML preview) are also
-- neutralised via rendermark.wrap/rendermark.image/rendermark.rm_compat calling
-- back into M.is_active(win) -- this module has no hard dependency on
-- rendermark and must keep working with none of it loaded.
--
-- State is per WINDOW, not per buffer: the same buffer split across two windows
-- can have one in READ mode and the other in Normal mode. <leader>r toggles from
-- Normal mode; <Esc> returns to Normal. Default is always Normal -- READ mode is
-- only ever entered by explicit user action.

local ut = require 'util'
local M = {}

local win_state = {}     -- win -> { buf, saved_modifiable, saved_cursorline, saved_relativenumber, saved_scrolloff }
local mapped_bufs = {}   -- buf -> true once j/k/<Esc> are installed for that buffer
local saved_guicursor = nil
local global_applied = false -- whether guicursor/rm_compat suppression is currently ON

local function rm()
    local ok, mod = pcall(require, 'rendermark.rm_compat')
    return ok and mod or nil
end

local function wrap_refresh(win)
    local ok, wrap = pcall(require, 'rendermark.wrap')
    if ok then pcall(wrap.refresh, win) end
end

-- Like most window-id parameters in the Neovim API, 0/nil both mean "current
-- window" here -- callers (e.g. wrap.lua passing its own win parameter through)
-- may legitimately pass either.
local function resolve_win(win)
    if not win or win == 0 then
        return vim.api.nvim_get_current_win()
    end
    return win
end

function M.is_active(win)
    return win_state[resolve_win(win)] ~= nil
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

-- guicursor and render-markdown's anti-conceal/concealcursor are editor-global:
-- Neovim only ever shows one cursor, in the focused window, so gate these on
-- whether the FOCUSED window is active, not any window. Note: while the focused
-- window is reading, this briefly suppresses anti-conceal editor-wide, so an
-- unfocused Normal-mode markdown split's own cursor line won't reveal raw
-- syntax until it regains focus -- an accepted limitation of a plugin-global
-- setting, not fixable from here.
local function sync_global(win)
    win = resolve_win(win)
    local should = M.is_active(win)
    if should == global_applied then
        return
    end
    global_applied = should
    if should then
        hide_cursor()
        local m = rm()
        if m then
            m.set_anti_conceal(false)
            m.set_conceal_cursor('nvic')
        end
    else
        restore_cursor()
        local m = rm()
        if m then
            m.set_anti_conceal(true)
            m.set_conceal_cursor(nil)
        end
    end
end

local function feed(keys)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), 'n', false)
end

-- Keep the hidden cursor pinned to column 0 with no horizontal scroll: leftcol > 0
-- makes the wrap engine bail out and show raw text (rendermark/wrap.lua refresh).
-- Global, not per-buffer: only the CURRENT window's cursor is real, so this only
-- needs to check whether the focused window is active.
local function pin_current_view()
    local win = vim.api.nvim_get_current_win()
    if not M.is_active(win) then
        return
    end
    local view = vim.fn.winsaveview()
    if view.col ~= 0 or view.leftcol ~= 0 then
        view.col = 0
        view.leftcol = 0
        vim.fn.winrestview(view)
    end
end

-- j/k/<Esc> are buffer-local (Neovim has no window-local keymaps) but READ mode
-- is window-scoped, so each branches on the CURRENT window's state at call time
-- and falls through to the real motion otherwise. This correctly handles the
-- same buffer split across a READ window and a Normal window. Installed once
-- per buffer and never uninstalled -- harmless no-op outside an active window.
local function ensure_keymaps(buf)
    if mapped_bufs[buf] then
        return
    end
    mapped_bufs[buf] = true
    ut.nnoremap('j', function()
        local win = vim.api.nvim_get_current_win()
        feed(vim.v.count1 .. (M.is_active(win) and '<C-e>' or 'j'))
    end, { buffer = buf })
    ut.nnoremap('k', function()
        local win = vim.api.nvim_get_current_win()
        feed(vim.v.count1 .. (M.is_active(win) and '<C-y>' or 'k'))
    end, { buffer = buf })
    ut.nnoremap('<esc>', function()
        local win = vim.api.nvim_get_current_win()
        if M.is_active(win) then
            M.exit(win)
        else
            feed('<esc>')
        end
    end, { buffer = buf })
end

-- Snapshot + apply the current buffer's modifiable state for an active window.
-- 'modifiable' is buffer-local in Vim, so if the same buffer is split across a
-- READ window and a Normal window, blocking edits here blocks them in both --
-- an accepted limitation, not worked around (a keymap-based fake-readonly would
-- have the identical buffer-scoping problem).
local function apply_buffer(win, buf)
    local st = win_state[win]
    st.buf = buf
    st.saved_modifiable = vim.bo[buf].modifiable
    vim.bo[buf].modifiable = false
    ensure_keymaps(buf)
end

function M.enter(win)
    win = resolve_win(win)
    if M.is_active(win) or not vim.api.nvim_win_is_valid(win) then
        return
    end
    local buf = vim.api.nvim_win_get_buf(win)
    win_state[win] = {
        saved_cursorline = vim.wo[win].cursorline,
        saved_relativenumber = vim.wo[win].relativenumber,
        saved_scrolloff = vim.wo[win].scrolloff,
    }
    apply_buffer(win, buf)
    vim.wo[win].cursorline = false
    vim.wo[win].relativenumber = false
    vim.wo[win].scrolloff = 0

    vim.api.nvim_win_call(win, function()
        local view = vim.fn.winsaveview()
        view.col = 0
        view.leftcol = 0
        vim.fn.winrestview(view)
    end)

    sync_global(win)
    wrap_refresh(win)
end

function M.exit(win)
    win = resolve_win(win)
    local st = win_state[win]
    if not st then
        return
    end
    win_state[win] = nil

    if vim.api.nvim_win_is_valid(win) then
        vim.wo[win].cursorline = st.saved_cursorline
        vim.wo[win].relativenumber = st.saved_relativenumber
        vim.wo[win].scrolloff = st.saved_scrolloff
    end
    local buf = st.buf
    if buf and vim.api.nvim_buf_is_valid(buf) then
        vim.bo[buf].modifiable = st.saved_modifiable
    end

    sync_global(win)
    wrap_refresh(win)
end

function M.toggle(win)
    win = resolve_win(win)
    if M.is_active(win) then
        M.exit(win)
    else
        M.enter(win)
    end
end

function M.setup()
    local group = vim.api.nvim_create_augroup('read_mode', { clear = true })

    ut.nnoremap('<leader>r', function() M.toggle() end)

    vim.api.nvim_create_autocmd('WinEnter', {
        group = group,
        callback = function() sync_global() end,
    })

    vim.api.nvim_create_autocmd('CursorMoved', {
        group = group,
        callback = pin_current_view,
    })

    vim.api.nvim_create_autocmd('WinClosed', {
        group = group,
        callback = function(args)
            win_state[tonumber(args.match)] = nil
        end,
    })

    vim.api.nvim_create_autocmd({ 'BufDelete', 'BufWipeout' }, {
        group = group,
        callback = function(args)
            mapped_bufs[args.buf] = nil
        end,
    })

    -- READ mode persists across in-window buffer switches (:bnext, :e, ...):
    -- re-apply the buffer-side state (modifiable, keymaps) to whatever buffer
    -- now occupies an already-active window.
    vim.api.nvim_create_autocmd('BufWinEnter', {
        group = group,
        callback = function(args)
            local win = vim.api.nvim_get_current_win()
            if M.is_active(win) then
                apply_buffer(win, args.buf)
                wrap_refresh(win)
            end
        end,
    })
end

return M
