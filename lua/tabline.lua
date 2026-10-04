local env = require 'env'
local ut = require 'util'
local M = {}

local tab_offset = 1
local auto_scroll_next = false
local current_tabpage = nil -- tab active as of the last TabEnter
local prev_tabpage = nil    -- tab active immediately before that

-- Cached render state; each piece is rebuilt only by the event that changes it.
local titles = {}        -- per-tab display title, index 1..tabcount
local widths = {}        -- per-tab cell width incl. separators
local session_text = ''
local session_width = 0
local ime_text = ''
local ime_width = 0
local tab_cache = {} -- keyed by stable tabpage handles
local root_cache = {}

-- Rectangular tabs separated by a TabLineFill space (slanted glyphs overflow in some fonts).
local EDGE_L = ''
local EDGE_R = ' '
local EDGE_W = vim.fn.strdisplaywidth(EDGE_L .. EDGE_R)

local function is_tabline_ignored_buf(bufnum)
    local buftype = vim.bo[bufnum].buftype
    if buftype == 'quickfix' then return true end
    return false
end

-- IME state from neopp (vim.g.neopp_ime); empty outside neopp.
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
        local path = vim.fn.fnamemodify(bufname, ':p')
        local dir = vim.fn.fnamemodify(path, ':h')
        if root_cache[dir] == nil then
            root_cache[dir] = require'prjroot'.GetProjectRoot(path) or false
        end
        local pr = root_cache[dir]
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
        local edgeid = string.format('TabLineEdge%d', i)
        if i == vim.fn.tabpagenr() then
            ut.set_highlight(tabid, 'TabLineTabSel')
            ut.set_highlight(edgeid, 'TabLineTabSelEdge')
        else
            ut.set_highlight(tabid, 'TabLineTab')
            ut.set_highlight(edgeid, 'TabLineTabEdge')
        end
    end
    return ''
end

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

-- Largest offset that still shows the last tab.
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

-- Rebuild the per-tab title/width cache (expensive; tab-content events only).
local function rebuild_titles(force)
    local live = {}
    titles = {}
    widths = {}
    for i, tab in ipairs(vim.api.nvim_list_tabpages()) do
        local content = {}
        for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
            if vim.api.nvim_win_get_config(win).relative == '' then
                local buf = vim.api.nvim_win_get_buf(win)
                content[#content+1] = { buf, vim.api.nvim_buf_get_name(buf), vim.bo[buf].buftype }
            end
        end
        local cached = tab_cache[tab]
        if force or not cached or not vim.deep_equal(cached.content, content) then
            cached = { content = content, title = M.tabtitle(i) }
        end
        live[tab] = cached
        titles[i] = cached.title
        widths[i] = vim.fn.strdisplaywidth(string.format('%s %d %s %s', EDGE_L, i, titles[i], EDGE_R))
    end
    tab_cache = live
end

local function rebuild_session()
    session_text = vim.fn.fnamemodify(vim.v.this_session, ':p:t')
    session_width = vim.fn.strdisplaywidth(' ' .. session_text .. ' ')
end

local function rebuild_ime()
    ime_text = neopp_ime()
    ime_width = (ime_text ~= '') and vim.fn.strdisplaywidth(' ' .. ime_text .. ' ') or 0
end

-- Assemble the tabline from the cache; scroll math runs every call.
local function render()
    local total = vim.fn.tabpagenr('$')
    local cur = vim.fn.tabpagenr()
    -- Resync with the live tab count.
    if #widths ~= total then rebuild_titles() end
    tab_offset = math.max(1, math.min(total, tab_offset))

    -- Keep the current tab visible.
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

    -- Pull the offset back so the tail fills the line.
    tab_offset = math.min(tab_offset, max_tab_offset(total))

    -- known before visible_end is computed
    local left_cur_hidden = cur < tab_offset
    -- left indicator: " < " (3) or "< [ N ]" (4 + edges + digits)
    local left_ind_w = tab_offset > 1 and (left_cur_hidden and (4 + EDGE_W + #tostring(cur)) or 3) or 0

    -- Pass 1: no right indicator
    local avail = vim.o.columns - session_width - ime_width - left_ind_w
    local vend_no_right = tabline_vis_end(tab_offset, widths, total, avail)

    -- Pass 2: reserve room for the right indicator on overflow
    local visible_end
    if vend_no_right >= total then
        visible_end = vend_no_right
    else
        -- right indicator: " >" (2) or "[ N ] >" (4 + edges + digits)
        local right_ind_w = cur > vend_no_right and (4 + EDGE_W + #tostring(cur)) or 2
        visible_end = tabline_vis_end(tab_offset, widths, total, avail - right_ind_w)
    end

    local right_hidden = total - visible_end
    local s = {}

    if tab_offset > 1 then
        if left_cur_hidden then
            -- "< [ N ]"
            s[#s+1] = string.format('%%#MoreMsg#< %%#TabLineEdge%d#%s%%#TabLine%d# %d %%#TabLineEdge%d#%s',
                cur, EDGE_L, cur, cur, cur, EDGE_R)
        else
            s[#s+1] = '%#MoreMsg# < '
        end
    end
    for i = tab_offset, visible_end do
        s[#s+1] = string.format('%%%dT%%#TabLineEdge%d#%s%%#TabLine%d# %d %s ', i, i, EDGE_L, i, i, titles[i])
        s[#s+1] = string.format('%%#TabLineEdge%d#%s', i, EDGE_R)
    end
    if right_hidden > 0 then
        if cur > visible_end then
            -- "[ N ] >"
            s[#s+1] = string.format('%%#TabLineEdge%d#%s%%#TabLine%d# %d %%#TabLineEdge%d#%s %%#MoreMsg#>',
                cur, EDGE_L, cur, cur, cur, EDGE_R)
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

-- Full refresh, for callers outside the autocmds (session.lua).
function M.TabLine()
    root_cache = {}
    rebuild_titles(true)
    rebuild_session()
    rebuild_ime()
    M.tab_update()
    return render()
end

function M.setup()
    local pending = false
    local tabs_changed = false
    local function paint_content(after_session)
        if (vim.g.SessionLoad == 1 and after_session ~= true) or pending then return end
        pending = true
        vim.schedule(function()
            pending = false
            if vim.g.SessionLoad == 1 then return end
            rebuild_titles()
            if tabs_changed then
                M.tab_update()
                tabs_changed = false
            end
            vim.go.tabline = render()
        end)
    end
    local function paint_tabs()
        tabs_changed = true
        paint_content()
    end
    local function paint_session()
        root_cache = {}
        tab_cache = {}
        rebuild_session()
        tabs_changed = true
        paint_content(true)
    end
    -- IME toggle: only the rightmost segment changes.
    local function paint_ime()
        rebuild_ime()
        vim.go.tabline = render()
    end
    -- Resize: only render()'s scroll math depends on vim.o.columns.
    local function paint_resize()
        vim.go.tabline = render()
    end

    -- prev_tabpage is tracked here, not in TabLeave, which also fires for the tab
    -- being closed.
    vim.api.nvim_create_autocmd('TabEnter', { callback = function()
        auto_scroll_next = true
        prev_tabpage = current_tabpage
        current_tabpage = vim.api.nvim_get_current_tabpage()
    end })
    -- After closing the current tab, return to the previous one instead of the next.
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
    -- :tabmove fires no tab autocmd; catch it from the command line.
    vim.api.nvim_create_autocmd('CmdlineLeave', {
        pattern = ':',
        callback = function()
            if vim.v.event.abort then return end
            if vim.fn.getcmdline():match('^%s*tabm') then
                paint_tabs()
            end
        end,
    })
    vim.api.nvim_create_autocmd({'WinEnter', 'BufEnter', 'WinNew', 'WinClosed', 'BufFilePost'}, { callback = paint_content })
    vim.api.nvim_create_autocmd('DirChanged', { callback = function()
        root_cache = {}
        tab_cache = {}
        paint_content()
    end })
    vim.api.nvim_create_autocmd('SessionLoadPost', { callback = paint_session })
    -- Refresh just the IME indicator.
    vim.api.nvim_create_autocmd('User', { pattern = 'NeoppImeChanged', callback = paint_ime })
    vim.api.nvim_create_autocmd('VimResized', { callback = paint_resize })

    -- No TabEnter fires for the first tab, so link its highlights up front.
    M.tab_update()
end

return M
