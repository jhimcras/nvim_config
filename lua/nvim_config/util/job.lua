local M = {}


function M.AsyncProcess(cmd, args, cwd, ev_or_opts, read_func, end_func)
    local ev
    -- 4th arg: opts { env, onread, onexit }, or a legacy env list (integer-indexed).
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
    if not success or not err_or_handle then
        if stdout then stdout:close() end
        if stderr then stderr:close() end
        local err = success and pid_or_err or err_or_handle
        return nil, function() end, function() return "failed" end, nil, err
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
        end
        status = 'terminated'
    end

    return pid, terminate_function, get_status, handle
end


return M
