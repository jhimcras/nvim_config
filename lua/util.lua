local M = {}
local env = require 'env'

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

function M.GetVisualSelection()
    local mode = vim.fn.mode()
    if mode == 'v' then
        local line_start = vim.fn.line('v')
        local line_end = vim.fn.line('.')
        local column_start = vim.fn.col('v')
        local column_end = vim.fn.col('.')
        if line_start == line_end then
            return { line_start, math.min(column_start, column_end), line_end, math.max(column_start, column_end) }
        elseif line_start > line_end then
            return { line_end, column_end, line_start, column_start }
        else
            return { line_start, column_start, line_end, column_end }
        end
    elseif mode == 'V' then
        local line_start = vim.fn.line('v')
        local line_end = vim.fn.line('.')
        local last_line_len = string.len(vim.api.nvim_buf_get_lines(0, math.max(line_start, line_end)-1, math.max(line_start, line_end), false)[1])
        return { math.min(line_start, line_end), 1, math.max(line_start, line_end), last_line_len }
    end
    -- TODO: visual block mode...
end

function M.GetSelectWord()
    local sel = M.GetVisualSelection()
    if sel and sel[1] == sel[3] then
        local ln = vim.api.nvim_buf_get_lines(0, sel[1]-1, sel[1], false)
        return string.sub(ln[1], sel[2], sel[4])
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


function M.OpenProjectRootTerminal(splitcmd)
    local pr = require'prjroot'.GetCurrentProjectRoot()
    if pr then
        M.OpenTerminal(pr, splitcmd)
    else
        M.OpenTerminal(vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ':p:h'), splitcmd)
    end
end


function M.NewScratchBuffer(position)
    if position and position.orientation == 'vertical' then
        if position.size then
            vim.cmd(position.size ..' vnew')
        else
            vim.cmd('vnew')
        end
    elseif position and position.orientation == 'horizontal' then
        if position.size then
            vim.cmd('botright' .. position.size .. 'new')
        else
            vim.cmd('botright new')
        end
    else
        vim.cmd('vnew')
    end
    local buf = vim.api.nvim_get_current_buf()
    vim.bo.buftype = 'nofile'
    --vim.bo.filetype = 'scratch'
    --vim.bo.modifiable = false
    return buf
end


function M.AsyncProcess(cmd, args, cwd, ev, read_func, end_func)
    local stdout = read_func and vim.loop.new_pipe(false)
    local stderr = read_func and vim.loop.new_pipe(false)
    local handle, pid
    local on_exit = function(code, signal)
        if read_func then
            stdout:read_stop()
            stderr:read_stop()
            stdout:close()
            stderr:close()
        end
        handle:close()
        if end_func then
            end_func(code, signal)
        end
    end
    local spawn_options = {
        args = args,
        stdio = { nil, stdout, stderr},
        cwd = cwd,
        env = ev,
    }
    handle, pid = vim.loop.spawn(cmd, spawn_options, vim.schedule_wrap(on_exit))
    if read_func then
        vim.loop.read_start(stdout, read_func)
        vim.loop.read_start(stderr, read_func)
    end
    return pid
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

-- Hidden buffer call (from https://github.com/arithran/vim-delete-hidden-buffers)
function M.DeleteHiddenBuffers()
--[[
function! DeleteHiddenBuffers()
    let tpbl=[]
    call map(range(1, tabpagenr('$')), 'extend(tpbl, tabpagebuflist(v:val))')
    for buf in filter(range(1, bufnr('$')), 'bufexists(v:val) && index(tpbl, v:val)==-1')
        silent execute 'bwipeout' buf
    endfor
endfunction
command! DeleteHiddenBuffers call DeleteHiddenBuffers()
]]--
end

-- Erase trailing whitespace function and keyboard binding.
function M.StripTrailingWhitespace()
    local prevPosition = vim.fn.getpos('.')
    local prevSearch = vim.fn.getreg('/')
    vim.cmd('%s/\\s\\+$//e')
    vim.fn.setreg('/', prevSearch)
    vim.fn.setpos('.', prevPosition)
end

local function IsCurrentFileLuaPlugin()
    local current_file_path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ':p:h'):gsub(env.dir_sep, '/')
    local lua_plugin_folder = table.concat{vim.fn.fnamemodify(vim.env.MYVIMRC, ':p:h'), env.dir_sep, 'lua'}:gsub(env.dir_sep, '/')
    return string.sub(current_file_path, 1, #lua_plugin_folder) == lua_plugin_folder
end


function M.ResetPlugin(plugname)
    if _G.package.loaded[plugname] then
        _G.package.loaded[plugname] = nil
    end
end


function M.AutoResetPlugin()
    if IsCurrentFileLuaPlugin() then
        local current_file_path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ':p'):gsub(env.dir_sep, '/')
        local file_name = vim.fn.fnamemodify(current_file_path, ':t:r')
        local folder = vim.fn.fnamemodify(current_file_path, ':h'):gsub(env.dir_sep, '/')
        local lua_plugin_folder = table.concat{vim.fn.fnamemodify(vim.env.MYVIMRC, ':p:h'), env.dir_sep, 'lua'}:gsub(env.dir_sep, '/')
        local path_from_lua = folder:sub(#lua_plugin_folder+1)
        local prefix = path_from_lua:gsub('/', '.')
        if prefix ~= '' then prefix = prefix .. '.' end
        --print('Reset plugin: ' .. prefix .. file_name)
        M.ResetPlugin(prefix .. file_name)
        --local s = buf_name:find([[
        --local current_plugin_name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ':p:t:r')
        --ResetPlugin(current_plugin_name)
    end
end


function M.LaunchCurrentLuaFile()
    local lua_exe = ''
    if env.os.win == true then
        lua_exe = 'luajit' -- TODO: findout actual lua executable file
    elseif env.os.unix == true then
        lua_exe = 'lua'
    end
    if vim.fn.executable(lua_exe) then
        require'launcher'.Launch(lua_exe, {vim.fn.expand('%')}, vim.fn.fnamemodify('%', ':p:h'), 'vertical')
    end
end


function M.CreateMarkdownNote()
    vim.cmd.vnew()
    vim.api.nvim_get_current_buf()
    vim.bo.filetype = 'markdown'
end


function M.ExecFileOnDirvish()
    local old_reg = vim.fn.getreg('@')
    vim.cmd('normal yy')
    local execute_file = vim.fn.shellescape(vim.fn.trim(vim.fn.getreg('@')), 1)
    if env.os.win then
        vim.cmd('silent !start explorer ' .. execute_file)
    elseif env.os.unix and vim.fn.executable('kde-open5') then
        vim.cmd('silent !kde-open5 ' .. execute_file .. ' &')
    end
    vim.fn.setreg('@', old_reg)
end

-- show difference of current file and saved file
function M.DiffOrig()
    vim.cmd('vert new | set bt=nofile | r ++edit # | 0d_ | diffthis | wincmd p | diffthis')
end

-- Show the stack of syntax highlighting classes affecting whatever is under the cursor.
-- Notes: Not working on treesitter
function M.SynStack()
    local syn_stack = ''
    local syn = vim.fn.synstack(vim.fn.line('.'), vim.fn.col('.'))
    for _, s in ipairs(syn) do
        syn_stack = (syn_stack~='' and (syn_stack .. ' > ') or '') .. vim.fn.synIDattr(vim.v.val, 'name')
    end
    vim.notify(syn_stack, vim.log.levels.INFO)
end

function M.set_highlight(name, args)
    if type(args) == 'table' then
        local a = { name }
        for key, arg in pairs(args) do
            a[#a+1] = string.format(' %s=%s', key, tostring(arg))
        end
        vim.cmd.highlight(table.concat(a))
    elseif type(args) == 'string' then
        vim.cmd.highlight {'link', name, args}
    end
end

local function map_general(mode, lh, rh, opts)
    if opts then
        local check_validation = function(o)
            assert(o == 'expr' or o == 'buffer' or o == 'noremap' or o == 'silent',
                   string.format('keymap option: %s is not valid option',  tostring(o)))
        end
        local options = {}
        for _, o in ipairs(opts) do
            check_validation(o)
            options[o] = true
        end
        for o, v in pairs(opts) do
            if type(o) ~= 'number' then
                check_validation(o)
                options[o] = v
            end
        end
        vim.keymap.set(mode, lh, rh, options)
    end
end

local modes = { '', 'n', 't', 'x', 'i', 'v', 's', 'o' }
for _, m in ipairs(modes) do
    M[m .. 'map'] = function(lh, rh, opts) map_general(m, lh, rh, vim.tbl_extend('force', opts or {}, {silent=true})) end
    M[m .. 'noremap'] = function(lh, rh, opts) map_general(m, lh, rh, vim.tbl_extend('force', opts or {}, {noremap=true, silent=true})) end
end

function Dump(...)
    local objects = vim.tbl_map(vim.inspect, {...})
    print(unpack(objects))
end

return M
