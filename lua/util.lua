local M = {}
local env = require 'env'

M.MEMOIZE_CLEANUP_HOUR_MS = 3600000


function M.GetBufferName(bufnr)
    bufnr = bufnr or 0
    local raw = vim.api.nvim_buf_get_name(bufnr)
    if raw == '' then return '' end

    if vim.bo[bufnr].filetype == 'oil' then
        return raw:sub(8, 8) .. ':' .. raw:sub(9):gsub('\\', '/')
    end
    -- TODO: implement as possible as every filetype, buftype currently used

    local abs = vim.fn.fnamemodify(raw, ':p')
    local resolved = vim.uv.fs_realpath(abs)
    return resolved or abs
end


function M.GetBufferDir(bufnr)
    local name = M.GetBufferName(bufnr)
    if name == '' then return '' end
    return vim.fn.fnamemodify(name, ':p:h')
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

    handle, pid = vim.uv.spawn(cmd, spawn_options, vim.schedule_wrap(on_exit))
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

    return pid, terminate_function, get_status
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
    if not func then return function() return nil end end
    local cached_time
    local cached_result
    return function()
        local now = vim.uv.now()
        if cached_result and now - cached_time  < expired_ms then
            return cached_result
        end
        cached_result = func()
        cached_time = now
        return cached_result
    end
end

-- Polyfill pack for LuaJIT/Lua 5.1: preserves nils via 'n' field.
local function pack(...)
  return { n = select("#", ...), ... }
end
-- Use table.unpack if available (Lua 5.2+), otherwise global unpack (Lua 5.1).
local unpack_fn = table.unpack or unpack

-- Default key function: builds a string key from argument tuple.
local function default_key(...)
  local n = select("#", ...)
  if n == 0 then return "__noargs__" end
  local parts = {}
  for i = 1, n do
    local v = select(i, ...)
    local t = type(v)
    if t == "number" or t == "boolean" or t == "nil" then
      parts[#parts + 1] = tostring(v)
    elseif t == "string" then
      parts[#parts + 1] = "s:" .. v
    else
      -- identity-based key for tables/functions/userdata/threads
      parts[#parts + 1] = t .. ":" .. tostring(v)  -- e.g., table: 0x...
    end
  end
  return table.concat(parts, "|")
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
    assert(type(func) == "function", "memoize_ttl: func must be a function")

    opts = opts or {}
    local ttl_ms = assert(tonumber(opts.ttl_ms), "memoize_ttl: opts.ttl_ms must be a number")
    local key_fn = opts.key_fn or default_key
    local cleanup_ms = tonumber(opts.cleanup_ms) or 0
    local opportunistic_every = tonumber(opts.opportunistic_every) or 100

    local cache = {}  -- key -> { time = <ms>, pack = pack(...) }
    local calls_since_sweep = 0
    local timer  -- optional uv timer for background cleanup

    -- Sweeper: remove expired entries.
    local function sweep_expired()
        if ttl_ms <= 0 then
            -- No caching; nothing to sweep
            return
        end
        local now = vim.uv.now()
        for k, entry in pairs(cache) do
            if (now - entry.time) >= ttl_ms then
                cache[k] = nil
            end
        end
    end

    -- Start background cleaner if requested.
    if cleanup_ms > 0 and ttl_ms > 0 then
        timer = vim.uv.new_timer()
        timer:start(cleanup_ms, cleanup_ms, function()
            -- Run sweeps on libuv thread; safe as we only modify local table.
            sweep_expired()
        end)
        -- Stop timer on Neovim exit.
        pcall(vim.api.nvim_create_autocmd, "VimLeavePre", {
            callback = function()
                if timer then
                    timer:stop()
                    timer:close()
                    timer = nil
                end
            end,
            once = true,
        })
    end

    -- The memoized wrapper
    return function(...)
        if ttl_ms <= 0 then
            -- Caching disabled; just call through
            return func(...)
        end

        local key = key_fn(...)
        local now = vim.uv.now()
        local entry = cache[key]

        -- Hit within TTL -> return cached
        if entry and (now - entry.time) < ttl_ms then
            return unpack_fn(entry.pack, 1, entry.pack.n)
        end

        -- Miss or expired -> recompute & store
        local result = pack(func(...))
        cache[key] = { time = now, pack = result }

        -- Opportunistic cleanup if no timer
        if not timer then
            calls_since_sweep = calls_since_sweep + 1
            if calls_since_sweep >= opportunistic_every then
                calls_since_sweep = 0
                sweep_expired()
            end
        end

        return unpack_fn(result, 1, result.n)
    end
end


function M.insert_unique_by(t, value, eq)
    for _, v in ipairs(t) do
        if eq(v, value) then
            return false
        end
    end
    table.insert(t, value)
    return true
end


function M.normalize_path_separator(path)
    if env.os.win then
        return path:gsub("/", "\\")
    end
    return path:gsub("\\", "/")
end


function M.serialize(tbl, indent)
    indent = indent or 0
    local pad = string.rep(" ", indent)
    local lines = { "{" }
    for k, v in pairs(tbl) do
        local key = type(k) == "string" and k or ("[" .. tostring(k) .. "]")
        local value
        if type(v) == "table" then
            value = M.serialize(v, indent + 2)
        elseif type(v) == "string" then
            value = string.format("%q", v)
        else
            value = tostring(v)
        end
        table.insert(lines, string.format("%s  %s = %s,", pad, key, value))
    end
    table.insert(lines, pad .. "}")
    return table.concat(lines, "\n")
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
