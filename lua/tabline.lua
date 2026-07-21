local env = require 'env'
local ut = require 'util'
local M = {}

local tab_offset = 1
local auto_scroll_next = false
local current_tabpage = nil -- tab active as of the last TabEnter
local prev_tabpage = nil    -- tab active immediately before that

-- Cached render state. Each piece is rebuilt only by the event that can change
-- it (see M.setup), so frequent events (IME toggle) reuse the rest untouched.
local titles = {}        -- per-tab display title, index 1..tabcount
local widths = {}        -- per-tab cell width incl. separators
local session_text = ''
local session_width = 0
local ime_text = ''
local ime_width = 0

local function is_tabline_ignored_buf(bufnum)
    local buftype = vim.bo[bufnum].buftype
    if buftype == 'quickfix' then return true end
    return false
end

-- IME state published by neopp (vim.g.neopp_ime); cross-platform. neopp fires
-- 'User NeoppImeChanged' on each toggle, which refreshes the IME segment (see setup).
-- Empty outside neopp.
local function neopp_ime()
    local s = vim.g.neopp_ime
    if s == 'korean_hangul' then return '한'
    elseif s == 'korean_eng' then return 'A(KR)'
    elseif s == 'off'        then return 'A'
    elseif s == nil or s == '' then return ''
    else return s end
end

function M.tabtitle(n)
    local num_wins = vim.fn.tabpagewinnr(n, '$')
    local buflist = {}
    for w = 1, num_wins do
        local winid = vim.fn.win_getid(w, n)
        if vim.api.nvim_win_get_config(winid).relative == '' then
            table.insert(buflist, vim.api.nvim_win_get_buf(winid))
        end
    end
    local is_equal = function(a, b) return a == b end
    local prjroot_of = function(bufname)
        local pr = require'prjroot'.GetProjectRoot(vim.fn.fnamemodify(bufname, ':p'))
        if not pr then return end
        return vim.fn.fnamemodify(pr, ':p:h:t')
    end
    local r = {}
    for _, bufnum in ipairs(buflist) do
        if not is_tabline_ignored_buf(bufnum) then
            local bufname = vim.fn.bufname(bufnum)
            local pr = prjroot_of(bufname) or ''
            r[pr] = r[pr] or {}
            ut.insert_unique_by(r[pr], bufname, is_equal)
        end
    end
    local title = {}
    for pr, bufnames in pairs(r) do
        if pr ~= '' then
            title[#title+1] = string.format('[%s]', pr)
        end
        for _, bufname in ipairs(bufnames) do
            if bufname == '' then
                title[#title+1] = 'No Name'
            else
                if bufname:sub(bufname:len()) == env.dir_sep then
                    title[#title+1] = string.format('%s%s', vim.fn.fnamemodify(bufname, ':p:h:t'), env.dir_sep)
                else
                    title[#title+1] = vim.fn.fnamemodify(bufname, ':p:t')
                end
            end
        end
    end
    return table.concat(title, ' ')
end

function M.tab_update()
    local total_tab_number = vim.fn.tabpagenr('$')
    for i=1, total_tab_number do
        local tabid = string.format('TabLine%d', i)
        if i == vim.fn.tabpagenr() then
            ut.set_highlight(tabid, 'TabLineSel')
        else
            ut.set_highlight(tabid, 'TabLine')
        end
    end
    return ''
end

-- Single-pass visible end: avail space is pre-computed by caller
local function tabline_vis_end(offset, widths, total, avail)
    local vend = offset - 1
    local used = 0
    for i = offset, total do
        if used + widths[i] <= avail then
            used = used + widths[i]
            vend = i
        else
            break
        end
    end
    return vend
end

-- Rebuild the per-tab title/width cache. Expensive: M.tabtitle walks each tab's
-- windows/buffers and resolves project roots. Only the tab-content events call it.
local function rebuild_titles()
    local total = vim.fn.tabpagenr('$')
    titles = {}
    widths = {}
    for i = 1, total do
        titles[i] = M.tabtitle(i)
        widths[i] = vim.fn.strdisplaywidth(string.format(' %d %s │', i, titles[i]))
    end
end

local function rebuild_session()
    session_text = vim.fn.fnamemodify(vim.v.this_session, ':p:t')
    session_width = vim.fn.strdisplaywidth(' ' .. session_text .. ' ')
end

local function rebuild_ime()
    ime_text = neopp_ime()
    ime_width = (ime_text ~= '') and vim.fn.strdisplaywidth(' ' .. ime_text .. ' ') or 0
end

-- Assemble the tabline string from the cache only. Cheap: no title recompute, no
-- highlight commands. Runs the scroll/visibility math every call so overflow
-- indicators react to the live window width and IME width.
local function render()
    local total = vim.fn.tabpagenr('$')
    local cur = vim.fn.tabpagenr()
    -- Self-heal: keep the cache in sync with the live tab count in case a caller
    -- rendered without rebuilding titles first (avoids nil width indexing).
    if #widths ~= total then rebuild_titles() end
    tab_offset = math.max(1, math.min(total, tab_offset))

    -- Auto-scroll on tab navigation (gt/gT): keep current tab visible
    if auto_scroll_next then
        auto_scroll_next = false
        if cur < tab_offset then
            tab_offset = cur
        else
            local left_ind_w = tab_offset > 1 and 3 or 0
            local avail = vim.o.columns - session_width - ime_width - left_ind_w
            if cur > tabline_vis_end(tab_offset, widths, total, avail) then
                tab_offset = cur
            end
        end
    end

    -- cur < tab_offset is known before computing visible_end
    local left_cur_hidden = cur < tab_offset
    -- left indicator: " < " (3) or "< │ N │" (6 + digits)
    local left_ind_w = tab_offset > 1 and (left_cur_hidden and (6 + #tostring(cur)) or 3) or 0

    -- Pass 1: no right indicator reserved
    local avail = vim.o.columns - session_width - ime_width - left_ind_w
    local vend_no_right = tabline_vis_end(tab_offset, widths, total, avail)

    -- Pass 2: if right overflow, reserve space for right indicator
    local visible_end
    if vend_no_right >= total then
        visible_end = vend_no_right
    else
        -- right indicator: " >" (2) or " N │ >" (5 + digits)
        local right_ind_w = cur > vend_no_right and (5 + #tostring(cur)) or 2
        visible_end = tabline_vis_end(tab_offset, widths, total, avail - right_ind_w)
    end

    local right_hidden = total - visible_end
    local s = {}

    if tab_offset > 1 then
        if left_cur_hidden then
            -- "< │ N │"
            s[#s+1] = string.format('%%#MoreMsg#< %%#TabLine#│%%#TabLine%d# %d %%#TabLine#│', cur, cur)
        else
            s[#s+1] = '%#MoreMsg# < '
        end
    end
    for i = tab_offset, visible_end do
        s[#s+1] = string.format('%%#TabLine%d#%%%dT %d %s', i, i, i, titles[i])
        s[#s+1] = ' %#TabLine#│'
    end
    if right_hidden > 0 then
        if cur > visible_end then
            -- " N │ >"
            s[#s+1] = string.format('%%#TabLine%d# %d %%#TabLine#│ %%#MoreMsg#>', cur, cur)
        else
            s[#s+1] = ' %#MoreMsg#>'
        end
    end
    s[#s+1] = '%#MoreMsg#%=%#MoreMsg# ' .. session_text .. ' '

    if ime_text ~= '' then
        local hl = (ime_text == '한') and 'TabLineImeHangul' or 'TabLineImeEng'
        s[#s+1] = ('%%#%s# %s '):format(hl, ime_text)
    end

    return table.concat(s)
end

function M.tab_scroll(delta)
    rebuild_titles()
    rebuild_session()
    rebuild_ime()
    local total = vim.fn.tabpagenr('$')
    local new_offset = math.max(1, math.min(total, tab_offset + delta))

    if delta > 0 then
        -- Find the first offset where the last tab is visible; don't scroll past it
        local max_offset = total
        for offset = 1, total do
            local left_ind_w = offset > 1 and 3 or 0
            local avail = vim.o.columns - session_width - ime_width - left_ind_w
            if tabline_vis_end(offset, widths, total, avail) >= total then
                max_offset = offset
                break
            end
        end
        new_offset = math.min(new_offset, max_offset)
    end

    tab_offset = new_offset
    vim.go.tabline = render()
end

-- Full refresh: rebuild every cached piece and render. Public entry point kept
-- for external callers (lua/session.lua) that repaint outside the autocmds.
function M.TabLine()
    rebuild_titles()
    rebuild_session()
    rebuild_ime()
    M.tab_update()
    return render()
end

function M.setup()
    vim.o.showtabline = 2

    -- Content changed within tabs: rebuild titles, repaint. Highlights unchanged
    -- (tab count/selection did not move), so tab_update is skipped.
    local function paint_content()
        rebuild_titles()
        vim.go.tabline = render()
    end
    -- Tab structure/selection changed: titles + highlights, then repaint.
    local function paint_tabs()
        rebuild_titles()
        M.tab_update()
        vim.go.tabline = render()
    end
    -- Session loaded: the session name (and everything else) may have changed.
    local function paint_session()
        rebuild_session()
        rebuild_titles()
        M.tab_update()
        vim.go.tabline = render()
    end
    -- IME toggle: only the rightmost segment changes; reuse cached titles/highlights.
    local function paint_ime()
        rebuild_ime()
        vim.go.tabline = render()
    end

    -- Set flag before paint_tabs runs so auto-scroll applies on tab navigation.
    -- prev_tabpage is derived here (not from TabLeave) because TabLeave also
    -- fires for the tab being closed as part of :tabclose itself, which would
    -- clobber it with the closing tab's own handle right before TabClosed runs.
    vim.api.nvim_create_autocmd('TabEnter', { callback = function()
        auto_scroll_next = true
        prev_tabpage = current_tabpage
        current_tabpage = vim.api.nvim_get_current_tabpage()
    end })
    -- Neovim focuses the next tab by default after the active tab closes;
    -- jump back to whichever tab was active immediately before it instead.
    -- Guarded by current_tabpage so closing a background (non-current) tab,
    -- which doesn't move focus, is left untouched.
    vim.api.nvim_create_autocmd('TabClosed', {
        callback = function()
            local now = vim.api.nvim_get_current_tabpage()
            if now ~= current_tabpage and prev_tabpage and prev_tabpage ~= now
                and vim.api.nvim_tabpage_is_valid(prev_tabpage) then
                vim.cmd('tabnext ' .. vim.api.nvim_tabpage_get_number(prev_tabpage))
            end
        end,
    })
    vim.api.nvim_create_autocmd({'TabEnter', 'TabLeave', 'TabClosed'}, { callback = paint_tabs })
    -- :tabmove/:tabm reorders tabs without firing TabEnter/TabLeave/TabClosed, so the
    -- tabline goes stale; catch it via the typed command line and repaint after it runs.
    vim.api.nvim_create_autocmd('CmdlineLeave', {
        pattern = ':',
        callback = function()
            if vim.v.event.abort then return end
            if vim.fn.getcmdline():match('^%s*tabm') then
                vim.schedule(paint_tabs)
            end
        end,
    })
    vim.api.nvim_create_autocmd({'WinEnter', 'WinLeave', 'BufNew', 'BufEnter', 'BufLeave'}, { callback = paint_content })
    vim.api.nvim_create_autocmd('SessionLoadPost', { callback = paint_session })
    -- neopp publishes IME state via vim.g.neopp_ime and fires this on every toggle;
    -- refresh just the indicator so it updates live on the 한/영 key.
    vim.api.nvim_create_autocmd('User', { pattern = 'NeoppImeChanged', callback = paint_ime })

    ut.set_highlight('TabLineSel', {gui = 'bold,italic'})
    ut.set_highlight('TabLineImeHangul', { guibg = '#a6e3a1', guifg = '#1e1e2e', gui = 'bold' })
    ut.set_highlight('TabLineImeEng',    { guibg = '#45475a', guifg = '#cdd6f4' })
    ut.nnoremap('<c-right>', function() M.tab_scroll(vim.v.count1) end)
    ut.nnoremap('<c-left>', function() M.tab_scroll(-vim.v.count1) end)
end

return M
