local env = require 'env'
local ut = require 'util'
local M = {}

local tab_offset = 1
local auto_scroll_next = false

local function is_tabline_ignored_buf(bufnum)
    local buftype = vim.bo[bufnum].buftype
    if buftype == 'quickfix' then return true end
    return false
end

-- IME state published by neopp (vim.g.neopp_ime); cross-platform. neopp fires
-- 'User NeoppImeChanged' on each toggle, which rebuilds the tabline (see setup).
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

function M.tab_scroll(delta)
    local total = vim.fn.tabpagenr('$')
    local new_offset = math.max(1, math.min(total, tab_offset + delta))

    if delta > 0 then
        -- Find the first offset where the last tab is visible; don't scroll past it
        local titles_w = {}
        local widths_w = {}
        for i = 1, total do
            titles_w[i] = M.tabtitle(i)
            widths_w[i] = vim.fn.strdisplaywidth(string.format(' %d %s │', i, titles_w[i]))
        end
        local session_text = vim.fn.fnamemodify(vim.v.this_session, ':p:t')
        local session_width = vim.fn.strdisplaywidth(' ' .. session_text .. ' ')
        local ime_text = neopp_ime()
        local ime_width = (ime_text ~= '') and vim.fn.strdisplaywidth(' ' .. ime_text .. ' ') or 0
        local max_offset = total
        for offset = 1, total do
            local left_ind_w = offset > 1 and 3 or 0
            local avail = vim.o.columns - session_width - ime_width - left_ind_w
            if tabline_vis_end(offset, widths_w, total, avail) >= total then
                max_offset = offset
                break
            end
        end
        new_offset = math.min(new_offset, max_offset)
    end

    tab_offset = new_offset
    vim.go.tabline = M.TabLine()
end

function M.TabLine()
    local total = vim.fn.tabpagenr('$')
    local cur = vim.fn.tabpagenr()
    tab_offset = math.max(1, math.min(total, tab_offset))
    M.tab_update()

    local titles = {}
    local widths = {}
    for i = 1, total do
        titles[i] = M.tabtitle(i)
        widths[i] = vim.fn.strdisplaywidth(string.format(' %d %s │', i, titles[i]))
    end

    local session_text = vim.fn.fnamemodify(vim.v.this_session, ':p:t')
    local session_width = vim.fn.strdisplaywidth(' ' .. session_text .. ' ')
    local ime_text = neopp_ime()
    local ime_width = (ime_text ~= '') and vim.fn.strdisplaywidth(' ' .. ime_text .. ' ') or 0

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

function M.setup()
    vim.o.showtabline = 2
    -- Set flag before TabLine() is called so auto-scroll applies on tab navigation
    vim.api.nvim_create_autocmd('TabEnter', { callback = function() auto_scroll_next = true end })
    vim.api.nvim_create_autocmd(
        {'WinEnter', 'WinLeave', 'TabEnter', 'TabLeave', 'TabClosed', 'BufNew', 'BufEnter', 'BufLeave', 'SessionLoadPost'},
        { callback = function() vim.go.tabline = M.TabLine() end }
    )
    -- neopp publishes IME state via vim.g.neopp_ime and fires this on every toggle;
    -- rebuild the tabline so the indicator updates live on the 한/영 key.
    vim.api.nvim_create_autocmd('User', {
        pattern = 'NeoppImeChanged',
        callback = function() vim.go.tabline = M.TabLine() end,
    })
    ut.set_highlight('TabLineSel', {gui = 'bold,italic'})
    ut.set_highlight('TabLineImeHangul', { guibg = '#a6e3a1', guifg = '#1e1e2e', gui = 'bold' })
    ut.set_highlight('TabLineImeEng',    { guibg = '#45475a', guifg = '#cdd6f4' })
    ut.nnoremap('<c-right>', function() M.tab_scroll(vim.v.count1) end)
    ut.nnoremap('<c-left>', function() M.tab_scroll(-vim.v.count1) end)
end

return M
