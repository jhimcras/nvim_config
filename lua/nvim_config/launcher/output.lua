local M = {}

local registry = require('nvim_config.launcher.registry')
local running_processes = registry.processes
local api = vim.api
local pr = require('nvim_config.prjroot')
local util_buffer = require('nvim_config.util.buffer')
local util_job = require('nvim_config.util.job')
local env = require('nvim_config.env')
local guard = require('nvim_config.launcher.guard')
local buffers_handles = {}
local launcher_timers = {}
local spinner = require('nvim_config.spinner')
local launcher_highlight_ns = api.nvim_create_namespace('launcher_highlights')

local function SetBufLines(buf, start, end_, strict, lines)
    if not api.nvim_buf_is_valid(buf) then return end
    local modifiable = api.nvim_get_option_value('modifiable', { buf = buf })
    api.nvim_set_option_value('modifiable', true, { buf = buf })
    api.nvim_buf_set_lines(buf, start, end_, strict, lines)
    api.nvim_set_option_value('modifiable', modifiable, { buf = buf })
end

local function AddHighlight(buf, hl_group, lnum, col_start, col_end)
    vim.hl.range(buf, launcher_highlight_ns, hl_group, { lnum, col_start }, { lnum, col_end }, {})
end

function M.GetHighlights(buf)
    local highlights = {}
    for _, mark in ipairs(api.nvim_buf_get_extmarks(buf, launcher_highlight_ns, 0, -1, { details = true })) do
        local details = mark[4]
        if details.hl_group then
            highlights[#highlights + 1] = { mark[2], mark[3], details.end_col, details.hl_group }
        end
    end
    return highlights
end

local function SafeCloseTimer(buf)
    spinner.stop(launcher_timers[buf])
    launcher_timers[buf] = nil
end

M.set_buf_lines = SetBufLines

function M.Restore(data)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = 'nofile'
    vim.bo[buf].bufhidden = 'hide'
    
    local lines = data.content or {}
    api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    for _, hl in ipairs(data.highlights or {}) do
        local color = hl[4]:match('^LauncherHL_(%x+)$')
        if color then
            api.nvim_set_hl(0, hl[4], { fg = '#' .. color })
        end
        AddHighlight(buf, hl[4], hl[1], hl[2], hl[3])
    end
    
    api.nvim_buf_set_var(buf, 'lc_object', data.obj)
    api.nvim_buf_set_var(buf, 'lc_command', data.cmd_full or data.cmd)
    api.nvim_buf_set_var(buf, 'prjroot_folder', data.prjroot)
    api.nvim_buf_set_var(buf, 'launcher_status', data.status == 'running' and 'terminated' or (data.status or 'done'))
    api.nvim_buf_set_var(buf, 'launcher_matches', data.matches or {})
    api.nvim_buf_set_var(buf, 'this_buf_can_be_closed', true)
    
    if data.filetype == 'terminal' then
        api.nvim_set_option_value('filetype', 'terminal', { buf = buf })
    else
        api.nvim_set_option_value('filetype', 'launcher', { buf = buf })
    end
    
    api.nvim_set_option_value('modifiable', false, { buf = buf })
    
    if data.prjroot then
        pr.SetBufferProjectRoot(buf, data.prjroot)
    end
    
    guard.set_launcher_mapping(buf, M.TerminateCurrentLauncherBuffer)
    
    if data.obj then
        local name = string.format("(%d) %s", buf, data.obj)
        while vim.fn.bufnr(name) ~= -1 do
            name = name .. ' [restored]'
        end
        api.nvim_buf_set_name(buf, name)
    end
    
    return buf
end

local function FollowingWindows(buf)
    local line_count = api.nvim_buf_line_count(buf)
    local wins = vim.fn.win_findbuf(buf)
    local scroll_wins = {}
    for _, w in ipairs(wins) do
        if api.nvim_win_get_cursor(w)[1] == line_count then
            table.insert(scroll_wins, w)
        end
    end
    return scroll_wins
end

local function ScrollWindows(buf, scroll_wins)
    local new_line_count = api.nvim_buf_line_count(buf)
    for _, w in ipairs(scroll_wins) do
        if api.nvim_win_is_valid(w) then
            api.nvim_win_set_cursor(w, {new_line_count, 0})
        end
    end
end

local function ParseOutput(results, color_mode)
    local processed_lines = results
    local highlight_data = {}

    if color_mode == 'use' or color_mode == 'mono' then
        local ansi = require('nvim_config.ansi_parser')
        processed_lines = {}
        for i, line in ipairs(results) do
            local cleaned, highlights = ansi.parse_ansi(line)
            processed_lines[i] = cleaned
            if color_mode == 'use' then
                highlight_data[i] = highlights
            end
        end
    end

    return processed_lines, highlight_data
end

local function ApplyPatterns(buf, processed_lines, start_line, patterns, matches, pattern_highlight_groups)
    -- Apply custom patterns
    if patterns then
        for i, line in ipairs(processed_lines) do
            local lnum = start_line + i - 1
            for _, pcfg in pairs(patterns) do
                local m = { line:match(pcfg.pattern) }
                if #m > 0 then
                    -- Metadata
                    local match_info = { lnum = lnum + 1 }
                    if pcfg.extract then
                        for idx, field in ipairs(pcfg.extract) do
                            if field ~= '' and m[idx] then
                                match_info[field] = m[idx]
                            end
                        end
                    end
                    if pcfg.base_dir then
                        match_info.base_dir = pcfg.base_dir(match_info, line)
                    end
                    table.insert(matches, match_info)

                    -- Apply highlights
                    if pcfg.highlight then
                        local s, e, c1, c2, c3, c4, c5, c6, c7, c8, c9 = line:find(pcfg.pattern)
                        local captures = { [0] = {s, e}, c1, c2, c3, c4, c5, c6, c7, c8, c9 }

                        -- find returns capture strings, not positions;
                        -- locate each inside the matched span.

                        for hl_idx, hl_group_or_color in pairs(pcfg.highlight) do
                            local hl_group = hl_group_or_color
                            if hl_group_or_color:match('^#') then
                                hl_group = 'LauncherHL_' .. hl_group_or_color:sub(2)
                                if not pattern_highlight_groups[hl_group] then
                                    api.nvim_set_hl(0, hl_group, { fg = hl_group_or_color })
                                    pattern_highlight_groups[hl_group] = true
                                end
                            end

                            if hl_idx == 0 then
                                if s and e then
                                    AddHighlight(buf, hl_group, lnum, s - 1, e)
                                end
                            elseif m[hl_idx] then
                                -- Locate the capture inside the match
                                local cap_str = m[hl_idx]
                                local search_area = line:sub(s, e)
                                local cap_s, cap_e = search_area:find(cap_str, 1, true)
                                if cap_s then
                                    AddHighlight(buf, hl_group, lnum, s + cap_s - 2, s + cap_e - 1)
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end

local function CreateOutputCallbacks(buf, session_token, encoding, color_mode, patterns)
    local matches = {}
    local pattern_highlight_groups = {}
    local pending = {}
    local flush_scheduled = false
    local flush

    local onread = function(err, data)
        if not running_processes[buf] or running_processes[buf].session_token ~= session_token then return end
        if err then
            api.nvim_buf_call(buf, function()
                if not api.nvim_buf_is_valid(buf) then return end
                if not running_processes[buf] or running_processes[buf].session_token ~= session_token then return end

                local scroll_wins = FollowingWindows(buf)

                SetBufLines(buf, -2, -1, false, {'Error reading output: ' .. err})
                api.nvim_buf_set_var(buf, 'launcher_failed', true)
                api.nvim_buf_set_var(buf, 'this_buf_can_be_closed', true)
                api.nvim_set_option_value('modified', false, { buf = buf })

                ScrollWindows(buf, scroll_wins)
            end)
            return
        end
        if data then
            if encoding and encoding ~= 'utf-8' and type(data) == 'string' then
                data = vim.iconv(data, encoding, 'utf-8')
            end
            pending[#pending + 1] = tostring(data)
            if not flush_scheduled then
                flush_scheduled = true
                vim.defer_fn(function() flush() end, 40)
            end
        end
    end
    flush = function()
        flush_scheduled = false
        if not api.nvim_buf_is_valid(buf) then return end
        if not running_processes[buf] or running_processes[buf].session_token ~= session_token then return end
        if #pending == 0 then return end
        local results = vim.split(table.concat(pending), env.new_line_char, { plain = true })
        pending = {}

        local scroll_wins = FollowingWindows(buf)

        local processed_lines, highlight_data = ParseOutput(results, color_mode)

        local start_line = api.nvim_buf_line_count(buf) - 1
        local last_line = api.nvim_buf_get_lines(buf, -2, -1, false)
        processed_lines[1] = (last_line[1] or '') .. processed_lines[1]

        -- Shift the first line's highlights when prepending to it
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
                    AddHighlight(buf, hl[3], lnum, hl[1], hl[2])
                end
            end
        end

        ApplyPatterns(buf, processed_lines, start_line, patterns, matches, pattern_highlight_groups)

        ScrollWindows(buf, scroll_wins)
    end
    local on_exit = function(code, signal)
        if not running_processes[buf] or running_processes[buf].session_token ~= session_token then return end
        if not api.nvim_buf_is_valid(buf) then return end

        flush()
        api.nvim_buf_set_var(buf, 'launcher_matches', matches)
        running_processes[buf] = nil
        local scroll_wins = FollowingWindows(buf)

        -- Stop the spinner
        SafeCloseTimer(buf)

        local status = (code == 0 and signal == 0) and 'done' or 'terminated'
        api.nvim_buf_set_var(buf, 'launcher_status', status)
        api.nvim_set_option_value('modified', false, { buf = buf })

        local end_text = string.format('---- End [code %d] [signal %d]', code, signal)
        SetBufLines(buf, -2, -1, false, {end_text})
        api.nvim_buf_set_var(buf, 'this_buf_can_be_closed', true)
        vim.cmd('redrawstatus!')

        ScrollWindows(buf, scroll_wins)
    end

    return onread, on_exit, matches
end

function M.Launch(cmd, args, cwd, ev, hi, position, color_mode, existing_buf, encoding, obj, patterns)
    local prjroot_origin = pr.GetCurrentProjectRoot()
    local buf
    if existing_buf then
        buf = existing_buf
    else
        buf = util_buffer.NewScratchBuffer(position)
    end
    api.nvim_set_option_value('filetype', 'launcher', { buf = buf })
    api.nvim_set_option_value('bufhidden', 'hide', { buf = buf })
    api.nvim_set_option_value('modifiable', false, { buf = buf })

    -- Matches for navigation
    api.nvim_buf_set_var(buf, 'launcher_matches', {})

    -- Unique session token for this launch
    local session_token = {}

    -- lc_object / lc_command feed the statusline
    local success, _ = pcall(api.nvim_buf_get_var, buf, 'lc_object')
    if not success then
        api.nvim_buf_set_var(buf, 'lc_object', obj or cmd)
    end
    local full_cmd_str = cmd
    if args and #args > 0 then
        full_cmd_str = full_cmd_str .. ' ' .. table.concat(args, ' ')
    end
    api.nvim_buf_set_var(buf, 'lc_command', full_cmd_str)

    local onread, on_exit, matches = CreateOutputCallbacks(buf, session_token, encoding, color_mode, patterns)

    -- Start the spinner
    api.nvim_buf_set_var(buf, 'launcher_status', 'running')
    api.nvim_set_option_value('modified', true, { buf = buf })
    launcher_timers[buf] = spinner.start({ buf = buf })

    local win = api.nvim_get_current_win()
    -- Start at the bottom
    api.nvim_win_set_cursor(win, {api.nvim_buf_line_count(buf), 0})

    if prjroot_origin then
        pr.SetBufferProjectRoot(buf, prjroot_origin)
        api.nvim_buf_set_var(buf, 'prjroot_folder', prjroot_origin)
    end
    guard.set_launcher_mapping(buf, M.TerminateCurrentLauncherBuffer)

    local ok, pid, terminate_fn, get_status, handle, err = pcall(util_job.AsyncProcess, cmd, args, cwd, { env = ev, onread = onread, onexit = on_exit })

    if ok and handle then
        buffers_handles[buf] = handle
        api.nvim_buf_set_var(buf, 'launcher_terminate_fn', terminate_fn)
        running_processes[buf] = {
            type = 'general',
            handle = handle,
            pid = pid,
            obj = obj,
            cmd = cmd,
            args = args,
            session_token = session_token,
            matches = matches
        }
    else
        local err_msg = 'Failed to start process: ' .. tostring(err or pid or 'unknown')
        SetBufLines(buf, -1, -1, false, {err_msg})
        api.nvim_buf_set_var(buf, 'launcher_status', 'terminated')
        api.nvim_buf_set_var(buf, 'launcher_failed', true)
        api.nvim_buf_set_var(buf, 'this_buf_can_be_closed', true)
        api.nvim_set_option_value('modified', false, { buf = buf })

        -- Failed to start
        SafeCloseTimer(buf)
        running_processes[buf] = nil
        vim.cmd('redrawstatus!')
    end
    return buf
end

function M.TerminateCurrentLauncherBuffer()
    local buf = vim.api.nvim_get_current_buf()
    local proc = running_processes[buf]

    if proc then
        if proc.type == 'terminal' then
            vim.notify(string.format('Terminating terminal job...'), vim.log.levels.WARN)
            vim.fn.jobstop(proc.job_id)
            running_processes[buf] = nil
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

function M.cleanup(buf)
    SafeCloseTimer(buf)
    buffers_handles[buf] = nil
end

return M
