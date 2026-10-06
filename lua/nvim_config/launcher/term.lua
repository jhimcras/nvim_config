local M = {}

local registry = require('nvim_config.launcher.registry')
local running_processes = registry.processes
local api = vim.api
local pr = require('nvim_config.prjroot')
local util_buffer = require('nvim_config.util.buffer')
local guard = require('nvim_config.launcher.guard')
local output = require('nvim_config.launcher.output')

function M.LaunchOnTerm(cmd, args, cwd, ev, position, obj, existing_buf)
    local prjroot_origin = pr.GetCurrentProjectRoot()
    local buf
    if existing_buf then
        buf = existing_buf
    else
        buf = util_buffer.NewScratchBuffer(position)
    end
    api.nvim_set_option_value('filetype', 'terminal', { buf = buf })
    api.nvim_set_option_value('bufhidden', 'hide', { buf = buf })

    -- Unique session token for this terminal launch
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
    guard.set_launcher_mapping(buf, output.TerminateCurrentLauncherBuffer)

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
                if not running_processes[buf] or running_processes[buf].session_token ~= session_token then return end
                if not api.nvim_buf_is_valid(buf) then return end

                running_processes[buf] = nil
                api.nvim_buf_set_var(buf, 'launcher_status', (code == 0) and 'done' or 'terminated')
                api.nvim_buf_set_var(buf, 'this_buf_can_be_closed', true)
                vim.cmd('redrawstatus!')
            end
        })
    end)

    running_processes[buf] = {
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


return M
