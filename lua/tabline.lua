local env = require 'env'
local ut = require 'util'
local M = {}

local tab_offset = 1
local auto_scroll_next = false
local current_tabpage = nil -- tab active as of the last TabEnter
local prev_tabpage = nil    -- tab active immediately before that

-- Cached render state; each piece is rebuilt only by the event that changes it,
-- so a frequent event (IME toggle) reuses the rest.
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

-- IME state from neopp (vim.g.neopp_ime), refreshed on 'User NeoppImeChanged'.
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

-- Single pass; the caller pre-computes the available space.
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

-- Largest offset that still shows the last tab; scrolling further would only
-- leave blank space on the left.
local function max_tab_offset(total)
    local used = 0
    local offset = total + 1
    for i = total, 1, -1 do
        local avail = vim.o.columns - session_width - ime_width - (i > 1 and 3 or 0)
        if used + widths[i] > avail then break end
        used = used + widths[i]
        offset = i
    end
    return math.min(offset, total)
end

-- Rebuild the per-tab title/width cache. Expensive (M.tabtitle walks every tab's
-- buffers and resolves project roots), so only tab-content events call it.
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

-- Assemble the tabline from the cache alone: no title recompute, no highlight
-- commands. The scroll math runs every call so overflow tracks the live width.
local function render()
    local total = vim.fn.tabpagenr('$')
    local cur = vim.fn.tabpagenr()
    -- Resync with the live tab count in case a caller skipped the title rebuild.
    if #widths ~= total then rebuild_titles() end
    tab_offset = math.max(1, math.min(total, tab_offset))

    -- Auto-scroll on gt/gT so the current tab stays visible
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

    -- Never leave room unused: pull the offset back so the tail fills the line
    tab_offset = math.min(tab_offset, max_tab_offset(total))

    -- known before visible_end is computed
    local left_cur_hidden = cur < tab_offset
    -- left indicator: " < " (3) or "< │ N │" (6 + digits)
    local left_ind_w = tab_offset > 1 and (left_cur_hidden and (6 + #tostring(cur)) or 3) or 0

    -- Pass 1: no right indicator
    local avail = vim.o.columns - session_width - ime_width - left_ind_w
    local vend_no_right = tabline_vis_end(tab_offset, widths, total, avail)

    -- Pass 2: reserve room for the right indicator on overflow
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
        new_offset = math.min(new_offset, max_tab_offset(total))
    end

    tab_offset = new_offset
    vim.go.tabline = render()
end

-- Full refresh, for callers repainting outside the autocmds (lua/session.lua).
function M.TabLine()
    rebuild_titles()
    rebuild_session()
    rebuild_ime()
    M.tab_update()
    return render()
end

function M.setup()
    -- Content changed inside tabs: titles only. Count and selection didn't move,
    -- so the highlights stand.
    local function paint_content()
        rebuild_titles()
        vim.go.tabline = render()
    end
    -- Structure/selection changed: titles + highlights.
    local function paint_tabs()
        rebuild_titles()
        M.tab_update()
        vim.go.tabline = render()
    end
    -- Session loaded: everything may have changed.
    local function paint_session()
        rebuild_session()
        rebuild_titles()
        M.tab_update()
        vim.go.tabline = render()
    end
    -- IME toggle: only the rightmost segment changes.
    local function paint_ime()
        rebuild_ime()
        vim.go.tabline = render()
    end

    -- Set before paint_tabs so auto-scroll applies. prev_tabpage is derived here
    -- rather than from TabLeave, which also fires for the tab :tabclose is closing
    -- and would clobber it with that handle right before TabClosed.
    vim.api.nvim_create_autocmd('TabEnter', { callback = function()
        auto_scroll_next = true
        prev_tabpage = current_tabpage
        current_tabpage = vim.api.nvim_get_current_tabpage()
    end })
    -- Neovim focuses the next tab after a close; go back to the previously active
    -- one instead. Guarded by current_tabpage, since closing a background tab
    -- doesn't move focus at all.
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
    -- :tabmove reorders tabs without firing any tab autocmd, so catch it from the
    -- typed command line and repaint afterwards.
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
    -- neopp fires this on every toggle; refresh just the indicator.
    vim.api.nvim_create_autocmd('User', { pattern = 'NeoppImeChanged', callback = paint_ime })
end

return M
