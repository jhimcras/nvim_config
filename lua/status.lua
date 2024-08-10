local env = require 'env'
local ut = require 'util'
local M = {}

local function GetModeColor(mode)
    local mode_color = {
        Normal = { bg = { '#70ace5', '#26394d' }, fg = { '#212121', '#b7bdc0' } };
        Insert = { bg = { '#87bb7c', '#374D33' }, fg = { '#212121', '#b7bdc0' } };
        Visual = { bg = { '#d7956e', '#4D3527' }, fg = { '#212121', '#b7bdc0' } };
        None = { bg = { '#b7bdc0', '#494C4D' }, fg = { '#212121', '#b7bdc0' } };
    }
    mode_color.Command = mode_color.Normal
    mode_color.Terminal = mode_color.Insert
    return mode_color[mode] or mode_color.None
end

function M.get_current_mode()
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
    return mode[leading_charater_of_current_mode] or ''
end

function M.status_update()
    local color = GetModeColor(M.get_current_mode())
    ut.set_highlight('StatusLineMode', {guibg = color.bg[1], guifg = color.fg[1]})
    ut.set_highlight('StatusLineNormal', {guibg = color.bg[2], guifg = color.fg[2]})
    return ''
end

local function terminalinfo()
    local buf_name = vim.api.nvim_buf_get_name(0)
    local term_cmd = string.sub(buf_name, vim.fn.match(buf_name, [[\v\:\zs[^:]+$]])+1)
    return 'TERMINAL │ ' .. (term_cmd or '')
end

local function helpinfo()
    local buf_name = vim.api.nvim_buf_get_name(0)
    local help_file_regex = [[\v\/\zs[^/]+\ze\.txt$]]
    local s = vim.fn.match(buf_name, help_file_regex)+1
    local e = vim.fn.matchend(buf_name, help_file_regex)
    local help_file_name = string.sub(buf_name, s, e)
    return 'HELP │ ' .. (help_file_name or '')
end

local function fugitiveinfo()
    return 'FUGITIVE │ ' .. (require'prjroot'.GetCurrentProjectRoot() or '')
end

local function launcher()
    return string.format('%s(%s)', vim.b.prjroot_folder, vim.b.lc_object)
end

local function quickfix()
    return vim.w.quickfix_title
end

local types = {
    { bt = 'terminal', info = terminalinfo },
    { bt = 'help', info = helpinfo },
    { ft = 'fugitive', info = fugitiveinfo },
    { ft = 'launcher', info = launcher },
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

function M.tabtitle(n)
    local extends = vim.list_extend
    local buflist = vim.fn.tabpagebuflist(n)
    local winnr = vim.fn.tabpagewinnr(n)
    local bname = vim.fn.bufname(buflist[winnr])
    local pr = require'prjroot'.GetProjectRoot(vim.fn.fnamemodify(bname, ':p'))
    local t = {}
    if pr then
        extends(t, { '[', vim.fn.fnamemodify(pr, ':p:h:t'), ']', ' ' })
    end
    if bname == '' then
        extends(t, { 'No Name' })
    else
        if bname:sub(bname:len()) == env.dir_sep then
            extends(t, { vim.fn.fnamemodify(bname, ':p:h:t'), env.dir_sep })
        else
            extends(t, { vim.fn.fnamemodify(bname, ':p:t') })
        end
    end
    return table.concat(t)
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
    if pr and pr ~= '' then
        gb = vim.fn.FugitiveHead()
        if gb and gb ~= '' then
            extends(fi, { ' ', gb, ' │ ' })
        end
    end
    if vim.bo.fileencoding ~= 'utf-8' and vim.bo.fileencoding ~= '' then
        extends(fi, { vim.bo.fileencoding, ' │ ' })
    end
    if vim.bo.bomb then
        extends(fi, {'BOM │ '})
    end
    local buf_name = vim.api.nvim_buf_get_name(0)
    if pr then
        local relative_filename = '.' .. buf_name:sub(pr:len()+1)
        if vim.fn.fnamemodify(pr, ':t') == gb then
            extends(fi, { '🗎 ', relative_filename })
        else
            extends(fi, { '🖿  ', vim.fn.fnamemodify(pr, ':t'), ' │ 🗎 ', relative_filename })
        end
    else
        extends(fi, (buf_name ~= '') and { '🗎 ', buf_name } or { 'No Name' } )
    end
    extends(fi, {
        vim.bo.modified and ' +' or '',
        vim.bo.readonly and ' ' or '',
        not vim.bo.modifiable and ' -'  or '',
    })
    return table.concat(fi)
end

function M.ActiveWin()
    local sl = {
        "%{v:lua.require'status'.status_update()}",
        "%(%#StatusLineNormal# %{v:lua.require'status'.leftside()} %)",
        "│ %{v:lua.require'status'.lsp()}",
        "%=",
        -- (env.os.unix) and "%(%#StatusLineMode#%{v:lua.require'status'.fcitx()}%)" or '',
        "%(%#StatusLineMode# %p%% %c %)"
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

function M.TabLine()
    local extends = vim.list_extend
    local total_tab_number = vim.fn.tabpagenr('$')
    local s = {}
    for i=1,total_tab_number do
        extends(s, {
            "%{v:lua.require'status'.tab_update()}",
            string.format("%%#TabLine%d#%%%dT %d %%{v:lua.require'status'.tabtitle(%d)}", i, i, i, i),
            " %#TabLine#│"
        })
    end
    extends(s, { "%#MoreMsg#%=%#MoreMsg# %{v:lua.require'status'.session()} " })
    return table.concat(s)
end

function M.setup()
    vim.o.laststatus = 2
    vim.o.showtabline = 2
    vim.api.nvim_create_autocmd({'WinEnter', 'BufWinEnter'},
                                { callback = function() vim.wo.statusline = M.ActiveWin() end })
    vim.api.nvim_create_autocmd({'WinLeave', 'BufLeave'},
                                { callback = function() vim.wo.statusline = M.InactiveWin() end })
    vim.api.nvim_create_autocmd({'WinEnter', 'WinLeave', 'TabEnter', 'TabLeave', 'TabClosed', 'BufNew', 'BufLeave', 'SessionLoadPost'},
                                { callback = function() vim.go.tabline = M.TabLine() end })
    ut.set_highlight('StatusLineInactive', {guibg = '#555555', guifg = '#909090'})
    ut.set_highlight('TabLineSel', {gui = 'bold,italic'})
end

return M
