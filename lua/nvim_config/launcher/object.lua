local M = {}

local registry = require('nvim_config.launcher.registry')
local running_processes = registry.processes
local api = vim.api
local pr = require('nvim_config.prjroot')
local util_buffer = require('nvim_config.util.buffer')
local util_job = require('nvim_config.util.job')
local util_map = require('nvim_config.util.map')
local env = require('nvim_config.env')
local output = require('nvim_config.launcher.output')
local term = require('nvim_config.launcher.term')

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

        if not util_buffer.IsExist(cwd) then
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

            local guard_buf = api.nvim_create_buf(false, true)
            api.nvim_buf_set_name(guard_buf, string.format("[External Process: %s]", obj or cmd))
            api.nvim_set_option_value('buftype', 'nofile', { buf = guard_buf })
            api.nvim_set_option_value('modified', true, { buf = guard_buf })

            local on_exit = function(code, signal)
                if api.nvim_buf_is_valid(guard_buf) then
                    api.nvim_set_option_value('modified', false, { buf = guard_buf })
                    api.nvim_buf_delete(guard_buf, {force = true})
                end
            end
            local pid, terminate_fn, get_status, handle, err = util_job.AsyncProcess(full_cmd, full_args, cwd, { env = ev, onexit = on_exit })
            if not handle then
                on_exit()
                vim.notify('Failed to start process: ' .. tostring(err or 'unknown'), vim.log.levels.ERROR)
                return
            end
            running_processes[guard_buf] = {
                type = 'external',
                pid = pid,
                handle = handle,
                obj = obj,
                cmd = cmd,
                args = args,
                buf = guard_buf
            }
        else
            local parent_win = vim.api.nvim_get_current_win()
            local existing_buf = FindExistingLauncherBuffer(obj, parent_win_prjroot)

            if existing_buf then
                -- Terminate whatever is running in that buffer
                local proc = running_processes[existing_buf]
                if proc then
                    local choice = vim.fn.confirm(string.format('Process [%s] is still running. Replace?', obj), "&Yes\n&No", 2)
                    if choice ~= 1 then
                        if lcfg.focus == true then
                            local wins = vim.fn.win_findbuf(existing_buf)
                            if #wins > 0 then
                                vim.api.nvim_set_current_win(wins[1])
                            end
                        end
                        return
                    end

                    if proc.type == 'terminal' then
                        vim.fn.jobstop(proc.job_id)
                    elseif proc.handle and not proc.handle:is_closing() then
                        proc.handle:kill(15)
                    end
                    running_processes[existing_buf] = nil
                end

                -- termopen() needs an empty unmodified non-terminal buffer.
                local old_buftype = vim.api.nvim_get_option_value('buftype', { buf = existing_buf })
                if old_buftype == 'terminal' or mode == 'terminal' then
                    vim.api.nvim_buf_delete(existing_buf, { force = true })
                    existing_buf = nil
                else
                    -- Clear it for non-terminal reuse
                    output.set_buf_lines(existing_buf, 0, -1, false, {})
                    -- Unmodified, so the next launch starts clean
                    vim.api.nvim_set_option_value('modified', false, { buf = existing_buf })

                    -- Hidden: show it again
                    local wins = vim.fn.win_findbuf(existing_buf)
                    if #wins == 0 then
                        local temp_buf = util_buffer.NewScratchBuffer(position)
                        vim.api.nvim_win_set_buf(vim.api.nvim_get_current_win(), existing_buf)
                        vim.api.nvim_buf_delete(temp_buf, { force = true })
                    else
                        if lcfg.focus == true then
                            vim.api.nvim_set_current_win(wins[1])
                        end
                    end
                end
            end

            local buf
            if mode == 'terminal' then
                buf = term.LaunchOnTerm(cmd, args, cwd, ev, position, obj, existing_buf)
            else
                buf = output.Launch(cmd, args, cwd, ev, hi, position, color_mode, existing_buf, encoding, obj, lcfg.patterns)
            end

            if not existing_buf then
                api.nvim_buf_set_name(buf, string.format("(%d) %s", buf, obj))
                api.nvim_buf_set_var(buf, 'lc_object', obj)
            end

            api.nvim_buf_set_var(buf, 'lc_parent_win', parent_win)
            api.nvim_buf_set_var(buf, 'prjroot_folder', parent_win_prjroot)

            if lcfg.focus == true then
                local wins = vim.fn.win_findbuf(buf)
                if #wins > 0 then
                    api.nvim_set_current_win(wins[1])
                end
            else
                if api.nvim_win_is_valid(parent_win) then
                    api.nvim_set_current_win(parent_win)
                end
            end
            return buf
        end
    end
end

function M.BufMapping()
    local c = pr.GetCurrentConfig()
    if c and c.launchers then
        for key, val in pairs(c.launchers) do
            if val.key then
                util_map.nnoremap(val.key, function() M.LaunchObject(key) end)
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


return M
