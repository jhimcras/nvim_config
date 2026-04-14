local M = {}

local pr = require'prjroot'
local ut = require'util'
local env = require 'env'
local api = vim.api
local buffers_handles = {}
local launcher_timers = {}
M.running_processes = {}

-- TODO: check whether the thread actually processing
local function CloseLauncherBuffer()
    local buf = vim.api.nvim_get_current_buf()
    local success, failed = pcall(api.nvim_buf_get_var, buf, 'launcher_failed')
    local success2, closed = pcall(api.nvim_buf_get_var, buf, 'this_buf_can_be_closed')

    if (success2 and closed) or (success and failed) then
        vim.cmd.bwipeout { bang = true }
    else
        vim.notify('This process is not closed yet.', vim.log.levels.WARN)
    end
end

local function set_launcher_mapping(buf)
    ut.nnoremap('gq', CloseLauncherBuffer, { buffer = buf })
    -- ut.nnoremap('e', [[gg/error<cr>]], { buffer = buf })
    -- ut.nnoremap('w', [[gg/warning<cr>]], { buffer = buf })
    -- ut.nnoremap('<cr>', [[<cmd>lua require'launcher'.Jump()<cr>]], { buffer = buf })
    ut.nnoremap('<c-c>', [[<cmd>lua require'launcher'.TerminateCurrentLauncherBuffer()<cr>]], { buffer = buf })
end

function M.Launch(cmd, args, cwd, ev, hi, position, color_mode, existing_buf, encoding, obj)
    local prjroot_origin = pr.GetCurrentProjectRoot()
    local buf
    if existing_buf then
        buf = existing_buf
    else
        buf = ut.NewScratchBuffer(position)
    end
    api.nvim_buf_set_option(buf, 'filetype', 'launcher')

    -- Ensure lc_object is set for statusline
    local success, _ = pcall(api.nvim_buf_get_var, buf, 'lc_object')
    if not success then
        api.nvim_buf_set_var(buf, 'lc_object', obj or cmd)
    end

    local onread = function(err, data)
        if err then
            api.nvim_buf_call(buf, function()
                api.nvim_buf_set_lines(buf, -2, -1, false, {'Error reading output: ' .. err})
                api.nvim_buf_set_var(buf, 'launcher_failed', true)
                api.nvim_buf_set_var(buf, 'this_buf_can_be_closed', true)
            end)
            return
        end
        if data then
            if encoding and encoding ~= 'utf-8' and type(data) == 'string' then
                data = vim.iconv(data, encoding, 'utf-8')
            end
            local results = vim.split(tostring(data), env.new_line_char)
            local append_result = vim.schedule_wrap(function()
                if not api.nvim_buf_is_valid(buf) then return end
                -- (rest of the logic remains the same)
                local processed_lines = results
                local highlight_data = {}

                if color_mode == 'use' or color_mode == 'mono' then
                    local ansi = require('ansi_parser')
                    processed_lines = {}
                    for i, line in ipairs(results) do
                        local cleaned, highlights = ansi.parse_ansi(line)
                        processed_lines[i] = cleaned
                        if color_mode == 'use' then
                            highlight_data[i] = highlights
                        end
                    end
                end

                local start_line = api.nvim_buf_line_count(buf) - 1
                local last_line = api.nvim_buf_get_lines(buf, -2, -1, false)
                processed_lines[1] = (last_line[1] or '') .. processed_lines[1]

                -- Adjust the first line's highlights if we prepended to an existing line
                if color_mode == 'use' and last_line[1] and #last_line[1] > 0 and highlight_data[1] then
                    for _, hl in ipairs(highlight_data[1]) do
                        hl[1] = hl[1] + #last_line[1]
                        hl[2] = hl[2] + #last_line[1]
                    end
                end

                api.nvim_buf_set_lines(buf, -2, -1, false, processed_lines)

                if color_mode == 'use' then
                    for i, line_highlights in ipairs(highlight_data) do
                        local lnum = start_line + i - 1
                        for _, hl in ipairs(line_highlights) do
                            api.nvim_buf_add_highlight(buf, -1, hl[3], lnum, hl[1], hl[2])
                        end
                    end
                end

                -- local buf_line_count = api.nvim_buf_line_count(buf)
                -- api.nvim_win_set_cursor(win, {buf_line_count,0})
            end)
            append_result()
        end
    end
    local on_exit = function(code, signal)
        M.running_processes[buf] = nil
        if not api.nvim_buf_is_valid(buf) then return end

        -- Stop spinner timer
        local timer = launcher_timers[buf]
        if timer then
            timer:stop()
            timer:close()
            launcher_timers[buf] = nil
        end

        local status = (code == 0 and signal == 0) and 'done' or 'terminated'
        api.nvim_buf_set_var(buf, 'launcher_status', status)

        local end_text = string.format('---- End [code %d] [signal %d]', code, signal)
        api.nvim_buf_set_lines(buf, -2, -1, false, {end_text})
        api.nvim_buf_set_var(buf, 'this_buf_can_be_closed', true)
        vim.cmd('redrawstatus!')
    end

    -- Start spinner timer
    api.nvim_buf_set_var(buf, 'launcher_status', 'running')
    local timer = vim.uv.new_timer()
    timer:start(0, 120, vim.schedule_wrap(function()
        if api.nvim_buf_is_valid(buf) then
            vim.cmd('redrawstatus!')
        else
            timer:stop()
            timer:close()
            launcher_timers[buf] = nil
        end
    end))
    launcher_timers[buf] = timer

    local win = api.nvim_get_current_win()
    if prjroot_origin then
        pr.SetBufferProjectRoot(buf, prjroot_origin)
        api.nvim_buf_set_var(buf, 'prjroot_folder', prjroot_origin)
    end
    set_launcher_mapping(buf)

    local ok, pid, terminate_fn, get_status, handle, err = pcall(ut.AsyncProcess, cmd, args, cwd, { env = ev, onread = onread, onexit = on_exit })

    if ok and handle then
        buffers_handles[buf] = handle
        api.nvim_buf_set_var(buf, 'launcher_terminate_fn', terminate_fn)
        M.running_processes[buf] = {
            type = 'general',
            handle = handle,
            pid = pid,
            obj = obj,
            cmd = cmd,
            args = args
        }
    else
        local err_msg = 'Failed to start process: ' .. tostring(err or pid or 'unknown')
        api.nvim_buf_set_lines(buf, -1, -1, false, {err_msg})
        api.nvim_buf_set_var(buf, 'launcher_status', 'terminated')
        api.nvim_buf_set_var(buf, 'launcher_failed', true)
        api.nvim_buf_set_var(buf, 'this_buf_can_be_closed', true)

        -- Stop timer if failed to start
        if launcher_timers[buf] then
            launcher_timers[buf]:stop()
            launcher_timers[buf]:close()
            launcher_timers[buf] = nil
        end
        M.running_processes[buf] = nil
        vim.cmd('redrawstatus!')
    end
    return buf
end

function M.LaunchOnTerm(cmd, args, cwd, ev, position, obj, existing_buf)
    local prjroot_origin = pr.GetCurrentProjectRoot()
    local buf
    if existing_buf then
        buf = existing_buf
    else
        buf = ut.NewScratchBuffer(position)
    end
    api.nvim_buf_set_option(buf, 'filetype', 'terminal')
    api.nvim_buf_set_var(buf, 'lc_object', obj or cmd)
    api.nvim_buf_set_var(buf, 'launcher_status', 'running')
    if prjroot_origin then
        pr.SetBufferProjectRoot(buf, prjroot_origin)
        api.nvim_buf_set_var(buf, 'prjroot_folder', prjroot_origin)
    end
    set_launcher_mapping(buf)

    local term_cmd = {cmd}
    for _, a in ipairs(args or {}) do
        table.insert(term_cmd, a)
    end

    local env_dict = nil
    if ev then
        env_dict = {}
        for _, v in ipairs(ev) do
            local key, val = v:match("^([^=]+)=(.*)$")
            if key then env_dict[key] = val end
        end
    end

    local job_id = api.nvim_buf_call(buf, function()
        return vim.fn.termopen(term_cmd, {
            cwd = cwd,
            env = env_dict,
            on_exit = function(_, code, signal)
                M.running_processes[buf] = nil
                if api.nvim_buf_is_valid(buf) then
                    api.nvim_buf_set_var(buf, 'launcher_status', (code == 0) and 'done' or 'terminated')
                    api.nvim_buf_set_var(buf, 'this_buf_can_be_closed', true)
                    vim.cmd('redrawstatus!')
                end
            end
        })
    end)

    M.running_processes[buf] = {
        type = 'terminal',
        job_id = job_id,
        obj = obj,
        cmd = cmd,
        args = args,
        buf = buf
    }
    return buf
end

function M.TerminateCurrentLauncherBuffer()
    local buf = vim.api.nvim_get_current_buf()
    local proc = M.running_processes[buf]

    if proc then
        if proc.type == 'terminal' then
            vim.notify(string.format('Terminating terminal job...'), vim.log.levels.WARN)
            vim.fn.jobstop(proc.job_id)
            M.running_processes[buf] = nil
            return
        end
    end

    local handle = buffers_handles[buf]
    local success, terminate_fn = pcall(vim.api.nvim_buf_get_var, buf, 'launcher_terminate_fn')
    if success and type(terminate_fn) == 'function' then
        vim.notify(string.format('Terminating process...'), vim.log.levels.WARN)
        terminate_fn(15) -- SIGTERM
    elseif handle and not handle:is_closing() then
        vim.notify(string.format('Terminating process...'), vim.log.levels.WARN)
        handle:kill(15) -- SIGTERM
    end
end

local function FindExistingLauncherBuffer(obj, prjroot)
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_valid(buf) then
            local ft = vim.api.nvim_get_option_value('filetype', { buf = buf })
            if ft == 'launcher' or ft == 'terminal' then
                local success, buf_obj = pcall(api.nvim_buf_get_var, buf, 'lc_object')
                local success2, buf_prj = pcall(api.nvim_buf_get_var, buf, 'prjroot_folder')
                if success and buf_obj == obj and success2 and buf_prj == prjroot then
                    return buf
                end
            end
        end
    end
    return nil
end

function M.LaunchObject(obj)
    local parent_win_prjroot = pr.GetCurrentProjectRoot()
    local c = pr.GetPrjrootConfig(parent_win_prjroot)
    if c and c.launchers and c.launchers[obj] then
        local lcfg = c.launchers[obj]
        local cmd = lcfg.cmd
        local args = lcfg.args
        local hi = lcfg.highlight
        local color_mode = lcfg.color or 'use'
        local encoding = lcfg.encoding
        local cwd = (lcfg.cwd) and lcfg.cwd:gsub([[^%.]], parent_win_prjroot) or parent_win_prjroot
        local position = (lcfg.position) or { orientation = 'vertical' }
        local mode = lcfg.mode or (position == 'external' and 'external' or 'general')

        if not ut.IsExist(cwd) then
            vim.notify(string.format('"%s" is not exist', cwd), vim.log.levels.ERROR)
            return
        end
        local ev = lcfg.env
        if ev then
            local env_cmd = {}
            for key, val in pairs(ev) do
                env_cmd[#env_cmd+1] = string.format("%s=%s", key, val)
            end
            ev = env_cmd
        end

        if mode == 'external' then
            local proc_key
            local on_exit = function(code, signal)
                if proc_key then
                    M.UnregisterProcess(proc_key)
                end
            end
            local pid, terminate_fn, get_status, handle = ut.AsyncProcess(cmd, args, cwd, { env = ev, onexit = on_exit })
            proc_key = "ext_" .. (pid or "unknown")
            M.running_processes[proc_key] = {
                type = 'external',
                pid = pid,
                handle = handle,
                obj = obj,
                cmd = cmd,
                args = args
            }
        else
            local parent_win = vim.api.nvim_get_current_win()
            local existing_buf = FindExistingLauncherBuffer(obj, parent_win_prjroot)

            if existing_buf then
                -- Terminate any process currently in that buffer
                local proc = M.running_processes[existing_buf]
                if proc then
                    if proc.type == 'terminal' then
                        vim.fn.jobstop(proc.job_id)
                    elseif proc.handle and not proc.handle:is_closing() then
                        proc.handle:kill(15)
                    end
                    M.running_processes[existing_buf] = nil
                end

                -- Clear the buffer content (only for non-terminal, terminal clears on termopen)
                local ft = vim.api.nvim_get_option_value('filetype', { buf = existing_buf })
                if ft ~= 'terminal' then
                    api.nvim_buf_set_lines(existing_buf, 0, -1, false, {})
                end

                -- If the buffer is hidden, display it again in the current tab
                local wins = vim.fn.win_findbuf(existing_buf)
                if #wins == 0 then
                    if position and position.orientation == 'vertical' then
                        vim.cmd((position.size or '') .. ' vsplit')
                    elseif position and position.orientation == 'horizontal' then
                        vim.cmd('botright ' .. (position.size or '') .. ' split')
                    else
                        vim.cmd('vsplit')
                    end
                    vim.api.nvim_set_current_buf(existing_buf)
                else
                    -- If it's already visible, focus it (maintains window)
                    vim.api.nvim_set_current_win(wins[1])
                end
            end

            local buf
            if mode == 'terminal' then
                buf = M.LaunchOnTerm(cmd, args, cwd, ev, position, obj, existing_buf)
            else
                buf = M.Launch(cmd, args, cwd, ev, hi, position, color_mode, existing_buf, encoding, obj)
            end

            if not existing_buf then
                api.nvim_buf_set_name(buf, string.format("(%d) %s", buf, obj))
                api.nvim_buf_set_var(buf, 'lc_object', obj)
            end

            api.nvim_buf_set_var(buf, 'lc_parent_win', parent_win)
            api.nvim_buf_set_var(buf, 'prjroot_folder', parent_win_prjroot)
        end
    end
end

local function BufMapping()
    local c = pr.GetCurrentConfig()
    if c and c.launchers then
        for key, val in pairs(c.launchers) do
            if val.key then
                ut.nnoremap(val.key, function() M.LaunchObject(key) end)
            end
        end
    end
end

-- WIP
function M.Jump()
    local c = pr.GetPrjrootConfig(vim.b.prjroot_folder)
    local obj = vim.b.lc_object
    local cwd = (c[obj].cwd) and c[obj].cwd:gsub([[^%.]], vim.b.prjroot_folder) or vim.b.prjroot_folder
    if obj and c[obj] then
        local jmp = c[obj].jmp
        if jmp and jmp.pattern then
            local cur_line = api.nvim_get_current_line()
            local m = { cur_line:match(jmp.pattern) }
            if jmp.file and m[jmp.file] then
                vim.api.nvim_set_current_win(vim.b.lc_parent_win)
                local filename = vim.fn.fnamemodify(cwd, ':p') .. m[jmp.file]
                vim.cmd('execute "edit +' .. m[jmp.row] .. ' ' .. filename .. '"')
            end
        end
    end
end

function M.GetLauncherList()
    local parent_win_prjroot = pr.GetCurrentProjectRoot()
    local c = pr.GetPrjrootConfig(parent_win_prjroot)
    if c and c.launchers then
        local launcher_list = {}
        for launcher_name, _ in pairs(c.launchers) do
            launcher_list[#launcher_list+1] = launcher_name
        end
        return launcher_list
    end
end

function M.GetRunningProcesses()
    local processes = {}
    for k, v in pairs(M.running_processes) do
        local p = vim.tbl_extend('force', v, { key = k })
        table.insert(processes, p)
    end
    return processes
end

function M.RegisterProcess(key, proc_info)
    M.running_processes[key] = proc_info
end

function M.UnregisterProcess(key)
    M.running_processes[key] = nil
end

function M.ShowProcessList()
    require('process_list').Show()
end

function M.setup()
    api.nvim_create_user_command('ProcessList', M.ShowProcessList, {})
    api.nvim_create_autocmd({'BufRead', 'BufNew'}, {callback = BufMapping})

    api.nvim_create_autocmd('BufWipeout', {
        callback = function(args)
            local buf = args.buf
            local proc = M.running_processes[buf]
            if proc then
                if proc.type == 'terminal' then
                    vim.fn.jobstop(proc.job_id)
                elseif proc.handle and not proc.handle:is_closing() then
                    proc.handle:kill(15)
                end
                M.running_processes[buf] = nil
            end

            local timer = launcher_timers[buf]
            if timer then
                if not timer:is_closing() then
                    timer:stop()
                    timer:close()
                end
                launcher_timers[buf] = nil
            end
        end
    })

    -- Initialize ANSI highlight groups
    local set_hl = vim.api.nvim_set_hl
    set_hl(0, 'AnsiBlack',   { fg = '#000000', bold = true })
    set_hl(0, 'AnsiRed',     { fg = '#ff5555' })
    set_hl(0, 'AnsiGreen',   { fg = '#50fa7b' })
    set_hl(0, 'AnsiYellow',  { fg = '#f1fa8c' })
    set_hl(0, 'AnsiBlue',    { fg = '#8be9fd' })
    set_hl(0, 'AnsiMagenta', { fg = '#ff79c6' })
    set_hl(0, 'AnsiCyan',    { fg = '#8be9fd' })
    set_hl(0, 'AnsiWhite',   { fg = '#f8f8f2' })
end

return M
