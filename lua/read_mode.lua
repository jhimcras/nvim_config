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

local search_state = {} -- win -> { anchor = {line, col}, hl_id }
local search_ns = vim.api.nvim_create_namespace('read_mode_search')
-- True while the /, n, N pipeline below is deliberately parking the real
-- cursor at the true (possibly far-right) match column for one tick so it can
-- capture it before clamping back to column 0 itself -- pin_current_view must
-- not clobber that column out from under it first.
local resolving_search = false

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

-- Keep the window pinned to no horizontal scroll: leftcol > 0 makes the wrap
-- engine bail out and show raw text (rendermark/wrap.lua refresh). Resetting
-- leftcol alone doesn't hold: with 'wrap' off, Neovim's redraw invariant
-- re-derives leftcol from the real cursor's column on the very next redraw,
-- so a leftcol-only reset just gets overwritten again when the column itself
-- is still off past the window's right edge. Reset col back to 0 too so
-- there's nothing left for that invariant to react to. Skipped while
-- resolving_search is true: the /, n, N pipeline deliberately parks the real
-- cursor at the true match column for one tick and needs to read it before
-- this clamps it away.
-- Global, not per-buffer: only the CURRENT window's cursor is real, so this only
-- needs to check whether the focused window is active.
local function pin_current_view()
    if resolving_search then
        return
    end
    local win = vim.api.nvim_get_current_win()
    if not M.is_active(win) then
        return
    end
    local view = vim.fn.winsaveview()
    if view.leftcol ~= 0 then
        view.leftcol = 0
        view.col = 0
        vim.fn.winrestview(view)
    end
end

local function clear_search_highlight(win)
    local st = search_state[win]
    if st and st.hl_id and st.buf and vim.api.nvim_buf_is_valid(st.buf) then
        pcall(vim.api.nvim_buf_del_extmark, st.buf, search_ns, st.hl_id)
    end
end

-- Shared endpoint for /, n, N once we know the true outcome of a native
-- search jump. `pos` is the real {line (1-based), col (0-based)} Vim's own
-- search landed on. On a long real line (rendermark/wrap.lua keeps it one
-- long 'nowrap' line and renders wrapping via virt_lines) this column can be
-- arbitrarily large -- showing it would force leftcol > 0 (never allowed
-- here) or land the invisible real cursor in the wrapped-overflow region.
-- Instead: remember the true match as this window's own search anchor
-- (independent of the real, column-clamped cursor) for n/N to consult, clamp
-- the real column back to 0, and vertically center + highlight the match's
-- line instead of showing its real column.
local function resolve_match(win, pos)
    if not vim.api.nvim_win_is_valid(win) then
        return
    end
    local buf = vim.api.nvim_win_get_buf(win)
    clear_search_highlight(win)
    search_state[win] = { anchor = { pos[1], pos[2] }, buf = buf }

    vim.api.nvim_win_set_cursor(win, { pos[1], 0 }) -- leftcol never needs to move again
    vim.api.nvim_win_call(win, function() vim.cmd('normal! zz') end)

    local pattern = vim.fn.getreg('/')
    if pattern ~= '' then
        local line = vim.api.nvim_buf_get_lines(buf, pos[1] - 1, pos[1], false)[1]
        if line then
            -- Cursor-independent: matches by byte offset directly, no transient
            -- cursor movement. matchstrpos returns 0-based, end-exclusive byte
            -- indices, directly usable as extmark col/end_col.
            local ok, m = pcall(vim.fn.matchstrpos, line, pattern, pos[2])
            if ok and m[2] ~= -1 then
                local hl_id = vim.api.nvim_buf_set_extmark(buf, search_ns, pos[1] - 1, m[2], {
                    end_col = m[3],
                    hl_group = 'IncSearch',
                })
                search_state[win].hl_id = hl_id
            end
        end
    end
    wrap_refresh(win)
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
    -- Capture whatever <Esc> already did (e.g. init.lua's global float-close
    -- + :nohlsearch binding) before shadowing it with this buffer-local map.
    -- A plain feed('<esc>') below would be fed non-recursively (noremap) and
    -- so would never re-trigger that other mapping -- it has to be invoked
    -- directly instead, or <Esc>'s other bindings silently stop working on
    -- any buffer that ever entered READ mode, even after exiting it.
    local prev_esc = vim.fn.maparg('<esc>', 'n', false, true)
    ut.nnoremap('<esc>', function()
        local win = vim.api.nvim_get_current_win()
        if M.is_active(win) then
            M.exit(win)
        elseif prev_esc.callback then
            prev_esc.callback()
        elseif prev_esc.rhs and prev_esc.rhs ~= '' then
            feed(prev_esc.rhs)
        else
            feed('<esc>')
        end
    end, { buffer = buf })

    local function search_repeat(cmd)
        return function()
            local win = vim.api.nvim_get_current_win()
            if not M.is_active(win) then
                feed(vim.v.count1 .. cmd)
                return
            end
            local st = search_state[win]
            resolving_search = true
            if st and st.anchor then
                -- Restore the TRUE last-match position (not the column-clamped
                -- real cursor) so native n/N continuation searches from where
                -- the match actually was, not from column 0. This restore is
                -- itself a CursorMoved-firing move, hence the guard around it.
                pcall(vim.api.nvim_win_set_cursor, win, st.anchor)
            end
            local ok = pcall(vim.cmd, 'normal! ' .. vim.v.count1 .. cmd)
            local pos = vim.api.nvim_win_get_cursor(win)
            resolving_search = false
            if ok then
                -- Deferred, not called inline: foreign plugins reacting to the
                -- same CursorMoved (e.g. render-markdown's checkbox highlight,
                -- which recomputes via its own vim.schedule) need a chance to
                -- run first, or wrap_refresh's collect_deco can snapshot the
                -- buffer's extmarks before that highlight exists yet.
                vim.schedule(function()
                    resolve_match(win, pos)
                end)
            end
        end
    end
    ut.nnoremap('n', search_repeat('n'), { buffer = buf })
    ut.nnoremap('N', search_repeat('N'), { buffer = buf })
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
    -- Window-local flag other modules (rendermark/wrap.lua, rendermark/image.lua)
    -- can read without requiring this module, so read_mode stays decoupled from them.
    vim.w[win].read_mode_active = true
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
        vim.w[win].read_mode_active = nil
    end
    local buf = st.buf
    if buf and vim.api.nvim_buf_is_valid(buf) then
        vim.bo[buf].modifiable = st.saved_modifiable
    end
    clear_search_highlight(win)
    search_state[win] = nil

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

    vim.api.nvim_create_autocmd('WinEnter', {
        group = group,
        callback = function() sync_global() end,
    })

    vim.api.nvim_create_autocmd('CursorMoved', {
        group = group,
        callback = pin_current_view,
    })

    -- '/' and '?' jump as ordinary normal-mode processing right after the
    -- cmdline closes, not synchronously within this callback, so defer the
    -- handoff a tick to be sure the native jump has already landed before we
    -- read the resulting cursor position.
    vim.api.nvim_create_autocmd('CmdlineLeave', {
        group = group,
        pattern = { '/', '?' },
        callback = function()
            if vim.v.event.abort then
                return
            end
            local win = vim.api.nvim_get_current_win()
            if not M.is_active(win) then
                return
            end
            resolving_search = true
            vim.schedule(function()
                resolving_search = false
                if vim.api.nvim_win_is_valid(win) then
                    resolve_match(win, vim.api.nvim_win_get_cursor(win))
                end
            end)
        end,
    })

    vim.api.nvim_create_autocmd('WinClosed', {
        group = group,
        callback = function(args)
            local win = tonumber(args.match)
            win_state[win] = nil
            search_state[win] = nil
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
                -- Any stored anchor/highlight belonged to the previous buffer
                -- in this window, not the one that just took its place.
                clear_search_highlight(win)
                search_state[win] = nil
                apply_buffer(win, args.buf)
                wrap_refresh(win)
            end
        end,
    })
end

return M
