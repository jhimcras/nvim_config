-- READ mode: a distraction-free reading view, per window, for any buffer. The
-- cursor and cursorline are hidden, editing is blocked, navigation is scrolling
-- only. <leader>r enters, <Esc> leaves; never entered implicitly.
--
-- State is per WINDOW, so one split can read a buffer while another edits it.
--
-- rendermark's raw-fallback reveals (cursor-line unwrap, image reveal, PlantUML
-- preview) call back into M.is_active(win) to suppress themselves; the dependency
-- is one-way, so this module works with none of rendermark loaded. The cursor
-- line's own conceal is handled here by raising 'concealcursor'.

local ut = require 'util'
local M = {}

local win_state = {}     -- win -> { buf, saved_modifiable, saved_cursorline, saved_relativenumber, saved_scrolloff, saved_concealcursor }
local mapped_bufs = {}   -- buf -> true once j/k/<Esc> are installed for that buffer
local saved_guicursor = nil
local global_applied = false -- whether the guicursor suppression is currently ON

local search_state = {} -- win -> { anchor = {line, col}, hl_id }
local search_ns = vim.api.nvim_create_namespace('read_mode_search')
-- True while the /, n, N pipeline parks the real cursor at the true match column
-- for one tick; pin_current_view must not clamp it away before it is read.
local resolving_search = false

local function wrap_refresh(win)
    local ok, wrap = pcall(require, 'rendermark.wrap')
    if ok then pcall(wrap.refresh, win) end
end

-- 0/nil both mean "current window", as elsewhere in the Neovim API.
local function resolve_win(win)
    if not win or win == 0 then
        return vim.api.nvim_get_current_win()
    end
    return win
end

function M.is_active(win)
    return win_state[resolve_win(win)] ~= nil
end

-- Hide the cursor by painting it in the editor background. GUI-targeted; the most
-- likely spot to need per-terminal tuning.
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

-- guicursor is editor-global and only the focused window has a cursor, so gate on
-- the FOCUSED window. ('concealcursor' is window-local; see M.enter/M.exit.)
local function sync_global(win)
    win = resolve_win(win)
    local should = M.is_active(win)
    if should == global_applied then
        return
    end
    global_applied = should
    if should then
        hide_cursor()
    else
        restore_cursor()
    end
end

local function feed(keys)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), 'n', false)
end

-- Pin the window to leftcol 0, since any horizontal scroll makes the wrap engine
-- bail out to raw text. Resetting leftcol alone doesn't hold: with 'wrap' off
-- Neovim re-derives it from the cursor column on the next redraw, so the column is
-- reset to 0 as well. Skipped while resolving_search parks the cursor at a match.
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

-- Shared endpoint for /, n, N. `pos` is where Vim's own search landed
-- {line 1-based, col 0-based}. On a long unwrapped line that column can be huge,
-- which would force leftcol > 0. So: remember the true match as this window's
-- search anchor for n/N, clamp the real column to 0, and center + highlight the
-- match's line instead.
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
            -- Match by byte offset, no cursor movement. matchstrpos returns
            -- 0-based end-exclusive indices, usable as extmark col/end_col.
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

-- Keymaps are buffer-local (Neovim has none window-local) but READ mode is
-- window-scoped, so each branches on the current window and otherwise falls
-- through to the real motion. Installed once per buffer, never uninstalled.
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
    -- Capture what <Esc> already did before shadowing it: feed('<esc>') is
    -- noremap and would never re-trigger the other mapping, so it must be invoked
    -- directly or <Esc>'s other bindings die on any buffer that entered READ mode.
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
                -- Restore the TRUE last-match position so native n/N continues from
                -- the match, not column 0. The restore itself fires CursorMoved,
                -- hence the guard.
                pcall(vim.api.nvim_win_set_cursor, win, st.anchor)
            end
            local ok = pcall(vim.cmd, 'normal! ' .. vim.v.count1 .. cmd)
            local pos = vim.api.nvim_win_get_cursor(win)
            resolving_search = false
            if ok then
                -- Deferred so foreign plugins scheduling off the same CursorMoved
                -- run first; otherwise collect_deco snapshots before their
                -- highlights exist.
                vim.schedule(function()
                    resolve_match(win, pos)
                end)
            end
        end
    end
    ut.nnoremap('n', search_repeat('n'), { buffer = buf })
    ut.nnoremap('N', search_repeat('N'), { buffer = buf })
end

-- Snapshot + apply the buffer's modifiable state. 'modifiable' is buffer-local, so
-- a buffer split across a READ and a Normal window is blocked in both -- accepted.
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
        saved_concealcursor = vim.wo[win].concealcursor,
    }
    -- Window-local flag other modules can read without requiring this one.
    vim.w[win].read_mode_active = true
    apply_buffer(win, buf)
    vim.wo[win].cursorline = false
    vim.wo[win].relativenumber = false
    vim.wo[win].scrolloff = 0
    -- Conceal the cursor's line too: the cursor is hidden, so every line should
    -- render, matching the cursor_row sentinel wrap uses for READ windows.
    vim.wo[win].concealcursor = 'nvic'

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
        vim.wo[win].concealcursor = st.saved_concealcursor or ''
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

    -- The jump happens after the cmdline closes, not inside this callback, so
    -- defer a tick before reading the resulting cursor position.
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

    -- READ mode survives buffer switches, so re-apply the buffer-side state
    -- (modifiable, keymaps) to whatever buffer the active window now holds.
    vim.api.nvim_create_autocmd('BufWinEnter', {
        group = group,
        callback = function(args)
            local win = vim.api.nvim_get_current_win()
            if M.is_active(win) then
                -- The stored anchor/highlight belonged to the previous buffer.
                clear_search_highlight(win)
                search_state[win] = nil
                apply_buffer(win, args.buf)
                wrap_refresh(win)
            end
        end,
    })
end

return M
