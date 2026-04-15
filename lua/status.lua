local env = require 'env'
local ut = require 'util'
local M = {}

local tab_offset = 1
local auto_scroll_next = false

-- M.start_active_time = 0

local function GetModeColor(mode)
    local mode_color = {
        -- Normal = { bg = { '#70ace5', '#26394d' }, fg = { '#212121', '#b7bdc0' } };
        Normal = { bg = { '#334155', '#1F2937' }, fg = { '#D1D5DB', '#9CA3AF'} };
        -- Insert = { bg = { '#87bb7c', '#374D33' }, fg = { '#212121', '#b7bdc0' } };
        Insert = { bg = { '#98BC99', '#1F2937' }, fg = { '#111827', '#98BC99' } };
        -- Visual = { bg = { '#d7956e', '#4D3527' }, fg = { '#212121', '#b7bdc0' } };
        Visual = { bg = { '#FBC19D', '#1F2937' }, fg = { '#111827', '#FBC19D' } };
        None = { bg = { '#b7bdc0', '#494C4D' }, fg = { '#212121', '#b7bdc0' } };
        Command = { bg = { '#99BBBD', '#1F2937' }, fg = { '#111827', '#99BBBD' } };
        Replace = { bg = { '#E8D4B0', '#1F2937' }, fg = { '#111827', '#E8D4B0' } };
        -- Quickfix = { bg = { '#FF0000', '#FF0000' }, fg = { '#111827', '#E8D4B0' } };
        -- Terminal = {};
    }
    -- mode_color.Command = mode_color.Normal
    mode_color.Terminal = mode_color.Insert
    return mode_color[mode] or mode_color.None
end

function M.get_current_mode(buftype)
    local leading_charater_of_current_mode = string.sub(vim.fn.mode(), 1, 1)
    local mode = {
        n = 'Normal',
        c = 'Command',
        i = 'Insert',
        R = 'Replace',
        v = 'Visual', V = 'Visual', ['^V'] = 'Visual',
        s = 'Select', S = 'Select', ['^S'] = 'Select',
        t = 'Terminal',
        r = 'None', ['!'] = 'None',
    }
    local buf_mode = {
        quickfix = 'Quickfix',
    }
    return buf_mode[buftype] or mode[leading_charater_of_current_mode] or ''
end

function M.status_update()
    -- M.start_active_time = vim.uv.hrtime()
    local color = GetModeColor(M.get_current_mode(vim.bo.buftype))
    ut.set_highlight('StatusLineMode', {guibg = color.bg[1], guifg = color.fg[1]})
    ut.set_highlight('StatusLineNormal', {guibg = color.bg[2], guifg = color.fg[2]})
    return ''
end

local function terminalinfo()
    local buf_name = ut.GetCurrentBufferDir()
    local term_cmd = string.sub(buf_name, vim.fn.match(buf_name, [[\v\:\zs[^:]+$]])+1)
    return '   TERM │ ' .. (term_cmd or '')
end

local function helpinfo()
    local buf_name = ut.GetCurrentBufferDir()
    local help_file_regex = [[\v\/\zs[^/]+\ze\.txt$]]
    local s = vim.fn.match(buf_name, help_file_regex)+1
    local e = vim.fn.matchend(buf_name, help_file_regex)
    local help_file_name = string.sub(buf_name, s, e)
    return 'HELP │ ' .. (help_file_name or '')
end

local spinner_frames = { '⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏' }

local function launcher_status_icon(bufnr, winid)
    local b = bufnr and vim.b[bufnr] or vim.b
    local status = b.launcher_status
    if status == 'running' then
        return spinner_frames[(math.floor(vim.uv.now() / 120) % #spinner_frames) + 1]
    elseif status == 'done' then
        return '✓'
    elseif status == 'terminated' then
        return '✗'
    end
    return ''
end

local function grep_status_icon(bufnr, winid)
    local gs = vim.w[winid] and vim.w[winid].grep_status
    if gs == 'searching' then
        return spinner_frames[(math.floor(vim.uv.now() / 120) % #spinner_frames) + 1]
    elseif gs == 'done' then
        return '✓'
    elseif gs == 'killed' then
        return '✗'
    end
    return ''
end


local function launcher_folder(bufnr)
    local b = bufnr and vim.b[bufnr] or vim.b
    return b.prjroot_folder or '?'
end

local function launcher_folder_compact(bufnr)
    local b = bufnr and vim.b[bufnr] or vim.b
    local folder = b.prjroot_folder
    return folder and vim.fn.fnamemodify(folder, ':t') or '?'
end

local function launcher_command(bufnr)
    local b = bufnr and vim.b[bufnr] or vim.b
    return b.lc_command or b.lc_object or '?'
end

local function launcher_info(bufnr, winid)
    local icon = launcher_status_icon(bufnr, winid)
    local icon_str = (icon and icon ~= '') and (icon .. ' ') or ''
    return string.format('%s%s %s', icon_str, launcher_folder_compact(bufnr), launcher_command(bufnr))
end

local function quickfix()
    return vim.w.quickfix_title
end

local types = {
    { bt = 'terminal', info = terminalinfo },
    { bt = 'help', info = helpinfo },
    { ft = 'launcher', info = launcher_info },
    { bt = 'quickfix', info = quickfix },
}

function M.lsp()
    if next(vim.lsp.get_clients()) ~= nil then
        return require'lsp-status'.status()
    end
    return ''
end

function M.fcitx()
    local check_proc = io.popen('fcitx-remote')
    return (check_proc and check_proc:read() == '2') and ' 한' or ''
end

function M.session()
    return vim.fn.fnamemodify(vim.v.this_session,':p:t')
end


local function is_tabline_ignored_buf(bufnum)
    local buftype = vim.bo[bufnum].buftype
    if buftype == 'quickfix' then return true end
    return false
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


function M.current_function(bufnr, winid)
    local ts_utils_loadded, ts_utils = pcall(require, "nvim-treesitter.ts_utils")
    if ts_utils_loadded then
        local node = ts_utils.get_node_at_cursor()
        if not node then return "" end

        while node do
            local ntype = node:type()

            if ntype == "function_definition" or ntype == "function_declaration" then
                -- Python / Lua: function name directly in 'name' field
                local name_node = node:field("name")[1]
                if name_node then
                    local name_type = name_node:type()
                    if name_type == "identifier" then
                        return vim.treesitter.get_node_text(name_node, 0)
                    elseif name_type == "dot_index_expression" then
                        local table = name_node:field("table")[1]
                        local field = name_node:field("field")[1]
                        if table and field then
                            return vim.treesitter.get_node_text(table, 0)
                                .. "." .. vim.treesitter.get_node_text(field, 0)
                        end
                    end
                end

                -- C / C++: function name in declarator
                local decl = node:field("declarator")[1]
                if decl then
                    local inner = decl:field("declarator")[1]
                    if inner then
                        local itype = inner:type()

                        if itype == "qualified_identifier" then
                            local scope = inner:field("scope")[1]
                            local name = inner:field("name")[1]
                            if scope and name then
                                return vim.treesitter.get_node_text(scope, 0)
                                    .. "::" .. vim.treesitter.get_node_text(name, 0)
                            end
                        elseif itype == "field_identifier" then
                            return vim.treesitter.get_node_text(inner, 0)
                        end
                    end
                end
            end

            node = node:parent()
        end
    end

    return ""
end

local function branch_or_commit(dir)
    local branch, commit = require'git'.git_branch_commit(dir)
    if branch and branch ~= 'HEAD' then
        return branch
    end
    return commit and commit:sub(1, 10)
end

function M.leftside()
    local extends = vim.list_extend
    for _, t in ipairs(types) do
        if (t.bt and vim.bo.buftype == t.bt) or (t.ft and vim.bo.filetype == t.ft) then
            return t.info()
        end
    end
    local pr = require'prjroot'.GetCurrentProjectRoot()
    local gb = nil
    local fi = {}
    if pr then
        if pr ~= '' then
            -- gb = vim.fn.exists'*FugitiveHead' == 1 and vim.fn.FugitiveHead() or ''
            gb = branch_or_commit(pr)
            if gb and gb ~= '' then
                extends(fi, { ' ', gb, ' │ ' })
            end
        end
        if vim.fn.fnamemodify(pr, ':t') ~= gb then
            extends(fi, { '🖿 ', vim.fn.fnamemodify(pr, ':t'), ' │ ' })
        end
    end
    if vim.bo.fileencoding ~= 'utf-8' and vim.bo.fileencoding ~= '' then
        extends(fi, { vim.bo.fileencoding, ' │ ' })
    end
    if vim.bo.bomb then
        extends(fi, {'BOM │ '})
    end
    local buf_name = vim.api.nvim_buf_get_name(0)
    if env.os.win then
        buf_name = buf_name:gsub("/", "\\")
    end
    if pr then
        extends(fi, { '🗎', '.' .. buf_name:sub(pr:len()+1) })
    else
        extends(fi, (buf_name ~= '') and { '🗎', buf_name } or { 'No Name' } )
    end
    extends(fi, {
        vim.bo.modified and ' +' or '',
        vim.bo.readonly and ' ' or '',
        not vim.bo.modifiable and ' -'  or '',
    })
    local cur_func = M.current_function()
    if cur_func and cur_func ~= '' then
        extends(fi, {' │ ℱ ', cur_func})
    end
    return table.concat(fi)
end

if env.os.win then
    local ffi = require("ffi")

    ffi.cdef[[
        void* GetForegroundWindow(void);
        void* GetParent(void* hWnd);
        unsigned int GetWindowThreadProcessId(void* hWnd, unsigned int* lpdwProcessId);
        void* ImmGetContext(void* hWnd);
        int ImmGetOpenStatus(void* hIMC);
    ]]

    local user32 = ffi.load("user32")
    local imm32 = ffi.load("imm32")

    local function get_hwnd()
        local fg = user32.GetForegroundWindow()
        local parent = user32.GetParent(fg)
        if parent ~= nil then
            return parent -- use parent if exists
        else
            return fg
        end
    end

    function M.GetIMEStatus()
        local hwnd = get_hwnd()
        if hwnd == nil then return "?hwnd" end

        local himc = imm32.ImmGetContext(hwnd)
        if himc == nil then return "?himc" end

        local status = imm32.ImmGetOpenStatus(himc)
        if status == 1 then
            return "한"  -- Hangul mode
        else
            return "A"   -- English mode
        end
    end
else
    function M.GetIMEStatus() return "" end
end

function M.search_result()
    -- M.duration_active = vim.uv.hrtime() - M.start_active_time
    if vim.v.hlsearch == 0 then
        return ''
    end

    -- M.duration_active = vim.uv.hrtime() - M.start_active_time
    local ok, searchcount = pcall(vim.fn.searchcount, { maxcount = 99999, timeout = 100 })
    if not ok or searchcount.total == 0 then
        return ''
    end

    -- M.duration_active = vim.uv.hrtime() - M.start_active_time
    return string.format('  %d/%d', searchcount.current, searchcount.total)
end

-- function M.dur()
--     return string.format("%d", M.duration_active)
-- end

function M.ActiveWin()
    -- return "%!v:lua.require'status'.LeftTest()"

    local sl = {
        "%{v:lua.require'status'.status_update()}",
        "%(%#StatusLineNormal# %{v:lua.require'status'.leftside()} %)",
        "%=",
        "%{v:lua.require'status'.lsp()}",
        -- (env.os.unix) and "%(%#StatusLineMode#%{v:lua.require'status'.fcitx()}%)" or '',
        -- (env.os.win) and "%(%#StatusLineMode#%{v:lua.require'status'.GetIMEStatus()}%)" or '',
        "%(%#StatusLineMode# %{v:lua.require'status'.search_result()}%)",
        "%(%#StatusLineMode# %p%% %c %)",
        -- "%{v:lua.require'status'.dur()}",
    }
    return table.concat(sl)
end

function M.InactiveWin()
    return "%(%#StatusLineInactive# %{v:lua.require'status'.leftside()}%)"
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
        local max_offset = total
        for offset = 1, total do
            local left_ind_w = offset > 1 and 3 or 0
            local avail = vim.o.columns - session_width - left_ind_w
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

    -- Auto-scroll on tab navigation (gt/gT): keep current tab visible
    if auto_scroll_next then
        auto_scroll_next = false
        if cur < tab_offset then
            tab_offset = cur
        else
            local left_ind_w = tab_offset > 1 and 3 or 0
            local avail = vim.o.columns - session_width - left_ind_w
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
    local avail = vim.o.columns - session_width - left_ind_w
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

    return table.concat(s)
end

local function project_or_git_branch_name(bufnr, winid)
    local pr = require'prjroot'.GetProjectRoot(ut.GetBufferDir(bufnr))
    if pr then
        local fi = {}
        local git_branch = nil
        if pr ~= '' then
            git_branch = branch_or_commit(pr)
            if git_branch and git_branch ~= '' then
                fi[#fi+1] = (' %s'):format(git_branch)
            end
        end
        local project_folder_name = vim.fn.fnamemodify(pr, ':t')
        if project_folder_name ~= git_branch then
            fi[#fi+1] = ('🖿 %s'):format(project_folder_name)
        end
        return fi
    end
end


local function encoding(bufnr, winid)
    local fe = vim.bo[bufnr].fileencoding
    local bom = vim.bo[bufnr].bomb and ' bom' or ''
    -- local bom = vim.bo[bufnr].bomb and 'ﮏ' or ''
    -- return (fe ~= '' and fe ~= 'utf-8') and (fe .. bom) or (bom ~= '' and bom or nil)
    return fe .. bom
end


local function filename_only(bufnr)
    local name = vim.api.nvim_buf_get_name(bufnr)
    return vim.fn.fnamemodify(name, ':t:r')
end


local function filename_and_status(bufnr, winid)
    local buf_name, protocol = ut.GetBufferName(bufnr)
    if protocol == 'oil' then
        if env.os.win then
            buf_name = buf_name:gsub('^/(%a)/', '%1:/')
            buf_name = buf_name:gsub('\\', '/')
        else
            local home = os.getenv('HOME')
            if home and buf_name:sub(1, #home) == home then
                buf_name = '~' .. buf_name:sub(#home + 1)
            end
        end
    end
    if env.os.win then
        buf_name = buf_name:gsub('\\', '/')
    end
    local is_dir = buf_name:sub(buf_name:len()) == '/'
    local filename
    local fileicon = is_dir and ' ' or '🗎'
    local pr = require'prjroot'.GetProjectRoot(buf_name)
    if pr and not is_dir then
        local bname = buf_name:sub(pr:len()+2)
        if bname == '' then return '' end
        filename = ('%s%s'):format(fileicon, bname)
    else
        if buf_name ~= '' then
            filename = ('%s%s'):format(fileicon, buf_name)
        else
            filename = 'No Name'
        end
    end
    local file_status = ('%s%s%s'):format(
        vim.bo[bufnr].modified and ' ' or '',
        vim.bo[bufnr].readonly and '' or '',
        not vim.bo[bufnr].modifiable and '-'  or '')
    return filename .. (file_status ~= '' and (' ' .. file_status) or '')
end


local function filename_and_status_compact(bufnr, winid)
    local bufname = vim.api.nvim_buf_get_name(bufnr)
    local name = bufname ~= '' and vim.fn.fnamemodify(bufname, ':t') or 'No Name'
    local mods = (vim.bo[bufnr].modified and ' ' or '')
               .. (vim.bo[bufnr].readonly and '' or '')
               .. (not vim.bo[bufnr].modifiable and '-' or '')
    return name .. (mods ~= '' and (' ' .. mods) or '')
end


local function current_function(bufnr, winid)
    local curfunc =  M.current_function()
    if curfunc and curfunc ~= '' then
        return 'ℱ ' .. curfunc
    end
end


local function lsp_status(bufnr, winid)
    if next(vim.lsp.get_clients{bufnr = bufnr}) ~= nil then
        return vim.trim(require'lsp-status'.status())
    end
end


local function search_count(bufnr, winid)
    if vim.v.hlsearch == 0 then return end

    local winids = vim.fn.win_findbuf(bufnr)
    if #winids == 0 then return end

    local searchcount = vim.api.nvim_win_call(winids[1], function()
        return {pcall(vim.fn.searchcount, { maxcount = 999999, timeout = 1000 })}
    end)
    if not searchcount[1] or searchcount[2].total == 0 then return end

    return ('  %d/%d'):format(searchcount[2].current, searchcount[2].total)
end


-- local cache = {}
-- local function search_count(bufnr, winid)
--     if vim.v.hlsearch == 0 then return end
--
--     local winids = vim.fn.win_findbuf(bufnr)
--     if #winids == 0 then return end
--
--     local function run_scan(timeout, maxcount, pos)
--         return vim.api.nvim_win_call(winids[1], function()
--             return { pcall(vim.fn.searchcount, {
--                 timeout = timeout or 20,
--                 maxcount = maxcount or 500,
--                 pos = pos,
--             }) }
--         end)
--     end
--
--     -- first quick scan
--     local sc = run_scan(20, 500)
--     if not sc[1] or sc[2].total == 0 then return end
--
--     cache[bufnr] = sc[2]
--
--     if sc[2].incomplete ~= 0 then
--         local function recompute(prev_pos)
--             local sc2 = run_scan(50, 5000, prev_pos)
--             if sc2[1] and sc2[2].total > 0 then
--                 cache[bufnr] = sc2[2]
--                 if sc2[2].incomplete ~= 0 then
--                     -- resume from last scanned position
--                     local next_pos = { 0, sc2[2].last_line or 1, sc2[2].last_column or 1, 0 }
--                     vim.defer_fn(function()
--                         recompute(next_pos)
--                     end, 50)
--                 end
--                 vim.cmd("redrawstatus") -- final refresh
--             end
--         end
--
--         vim.defer_fn(function() recompute(nil) end, 50)
--     end
--
--     local result = cache[bufnr]
--     if not result then return end
--
--     local total = result.incomplete ~= 0 and "??" or tostring(result.total)
--     local current = result.current or 0
--     return ('  %d/%s'):format(current, total)
-- end

--- Mark a component as shrinkable.
--- priority: 1=first to shrink (most expendable), 10=last to shrink (most critical)
--- compact: optional function(bufnr,winid)->string for compact rendering; nil=remove
local function sh(fn, priority, compact)
    return { __sh = true, fn = fn, priority = priority, compact = compact }
end

local function measure_sl_text(s)
    s = s:gsub('%%#[^#]*#', '')   -- strip %#HighlightGroup# codes
    s = s:gsub('%%p%%%%', '100')  -- %p%% -> percentage estimate
    s = s:gsub('%%c', '999')      -- %c -> column estimate
    s = s:gsub('%%[lL]', '9999') -- %l/%L -> line estimate
    s = s:gsub('%%[<=]', '')      -- %< and %= are zero-width separators
    s = s:gsub('%%%%', '%%')      -- %% -> literal %
    return vim.fn.strdisplaywidth(s)
end

local percentage_loc = '%p%%'
local column_loc = 'ﮇ %c'
local gap = '%<%='


local function fugitive_info(bufnr, winid)
    local info = require'git'.get_fugitive_info(bufnr)
    if not info then return 'Fugitive' end

    if info.type == 'summary' then
        return {
            'Git status',
            info.cwd,
            info.head,
            info.upstream,
            info.ab,
            sep = ' │ '
        }
    elseif info.type == 'blob' then
        return { 'Git blob', info.obj, info.file, sep = ' │ ' }
    elseif info.type == 'diff' then
        return { 'Git diff', info.file, sep = ' │ ' }
    end
    return 'Fugitive'
end

local function fugitive_info_compact(bufnr, winid)
    local info = require'git'.get_fugitive_info(bufnr)
    if not info then return 'FUG' end

    if info.type == 'summary' then
        return 'SUM │ ' .. info.head
    elseif info.type == 'blob' then
        local obj_map = { INDEX = 'IDX', OURS = 'OUR', THEIRS = 'THE', BASE = 'BASE' }
        return (obj_map[info.obj] or info.obj:sub(1, 4)) .. ' │ ' .. info.file
    elseif info.type == 'diff' then
        return 'DIF │ ' .. info.file
    end
    return 'FUG'
end

local function quickfix_search_query(bufnr, winid)
    -- Read title directly from loclist data via filewinid, bypassing w:quickfix_title
    -- which Neovim sets with incorrect timing when lopen splits an existing loclist window.
    local title
    local filewinid = vim.fn.getloclist(winid, { filewinid = 0 }).filewinid
    if filewinid and filewinid ~= 0 then
        title = vim.fn.getloclist(filewinid, { title = 0 }).title
    else
        title = vim.w[winid].quickfix_title
    end
    if not title then return end
    local chain = require'grep'.get_filter_chain(winid)
    if not chain or #chain == 0 then return title end
    local MAX_CHAIN = 25
    local visible = {}
    for i, v in ipairs(chain) do visible[i] = v end
    local hidden = 0
    while #table.concat(visible, ' → ') > MAX_CHAIN and #visible > 1 do
        table.remove(visible, 1)
        hidden = hidden + 1
    end
    local chain_str = ' → ' .. (hidden > 0 and ('(+' .. hidden .. ') ') or '') .. table.concat(visible, ' → ')
    local before, sep_and_after = title:match('^(.-)( │ .+)$')
    if before then
        return before .. chain_str .. sep_and_after
    end
    return title .. chain_str
end


local function quickfix_search_query_compact(bufnr, winid)
    local title
    local filewinid = vim.fn.getloclist(winid, { filewinid = 0 }).filewinid
    if filewinid and filewinid ~= 0 then
        title = vim.fn.getloclist(filewinid, { title = 0 }).title
    else
        title = vim.w[winid].quickfix_title
    end
    return title or ''
end

local function loclist_tag(bufnr, winid)
    local tag = vim.w[winid] and vim.w[winid].loclist_tag
    if not tag then return end
    return ('%#StatuslineTag' .. tag .. '#  ')
end


local function make_statusline_text(bufnr, winid, components, sep, ctx)
    sep = sep or ''
    if components == nil then return '' end

    if type(components) == 'string' then
        return components
    elseif type(components) == 'number' then
        return tostring(components)
    elseif type(components) == 'function' then
        local res = components(bufnr, winid)
        if res == nil then return '' end
        return make_statusline_text(bufnr, winid, res, sep, ctx)
    elseif type(components) == 'table' and components.__sh then
        if ctx then
            ctx.order = ctx.order + 1
            ctx.candidates[#ctx.candidates + 1] = {
                fn       = components.fn,
                priority = components.priority,
                compact  = components.compact,
                order    = ctx.order,
            }
        end
        local active
        if ctx and ctx.excluded[components.fn] then
            active = components.compact
        else
            active = components.fn
        end
        if active == nil then return '' end
        return make_statusline_text(bufnr, winid, active, sep, ctx)
    elseif type(components) == 'table' then
        sep = components.sep or sep
        local pad = components.pad or ''
        local hl = components.hl and ("%%#%s#"):format(components.hl) or ""
        local t = {}
        for _, c in ipairs(components) do
            -- Only process if it's a type we support as a statusline component
            if type(c) == 'string' or type(c) == 'number' or type(c) == 'function' or type(c) == 'table' then
                local c_str = make_statusline_text(bufnr, winid, c, sep, ctx)
                if c_str and c_str ~= '' then
                    t[#t+1] = c_str
                end
            end
        end
        if #t == 0 then return '' end
        for i, s in ipairs(t) do
            t[i] = hl .. (i == 1 and pad or '') .. s .. (i == #t and pad or '') .. hl
        end
        return table.concat(t, sep)
    end
    return ''
end


local function general_statusline(activation, mode, winid)
    local hl = function(num)
        return 'StatuslineGeneral' .. (activation and ('Active_%d_%s'):format(num, mode) or 'Inactive')
    end
    local proj_or_git_branch_memoized          = ut.memoize_ttl(project_or_git_branch_name,  {ttl_ms=1000})
    local filename_and_status_memoized         = ut.memoize_ttl(filename_and_status,          {ttl_ms=300})
    local filename_and_status_compact_memoized = ut.memoize_ttl(filename_and_status_compact,  {ttl_ms=300})
    local encoding_memoized                    = ut.memoize_ttl(encoding,                     {ttl_ms=2000})
    local current_function_memoized            = ut.memoize_ttl(current_function,             {ttl_ms=200})
    return {
        {
            sh(proj_or_git_branch_memoized, 9),
            sh(filename_and_status_memoized, 1, filename_and_status_compact_memoized),
            activation and sh(lsp_status, 2) or false,
            hl = hl(1), sep = ' │ ', pad = ' '
        },
        gap,
        {
            activation and sh(current_function_memoized, 3) or false,
            sh(encoding_memoized, 4),
            hl = hl(1), sep = ' │ ', pad = ' '
        },
        activation and {
            sh(search_count, 5),
            sh(percentage_loc, 10),
            sh(column_loc, 6),
            hl = hl(2), sep = ' ', pad = ' '
        } or false,
        loclist_tag,
    }
end


local function quickfix_statusline(activation, mode, winid)
    local is_search = false
    if winid and winid ~= 0 then
        local filewinid = vim.fn.getloclist(winid, { filewinid = 0 }).filewinid
        if filewinid and filewinid ~= 0 then
            local title = vim.fn.getloclist(filewinid, { title = 0 }).title
            is_search = title ~= nil and title:sub(1, 8) == 'Search: '
        end
    end
    local hl1 = is_search and 'StatuslineSearch_1' or 'StatuslineGeneralActive_1_n'
    local hl2 = is_search and 'StatuslineSearch_2' or 'StatuslineGeneralActive_2_n'
    return {
        { 'ﴴ ', sh(quickfix_search_query, 1, quickfix_search_query_compact), hl = hl1, sep = ' ', pad = ' ' },
        gap,
        { grep_status_icon, sh(search_count, 2), sh('%l/%L', 3, '%l'), hl = hl2, sep = ' ', pad = ' ' },
        loclist_tag,
    }
end

local function help_statusline(activation)
    local active_only = function(st) return activation and st or '' end
    return {
        {' ', filename_only, hl = 'StatuslineGeneralActive_1_n', pad = ' ', sep = ' ' },
        gap,
        active_only{ sh(search_count, 1), sh(percentage_loc, 2), hl = 'StatuslineGeneralActive_2_n', pad = ' ', sep = ' ' },
     }
end

local function man_title(bufnr, winid)
    local name = vim.fn.bufname(bufnr)
    return name:gsub('^man://', '')
end

local function checkhealth_statusline(activation)
    return {
        { 'Checkhealth', hl = 'StatuslineGeneralActive_1_n', pad = ' ' },
        gap,
    }
end

local function man_statusline(activation)
    local active_only = function(st) return activation and st or '' end
    return {
        { 'ManPage', man_title, hl = 'StatuslineGeneralActive_1_n', sep = ' ', pad = ' ' },
        gap,
        active_only{ sh(search_count, 1), sh(percentage_loc, 2), sh(column_loc, 3),
                     hl = 'StatuslineGeneralActive_2_n', sep = ' ', pad = ' ' },
    }
end

local function fugitive_statusline(activation)
    local active_only = function(st) return activation and st or '' end
    return {
        { ' ', sh(fugitive_info, 2, fugitive_info_compact), hl = 'StatuslineGeneralActive_1_n', sep = ' ', pad = ' ' },
        gap,
        active_only{ sh(percentage_loc, 1), hl = 'StatuslineGeneralActive_2_n', sep = ' ', pad = ' ' },
    }
end

local function terminal_statusline(activation, mode)
    -- local active_only = function(st) return activation and st or '' end
    -- local buf_name = ut.GetCurrentBufferDir()
    -- local term_cmd = string.sub(buf_name, vim.fn.match(buf_name, [[\v\:\zs[^:]+$]])+1)
    local hl = function()
        return 'StatuslineTerm' .. (activation and ('Active_1_%s'):format(mode) or 'Inactive')
    end
    return {' ', hl = hl(), sep = '',}
end


local function oil_statusline(activation, mode)
    local active_only = function(st) return activation and st or '' end
    local hl = function(num)
        return 'StatuslineGeneral' .. (activation and ('Active_%d_%s'):format(num, mode) or 'Inactive')
    end
    return {
        { project_or_git_branch_name, filename_and_status, hl = hl(1), sep = ' │ ', pad = ' ' },
        gap,
        active_only { search_count, percentage_loc, hl = hl(2), sep = ' ', pad = ' ' },
    }
end

local function launcher_statusline(activation, mode, winid)
    local active_only = function(st) return activation and st or '' end
    local hl = function(num)
        return 'StatuslineGeneral' .. (activation and ('Active_%d_%s'):format(num, mode) or 'Inactive')
    end
    return {
        {
            launcher_status_icon,
            sh(launcher_folder, 1, launcher_folder_compact),
            '│',
            sh(launcher_command, 2),
            hl = hl(1), sep = ' ', pad = ' '
        },
        gap,
        active_only {
            search_count,
            sh('%l/%L', 10, '%l'),
            hl = hl(2), sep = ' ', pad = ' '
        },
    }
end

-- Let's make not to use any functions on stausline option.
-- Refreshing on the selected events is the place that to execute funtions.

-- events (user selected by components)
-- → update status and tab line information (some are asyncronously done)
-- → redraw when it done at the all events (check the duration between redraws)
local statusline_setup = {
    components = {
        general = general_statusline,
        quickfix = quickfix_statusline,
        help = help_statusline,
        fugitive = fugitive_statusline,
        terminal = terminal_statusline,
        launcher = launcher_statusline,
        checkhealth = checkhealth_statusline,
        health      = checkhealth_statusline,
        man         = man_statusline,
        -- oil = oil_statusline,
    },
    highlights = {
        StatuslineGeneralActive = {
            [1] = {
                n = { bg = '#1F2937', fg = '#9CA3AF' },
                i = { bg = '#1F2937', fg = '#98BC99' },
                v = { bg = '#1F2937', fg = '#FBC19D' },
                c = { bg = '#1F2937', fg = '#99BBBD' },
                r = { bg = '#1F2937', fg = '#E8D4B0' },
            },
            [2] = {
                n = { bg = '#334155', fg = '#D1D5DB' },
                i = { bg = '#98BC99', fg = '#111827' },
                v = { bg = '#FBC19D', fg = '#111827' },
                c = { bg = '#99BBBD', fg = '#111827' },
                r = { bg = '#E8D4B0', fg = '#111827' },
            },
        },
        StatuslineGeneralInactive = { bg = '#1F2937', fg = '#6B7280' },
        StatuslineQuickfix = {
            [1] = { link = 'StatuslineGeneralActive_1' },
            [2] = { link = 'StatuslineGeneralActive_2' },
        },
        StatuslineTermActive = {
            [1] = {
                n = { link = 'StatuslineGeneralActive_1_n' },
                t = { link = 'StatuslineGeneralActive_1_i' },
            }
        },
        StatuslineTermInactive = { link = 'StatuslineGeneralInactive' },
        StatuslineTag1 = { fg = '#1e1e2e', bg = '#89b4fa' },
        StatuslineTag2 = { fg = '#1e1e2e', bg = '#a6e3a1' },
        StatuslineTag3 = { fg = '#1e1e2e', bg = '#fab387' },
        StatuslineTag4 = { fg = '#1e1e2e', bg = '#cba6f7' },
        StatuslineTag5 = { fg = '#1e1e2e', bg = '#f38ba8' },
        StatuslineSearch_1 = { bg = '#1F2937', fg = '#0284c7' },
        StatuslineSearch_2 = { bg = '#0c4a6e', fg = '#7dd3fc' },
    },
    -- seperator = { '│', hl = { bg = '', fg = '' } },
}

-- local function set_all_highlight(hls)
--     for hl, ms in pairs(hls) do
--         for m, colors in pairs(ms) do
--             ut.set_highlight(("%s_%s"):format(hl, m), colors)
--         end
--     end
-- end

local function set_all_highlight(hls)
    for group, value in pairs(hls) do
        if type(value) ~= "table" then
            -- ignore non-table values
        elseif value[1] then
            -- indexed table: [1], [2], ...
            for idx, sub in pairs(value) do
                local has_modes
                for k, v in pairs(sub) do
                    if type(v) == "table" then
                        vim.api.nvim_set_hl(0, ("%s_%s_%s"):format(group, idx, k), v)
                        has_modes = true
                    end
                end
                if not has_modes then
                    vim.api.nvim_set_hl(0, ("%s_%s"):format(group, idx), sub)
                end
            end
        else
            -- plain highlight definition
            vim.api.nvim_set_hl(0, group, value)
        end
    end
end

local function get_entry_func(buftype, filetype, protocol)
    local components = statusline_setup.components

    if components[protocol] then
        return components[protocol]
    elseif components[buftype] then
        return components[buftype]
    elseif components[filetype] then
        return components[filetype]
    end

    return components.general
end

function M.statusline_entry()
    local winid = vim.g.statusline_winid or 0
    local bufnr = vim.api.nvim_win_get_buf(winid)
    local protocol = ut.GetBufferProtocol(bufnr)
    local w = vim.api.nvim_win_get_width(winid)
    local activation = winid == vim.api.nvim_get_current_win()
    local entryfunc = get_entry_func(vim.bo[bufnr].buftype, vim.bo[bufnr].filetype, protocol)
    local tree = entryfunc(activation, vim.fn.mode(), winid)

    local excluded = {}
    local result

    repeat
        local ctx = { excluded = excluded, candidates = {}, order = 0 }
        result = make_statusline_text(bufnr, winid, tree, '', ctx)

        if measure_sl_text(result) <= w then break end

        table.sort(ctx.candidates, function(a, b)
            if a.priority ~= b.priority then return a.priority < b.priority end
            return a.order < b.order
        end)

        local next_c
        for _, c in ipairs(ctx.candidates) do
            if not excluded[c.fn] then next_c = c; break end
        end
        if not next_c then break end

        excluded[next_c.fn] = true
    until false

    return result
end

function M.setup()
    -- Skip statusline setup in test environment to avoid headless UI errors
    if vim.g.is_testing then return end

    vim.o.laststatus = 2
    vim.o.showtabline = 2

    local testing = true
    if testing == true then
        vim.o.statusline = "%!v:lua.require'status'.statusline_entry()"
        set_all_highlight(statusline_setup.highlights)
    else
        vim.api.nvim_create_autocmd({'WinEnter', 'BufWinEnter'},
                                    { callback = function() vim.wo.statusline = M.ActiveWin() end })
        vim.api.nvim_create_autocmd({'WinLeave', 'BufLeave'},
                                    { callback = function() vim.wo.statusline = M.InactiveWin() end })
        ut.set_highlight('StatusLineInactive', {guibg = '#1F2937', guifg = '#6B7280'})
    end

    -- Set flag before TabLine() is called so auto-scroll applies on tab navigation
    vim.api.nvim_create_autocmd('TabEnter', { callback = function() auto_scroll_next = true end })
    vim.api.nvim_create_autocmd({'WinEnter', 'WinLeave', 'TabEnter', 'TabLeave', 'TabClosed', 'BufNew', 'BufEnter', 'BufLeave', 'SessionLoadPost'},
                                { callback = function() vim.go.tabline = M.TabLine() end })
    ut.set_highlight('TabLineSel', {gui = 'bold,italic'})

    ut.nnoremap('<leader>t', function() require'status'.tab_scroll(vim.v.count1) end)
    ut.nnoremap('<leader>T', function() require'status'.tab_scroll(-vim.v.count1) end)
end

return M
