local M = {}
local env = require 'env'
local util_cache = require('util.cache')
local util_serialize = require('util.serialize')

M.MEMOIZE_CLEANUP_HOUR_MS = util_cache.MEMOIZE_CLEANUP_HOUR_MS


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
        M.OpenTerminal(M.GetCurrentBufferDir(), splitcmd)
    end
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
    --vim.bo.filetype = 'scratch'
    --vim.bo.modifiable = false
    return buf
end


function M.AsyncProcess(cmd, args, cwd, ev_or_opts, read_func, end_func)
    local ev
    -- Accept an opts table as 4th arg: { env=..., onread=..., onexit=... }
    -- Detected by: table with no integer index (distinguishes from old env list)
    if type(ev_or_opts) == 'table' and ev_or_opts[1] == nil then
        ev = ev_or_opts.env
        read_func = ev_or_opts.onread
        end_func = ev_or_opts.onexit
    else
        ev = ev_or_opts
    end
    local stdout = read_func and vim.uv.new_pipe(false)
    local stderr = read_func and vim.uv.new_pipe(false)
    local handle, pid
    local status = 'initializing'

    local get_status = function() return status end

    local on_exit = function(code, signal)
        if read_func then
            stdout:read_stop()
            stderr:read_stop()
            stdout:close()
            stderr:close()
        end
        if handle and not handle:is_closing() then
            handle:close()
        end
        if end_func then
            end_func(code, signal)
        end
        status = 'finished'
    end

    local spawn_options = {
        args = args,
        stdio = { nil, stdout, stderr},
        cwd = cwd,
        env = ev,
    }

    local success, err_or_handle, pid_or_err = pcall(vim.uv.spawn, cmd, spawn_options, vim.schedule_wrap(on_exit))
    if not success then
        return nil, function() end, function() return "failed" end, nil, err_or_handle
    end
    handle, pid = err_or_handle, pid_or_err
    status = 'running'

    if read_func then
        vim.uv.read_start(stdout, read_func)
        vim.uv.read_start(stderr, read_func)
    end
    local terminate_function = function(signal)
        signal = signal or "sigterm"
        if handle and not handle:is_closing() then
            handle:kill(signal)
            -- print("kill success")
        end
        status = 'terminated'
    end

    return pid, terminate_function, get_status, handle
end

function M.SimpleAsyncProcess(cmd, args, on_completed, cwd, ev)
    local stdout = vim.uv.new_pipe(false)
    local result = {}
    local handle
    handle = vim.uv.spawn(
        cmd,
        { args = args, stdio = { nil, stdout, nil }, cwd = cwd, env = ev, },
        vim.schedule_wrap(function()
            stdout:read_stop()
            stdout:close()
            if handle and not handle:is_closing() then
                handle:close()
            end
            if on_completed then
                on_completed(result)
            end
        end))

    local remain = ''
    vim.uv.read_start(stdout, function(err, data)
        if data then
            data = data:gsub('\r\n', '\n')
            local vals = vim.split(data, '\n')
            vals[1] = remain .. vals[1]
            if data:sub(-1) ~= '\n' then
                remain = table.remove(vals)
            else
                remain = ''
            end
            for _, d in ipairs(vals) do
                result[#result+1] = d
            end
        end
    end)
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
    local current_file_path = M.GetCurrentBufferDir():gsub(env.dir_sep, '/')
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
        local current_file_path = M.GetCurrentBufferDir():gsub(env.dir_sep, '/')
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

function M.set_highlights(hls)
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

function M.ttl_caching_result(func, expired_ms)
    return util_cache.ttl_caching_result(func, expired_ms)
end

--- Memoize a function with TTL and automatic cleanup of expired entries.
---
--- @param func      function                  The function to memoize.
--- @param opts?     table                     Options:
---   - ttl_ms       number (required)         TTL in milliseconds (> 0 enables caching)
---   - key_fn       function(...) -> string   Optional custom key function (default uses identity)
---   - cleanup_ms   number                    Sweep interval in ms; if nil/<=0, no background timer is used.
---   - opportunistic_every number             If no timer: sweep every N calls (default 100).
--- @return function                           A wrapper function with per-argument TTL caching.
function M.memoize_ttl(func, opts)
    return util_cache.memoize_ttl(func, opts)
end

--- Debounce a function: coalesce rapid calls into a single trailing invocation.
--- Each call (re)arms a timer for `ms`; the wrapped `fn` runs once, `ms` after the
--- last call, with that last call's arguments. The timer callback is scheduled on
--- the main loop, so `fn` may safely touch the Neovim API.
---
--- @param fn function   The function to debounce.
--- @param ms number     Trailing-edge delay in milliseconds.
--- @return function      The debounced wrapper.
function M.debounce(fn, ms)
    return util_cache.debounce(fn, ms)
end

--- Throttle a function: run it at most once per `ms`, firing immediately on
--- the leading edge and once more on the trailing edge if calls kept arriving
--- during the cooldown. Unlike `debounce`, this keeps firing at a steady
--- cadence during a sustained burst instead of waiting for it to go quiet.
---
--- @param fn function   The function to throttle.
--- @param ms number     Minimum milliseconds between invocations.
--- @return function      The throttled wrapper.
function M.throttle(fn, ms)
    return util_cache.throttle(fn, ms)
end


function M.insert_unique_by(t, value, eq)
    return util_serialize.insert_unique_by(t, value, eq)
end


function M.normalize_path_separator(path)
    return util_serialize.normalize_path_separator(path, env.os.win)
end


function M.serialize(tbl, indent)
    return util_serialize.serialize(tbl, indent)
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


function M.close_all_qf_and_loc_windows()
    for _, winid in ipairs(vim.api.nvim_list_wins()) do
        local buf = vim.api.nvim_win_get_buf(winid)
        local bt = vim.bo[buf].buftype
        if bt == 'quickfix' then
            vim.api.nvim_win_close(winid, true)
        end
    end
end


return M
