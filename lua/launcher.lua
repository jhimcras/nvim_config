local M = {}

local pr = require'prjroot'
local ut = require'util'
local env = require 'env'
local api = vim.api
local buffers_handles = {}
local launcher_timers = {}
M.running_processes = {}

local function SetBufLines(buf, start, end_, strict, lines)
    if not api.nvim_buf_is_valid(buf) then return end
    local modifiable = api.nvim_buf_get_option(buf, 'modifiable')
    api.nvim_buf_set_option(buf, 'modifiable', true)
    api.nvim_buf_set_lines(buf, start, end_, strict, lines)
    api.nvim_buf_set_option(buf, 'modifiable', modifiable)
end

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

function M.set_launcher_mapping(buf)
    ut.nnoremap('gq', CloseLauncherBuffer, { buffer = buf })
    ut.nnoremap(']e', [[<cmd>lua require'launcher'.NextMatch()<cr>]], { buffer = buf })
    ut.nnoremap('[e', [[<cmd>lua require'launcher'.PrevMatch()<cr>]], { buffer = buf })
    ut.nnoremap('<cr>', [[<cmd>lua require'launcher'.Jump()<cr>]], { buffer = buf })
    ut.nnoremap('<c-c>', [[<cmd>lua require'launcher'.TerminateCurrentLauncherBuffer()<cr>]], { buffer = buf })
end

function M.Restore(data)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = 'nofile'
    
    local lines = data.content or {}
    api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    
    api.nvim_buf_set_var(buf, 'lc_object', data.obj)
    api.nvim_buf_set_var(buf, 'lc_command', data.cmd_full or data.cmd)
    api.nvim_buf_set_var(buf, 'prjroot_folder', data.prjroot)
    api.nvim_buf_set_var(buf, 'launcher_status', data.status or 'done')
    api.nvim_buf_set_var(buf, 'launcher_matches', data.matches or {})
    api.nvim_buf_set_var(buf, 'this_buf_can_be_closed', true)
    
    if data.filetype == 'terminal' then
        api.nvim_buf_set_option(buf, 'filetype', 'terminal')
    else
        api.nvim_buf_set_option(buf, 'filetype', 'launcher')
    end
    
    api.nvim_buf_set_option(buf, 'modifiable', false)
    
    if data.prjroot then
        pr.SetBufferProjectRoot(buf, data.prjroot)
    end
    
    M.set_launcher_mapping(buf)
    
    if data.obj then
        api.nvim_buf_set_name(buf, string.format("(%d) %s", buf, data.obj))
    end
    
    return buf
end

function M.Launch(cmd, args, cwd, ev, hi, position, color_mode, existing_buf, encoding, obj, patterns)
    local prjroot_origin = pr.GetCurrentProjectRoot()
    local buf
    if existing_buf then
        buf = existing_buf
    else
        buf = ut.NewScratchBuffer(position)
    end
    api.nvim_buf_set_option(buf, 'filetype', 'launcher')
    api.nvim_buf_set_option(buf, 'modifiable', false)

    -- Initialize matches for navigation
    api.nvim_buf_set_var(buf, 'launcher_matches', {})

    -- Set a unique session token for this launch
    local session_token = {}

    -- Ensure lc_object and lc_command are set for statusline
    local success, _ = pcall(api.nvim_buf_get_var, buf, 'lc_object')
    if not success then
        api.nvim_buf_set_var(buf, 'lc_object', obj or cmd)
    end
    local full_cmd_str = cmd
    if args and #args > 0 then
        full_cmd_str = full_cmd_str .. ' ' .. table.concat(args, ' ')
    end
    api.nvim_buf_set_var(buf, 'lc_command', full_cmd_str)

    local onread = function(err, data)
        if not M.running_processes[buf] or M.running_processes[buf].session_token ~= session_token then return end
        if err then
            api.nvim_buf_call(buf, function()
                if not api.nvim_buf_is_valid(buf) then return end
                if not M.running_processes[buf] or M.running_processes[buf].session_token ~= session_token then return end

                local line_count = api.nvim_buf_line_count(buf)
                local wins = vim.fn.win_findbuf(buf)
                local scroll_wins = {}
                for _, w in ipairs(wins) do
                    if api.nvim_win_get_cursor(w)[1] == line_count then
                        table.insert(scroll_wins, w)
                    end
                end

                SetBufLines(buf, -2, -1, false, {'Error reading output: ' .. err})
                api.nvim_buf_set_var(buf, 'launcher_failed', true)
                api.nvim_buf_set_var(buf, 'this_buf_can_be_closed', true)

                local new_line_count = api.nvim_buf_line_count(buf)
                for _, w in ipairs(scroll_wins) do
                    if api.nvim_win_is_valid(w) then
                        api.nvim_win_set_cursor(w, {new_line_count, 0})
                    end
                end
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
                if not M.running_processes[buf] or M.running_processes[buf].session_token ~= session_token then return end

                local line_count = api.nvim_buf_line_count(buf)
                local wins = vim.fn.win_findbuf(buf)
                local scroll_wins = {}
                for _, w in ipairs(wins) do
                    if api.nvim_win_get_cursor(w)[1] == line_count then
                        table.insert(scroll_wins, w)
                    end
                end

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

                SetBufLines(buf, -2, -1, false, processed_lines)

                -- Apply ANSI highlights
                if color_mode == 'use' then
                    for i, line_highlights in ipairs(highlight_data) do
                        local lnum = start_line + i - 1
                        for _, hl in ipairs(line_highlights) do
                            api.nvim_buf_add_highlight(buf, -1, hl[3], lnum, hl[1], hl[2])
                        end
                    end
                end

                -- Apply custom patterns
                if patterns then
                    local matches = api.nvim_buf_get_var(buf, 'launcher_matches')
                    for i, line in ipairs(processed_lines) do
                        local lnum = start_line + i - 1
                        for _, pcfg in pairs(patterns) do
                            local m = { line:match(pcfg.pattern) }
                            if #m > 0 then
                                -- Extract metadata
                                local match_info = { lnum = lnum + 1 }
                                if pcfg.extract then
                                    for idx, field in ipairs(pcfg.extract) do
                                        if field ~= '' and m[idx] then
                                            match_info[field] = m[idx]
                                        end
                                    end
                                end
                                table.insert(matches, match_info)

                                -- Apply highlights
                                if pcfg.highlight then
                                    local s, e, c1, c2, c3, c4, c5, c6, c7, c8, c9 = line:find(pcfg.pattern)
                                    local captures = { [0] = {s, e}, c1, c2, c3, c4, c5, c6, c7, c8, c9 }
                                    
                                    -- When there are captures, the first N values returned by find (after s, e) are the capture strings OR positions if requested.
                                    -- Wait, Lua's line:find returns capture strings if they exist.
                                    -- To get POSITIONS of captures, we need to use () in the pattern as an empty capture.
                                    -- BUT, if we use the user's pattern, we can't easily get positions.
                                    -- Alternative: use vim.regex if available, or just search for the capture string within the match.
                                    
                                    for hl_idx, hl_group_or_color in pairs(pcfg.highlight) do
                                        local hl_group = hl_group_or_color
                                        if hl_group_or_color:match('^#') then
                                            hl_group = 'LauncherHL_' .. hl_group_or_color:sub(2)
                                            api.nvim_set_hl(0, hl_group, { fg = hl_group_or_color })
                                        end

                                        if hl_idx == 0 then
                                            if s and e then
                                                api.nvim_buf_add_highlight(buf, -1, hl_group, lnum, s - 1, e)
                                            end
                                        elseif m[hl_idx] then
                                            -- Search for the exact capture string within the matched portion of the line
                                            local cap_str = m[hl_idx]
                                            local search_area = line:sub(s, e)
                                            local cap_s, cap_e = search_area:find(cap_str, 1, true) -- plain search
                                            if cap_s then
                                                api.nvim_buf_add_highlight(buf, -1, hl_group, lnum, s + cap_s - 2, s + cap_e - 1)
                                            end
                                        end
                                    end
                                end
                            end
                        end
                    end
                    api.nvim_buf_set_var(buf, 'launcher_matches', matches)
                end

                local new_line_count = api.nvim_buf_line_count(buf)
                for _, w in ipairs(scroll_wins) do
                    if api.nvim_win_is_valid(w) then
                        api.nvim_win_set_cursor(w, {new_line_count, 0})
                    end
                end
            end)
            append_result()
        end
    end
    local on_exit = function(code, signal)
        if not M.running_processes[buf] or M.running_processes[buf].session_token ~= session_token then return end
        if not api.nvim_buf_is_valid(buf) then return end

        M.running_processes[buf] = nil
        local line_count = api.nvim_buf_line_count(buf)
        local wins = vim.fn.win_findbuf(buf)
        local scroll_wins = {}
        for _, w in ipairs(wins) do
            if api.nvim_win_get_cursor(w)[1] == line_count then
                table.insert(scroll_wins, w)
            end
        end

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
        SetBufLines(buf, -2, -1, false, {end_text})
        api.nvim_buf_set_var(buf, 'this_buf_can_be_closed', true)
        vim.cmd('redrawstatus!')

        local new_line_count = api.nvim_buf_line_count(buf)
        for _, w in ipairs(scroll_wins) do
            if api.nvim_win_is_valid(w) then
                api.nvim_win_set_cursor(w, {new_line_count, 0})
            end
        end
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
    -- Move cursor to the bottom at the start of execution
    api.nvim_win_set_cursor(win, {api.nvim_buf_line_count(buf), 0})

    if prjroot_origin then
        pr.SetBufferProjectRoot(buf, prjroot_origin)
        api.nvim_buf_set_var(buf, 'prjroot_folder', prjroot_origin)
    end
    M.set_launcher_mapping(buf)

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
            args = args,
            session_token = session_token
        }
    else
        local err_msg = 'Failed to start process: ' .. tostring(err or pid or 'unknown')
        SetBufLines(buf, -1, -1, false, {err_msg})
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

    -- Set a unique session token for this terminal launch
    local session_token = {}

    api.nvim_buf_set_var(buf, 'lc_object', obj or cmd)
    local full_cmd_str = cmd
    if args and #args > 0 then
        full_cmd_str = full_cmd_str .. ' ' .. table.concat(args, ' ')
    end
    api.nvim_buf_set_var(buf, 'lc_command', full_cmd_str)
    api.nvim_buf_set_var(buf, 'launcher_status', 'running')
    if prjroot_origin then
        pr.SetBufferProjectRoot(buf, prjroot_origin)
        api.nvim_buf_set_var(buf, 'prjroot_folder', prjroot_origin)
    end
    M.set_launcher_mapping(buf)

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
                if not M.running_processes[buf] or M.running_processes[buf].session_token ~= session_token then return end
                if not api.nvim_buf_is_valid(buf) then return end

                M.running_processes[buf] = nil
                api.nvim_buf_set_var(buf, 'launcher_status', (code == 0) and 'done' or 'terminated')
                api.nvim_buf_set_var(buf, 'this_buf_can_be_closed', true)
                vim.cmd('redrawstatus!')
            end
        })
    end)

    M.running_processes[buf] = {
        type = 'terminal',
        job_id = job_id,
        obj = obj,
        cmd = cmd,
        args = args,
        buf = buf,
        session_token = session_token
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
        if type(cmd) == 'function' then
            cmd()
            return
        end
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
            local full_cmd = cmd
            local full_args = {}
            if env.os.win then
                full_cmd = 'cmd'
                full_args = { '/c', 'start', '/WAIT', 'cmd', '/c', cmd }
                for _, a in ipairs(args or {}) do table.insert(full_args, a) end
            else
                local terms = { 'x-terminal-emulator', 'xterm', 'gnome-terminal', 'konsole', 'xfce4-terminal', 'alacritty', 'kitty' }
                local term = nil
                for _, t in ipairs(terms) do
                    if vim.fn.executable(t) == 1 then
                        term = t
                        break
                    end
                end

                if term then
                    full_cmd = term
                    if term == 'gnome-terminal' then
                        full_args = { '--wait', '--', cmd }
                    elseif term == 'konsole' then
                        full_args = { '--hold', '-e', cmd }
                    else
                        full_args = { '-e', cmd }
                    end
                    for _, a in ipairs(args or {}) do table.insert(full_args, a) end
                else
                    vim.notify("No terminal emulator found for external mode", vim.log.levels.ERROR)
                    return
                end
            end

            local proc_key
            local on_exit = function(code, signal)
                if proc_key then
                    M.UnregisterProcess(proc_key)
                end
            end
            local pid, terminate_fn, get_status, handle = ut.AsyncProcess(full_cmd, full_args, cwd, { env = ev, onexit = on_exit })
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
                    local choice = vim.fn.confirm(string.format('Process [%s] is still running. Replace?', obj), "&Yes\n&No", 2)
                    if choice ~= 1 then
                        -- If it's already visible, focus it
                        local wins = vim.fn.win_findbuf(existing_buf)
                        if #wins > 0 then
                            vim.api.nvim_set_current_win(wins[1])
                        end
                        return
                    end

                    if proc.type == 'terminal' then
                        vim.fn.jobstop(proc.job_id)
                    elseif proc.handle and not proc.handle:is_closing() then
                        proc.handle:kill(15)
                    end
                    M.running_processes[existing_buf] = nil
                end

                -- Clear the buffer content
                local ft = vim.api.nvim_get_option_value('filetype', { buf = existing_buf })
                if ft ~= 'terminal' then
                    SetBufLines(existing_buf, 0, -1, false, {})
                end

                -- If the buffer is hidden, display it again in the current tab
                local wins = vim.fn.win_findbuf(existing_buf)
                if #wins == 0 then
                    local buf = ut.NewScratchBuffer(position)
                    vim.api.nvim_win_set_buf(vim.api.nvim_get_current_win(), existing_buf)
                    -- Close the scratch buffer that was just created but not needed because we're reusing existing_buf
                    vim.api.nvim_buf_delete(buf, {force = true})
                else
                    -- If it's already visible, focus it (maintains window)
                    vim.api.nvim_set_current_win(wins[1])
                end
            end

            local buf
            if mode == 'terminal' then
                buf = M.LaunchOnTerm(cmd, args, cwd, ev, position, obj, existing_buf)
            else
                buf = M.Launch(cmd, args, cwd, ev, hi, position, color_mode, existing_buf, encoding, obj, lcfg.patterns)
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

function M.NextMatch()
    local success, matches = pcall(api.nvim_buf_get_var, 0, 'launcher_matches')
    if not success or not matches then return end
    local cur_line = api.nvim_win_get_cursor(0)[1]
    for _, m in ipairs(matches) do
        if m.lnum > cur_line then
            api.nvim_win_set_cursor(0, { m.lnum, 0 })
            return
        end
    end
    -- Wrap around
    if #matches > 0 then
        api.nvim_win_set_cursor(0, { matches[1].lnum, 0 })
    end
end

function M.PrevMatch()
    local success, matches = pcall(api.nvim_buf_get_var, 0, 'launcher_matches')
    if not success or not matches then return end
    local cur_line = api.nvim_win_get_cursor(0)[1]
    for i = #matches, 1, -1 do
        local m = matches[i]
        if m.lnum < cur_line then
            api.nvim_win_set_cursor(0, { m.lnum, 0 })
            return
        end
    end
    -- Wrap around
    if #matches > 0 then
        api.nvim_win_set_cursor(0, { matches[#matches].lnum, 0 })
    end
end

function M.Jump()
    local success, matches = pcall(api.nvim_buf_get_var, 0, 'launcher_matches')
    local cur_line = api.nvim_win_get_cursor(0)[1]
    local match = nil
    if success and matches then
        for _, m in ipairs(matches) do
            if m.lnum == cur_line then
                match = m
                break
            end
        end
    end

    if not match then
        -- Try to parse current line directly if not in matches
        local line = api.nvim_get_current_line()
        local prjroot = vim.b.prjroot_folder or pr.GetCurrentProjectRoot()
        local c = pr.GetPrjrootConfig(prjroot)
        local obj = vim.b.lc_object
        if c and c.launchers and c.launchers[obj] and c.launchers[obj].patterns then
            for _, pcfg in pairs(c.launchers[obj].patterns) do
                local m = { line:match(pcfg.pattern) }
                if #m > 0 and pcfg.extract then
                    match = {}
                    for idx, field in ipairs(pcfg.extract) do
                        if field ~= '' and m[idx] then
                            match[field] = m[idx]
                        end
                    end
                    break
                end
            end
        end
        -- Legacy support for jmp pattern
        if not match and c and c.launchers and c.launchers[obj] and c.launchers[obj].jmp then
            local jmp = c.launchers[obj].jmp
            local m = { line:match(jmp.pattern) }
            if jmp.file and m[jmp.file] then
                match = {
                    filename = m[jmp.file],
                    row = jmp.row and m[jmp.row] or 1,
                    column = jmp.col and m[jmp.col] or 1
                }
            end
        end
    end

    if match and match.filename then
        local parent_win = vim.b.lc_parent_win
        if parent_win and api.nvim_win_is_valid(parent_win) then
            api.nvim_set_current_win(parent_win)
        else
            -- If parent window is gone, try to find a suitable one
            vim.cmd('wincmd p')
        end
        
        local prjroot = vim.b.prjroot_folder or pr.GetCurrentProjectRoot()
        local filename = vim.fn.fnamemodify(match.filename, ':p')
        if not ut.IsExist(filename) and prjroot then
            filename = vim.fn.fnamemodify(prjroot .. '/' .. match.filename, ':p')
        end

        local edit_cmd = string.format('edit +%s %s', match.row or 1, vim.fn.fnameescape(filename))
        vim.cmd(edit_cmd)
        if match.column then
            api.nvim_win_set_cursor(0, { tonumber(match.row or 1), tonumber(match.column) - 1 })
        end
    end
end

function M.WipeLauncherBuffers()
    local prjroot = pr.GetCurrentProjectRoot()
    if not prjroot then return end
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_valid(buf) then
            local success, buf_prj = pcall(api.nvim_buf_get_var, buf, 'prjroot_folder')
            if success and buf_prj == prjroot then
                vim.api.nvim_buf_delete(buf, { force = true })
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
    api.nvim_create_user_command('WipeLauncherBuffers', M.WipeLauncherBuffers, {})
    ut.nnoremap('<leader>lc', M.WipeLauncherBuffers)
    api.nvim_create_autocmd({'BufRead', 'BufNew'}, {callback = BufMapping})

    api.nvim_create_autocmd('BufWipeout', {
        callback = function(args)
            local buf = args.buf
            local proc = M.running_processes[buf]
            if proc then
                if proc.type == 'terminal' then
                    vim.fn.jobstop(proc.job_id)
                elseif proc.handle and not proc.handle:is_closing() then
                    if type(proc.handle.kill) == 'function' then
                        proc.handle:kill(15)
                    end
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
