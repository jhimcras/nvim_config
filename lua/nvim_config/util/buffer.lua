local M = {}
local env = require 'nvim_config.env'


function M.GetBufferProtocol(bufnr)
    bufnr = bufnr or 0
    local raw = vim.api.nvim_buf_get_name(bufnr)
    return raw:match('^([^:]+)://')
end


function M.GetBufferName(bufnr)
    bufnr = bufnr or 0
    local raw = vim.api.nvim_buf_get_name(bufnr)
    if raw == '' then return '' end

    local protocol = M.GetBufferProtocol(bufnr)
    if protocol then
        return raw:sub(#protocol + 4), protocol
    end

    local abs = vim.fn.fnamemodify(raw, ':p')
    local resolved = vim.uv.fs_realpath(abs)
    return resolved or abs
end


function M.GetBufferDir(bufnr)
    local name = M.GetBufferName(bufnr)
    if name == '' then return '' end
    if env.os.win then
        name = name:gsub('^/(%a)/', '%1:/')
        name = name:gsub('\\', '/')
    end
    local path = vim.fn.fnamemodify(name, ':p:h')
    return vim.uv.fs_stat(path) and path:gsub('\\', '/') or ''
end


function M.GetCurrentBufferDir()
    return M.GetBufferDir(0)
end


function M.GetWinIndexInTab(winid, tabpage)
    if not winid or not vim.api.nvim_win_is_valid(winid) then
        return 0
    end

    tabpage = tabpage or vim.api.nvim_win_get_tabpage(winid)
    if not tabpage or not vim.api.nvim_tabpage_is_valid(tabpage) then
        return 0
    end

    local wins = vim.api.nvim_tabpage_list_wins(tabpage)
    for i, w in ipairs(wins) do
        if w == winid then
            return i
        end
    end

    return 0
end


function M.OpenConfig(opts)
    local args = { vim.fn.stdpath('config') .. '/init.lua' }
    if vim.fn.line('$') == 1 and vim.fn.getline(1) == '' then
        vim.cmd.edit { mods = opts.smods, args = args }
    elseif opts.mods ~= '' then
        vim.cmd.split { mods = opts.smods, args = args }
    else
        vim.cmd.split { mods = { vertical = true }, args = args }
    end
end


local function CDCmd()
    local change_directory_commands = { win32 = 'cd /D', unix = 'cd', }
    for osname, cmd in pairs(change_directory_commands) do
        if vim.fn.has(osname) == 1 then
            return cmd
        end
    end
    return ''
end


local function ShellCmd()
    local shell_start_commands = { win32 = 'cmd', unix = 'bash', }
    for osname, cmd in pairs(shell_start_commands) do
        if vim.fn.has(osname) == 1 then
            return cmd
        end
    end
    return ''
end


function M.OpenTerminal(path, splitcmd)
    local p = vim.fn.fnamemodify(path, ':p')
    local cmd = string.format([[call termopen('%s "%s" && %s')]], CDCmd(), p, ShellCmd())
    local splcmd = { vertical = 'vnew', horizontal = 'new', tab = 'tabe' }
    vim.fn.execute({splcmd[splitcmd], cmd})
end


function M.NewScratchBuffer(position)
    local orientation = 'vertical'
    local size = ''

    if type(position) == 'string' then
        orientation = position
    elseif type(position) == 'table' then
        orientation = position.orientation or 'vertical'
        if orientation == 'vertical' or orientation == 'left' or orientation == 'right' then
            size = tostring(position.width or position.size or '')
        elseif orientation == 'horizontal' or orientation == 'top' or orientation == 'bottom' then
            size = tostring(position.height or position.size or '')
        else
            size = tostring(position.size or '')
        end
    end

    local cmd = ''
    if orientation == 'vertical' then
        cmd = size .. ' vnew'
    elseif orientation == 'horizontal' then
        cmd = 'botright ' .. size .. ' new'
    elseif orientation == 'top' then
        cmd = 'topleft ' .. size .. ' new'
    elseif orientation == 'bottom' then
        cmd = 'botright ' .. size .. ' new'
    elseif orientation == 'left' then
        cmd = 'topleft ' .. size .. ' vnew'
    elseif orientation == 'right' then
        cmd = 'botright ' .. size .. ' vnew'
    elseif orientation == 'tab' then
        cmd = 'tabnew'
    else
        cmd = 'vnew'
    end

    vim.cmd(cmd)

    local buf = vim.api.nvim_get_current_buf()
    vim.bo.buftype = 'nofile'
    return buf
end


function M.IsExist(path)
    return vim.fn.filereadable(path) ~= 0 or vim.fn.isdirectory(path) ~= 0
end


function M.OpenAllHiddenBuffers()
    for _, b in ipairs(vim.fn.getbufinfo()) do
        if b.listed ~= 0 and b.hidden ~= 0 and b.name == '' then
            vim.cmd.sbuffer(b.bufnr)
        end
    end
end


function M.wipeout_hidden_buffers()
    local visible_buffers = {}
    for _, win in ipairs(vim.api.nvim_list_wins()) do
        visible_buffers[vim.api.nvim_win_get_buf(win)] = true
    end
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.fn.buflisted(buf) == 1 and not visible_buffers[buf] then
            vim.api.nvim_buf_delete(buf, {force = true})
        end
    end
end


function M.get_window_context(winid)
    if not winid or not vim.api.nvim_win_is_valid(winid) then
        return nil
    end

    local tabpage = vim.api.nvim_win_get_tabpage(winid)
    local bufnr   = vim.api.nvim_win_get_buf(winid)
    local cursor  = vim.api.nvim_win_get_cursor(winid)
    local bufname = M.GetBufferName(bufnr)

    return {
        tabpage = tabpage,
        winid   = winid,
        winidx  = M.GetWinIndexInTab(winid, tabpage),
        cursor  = { row = cursor[1], col = cursor[2] },
        bufnr   = bufnr,
        bufname = bufname,
        mtime   = bufname ~= '' and vim.fn.getftime(bufname) or nil,
    }
end


return M
