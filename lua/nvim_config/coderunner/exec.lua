local M = {}
local uv = vim.uv
local windows = uv.os_uname().sysname == 'Windows_NT'

-- Validate complete sequences after collecting bytes, including split reads.
function M.clean_utf8(s)
    local out, i = {}, 1
    while i <= #s do
        local b, n = s:byte(i), 0
        if b < 128 then n = 1
        elseif b >= 194 and b <= 223 then n = 2
        elseif b >= 224 and b <= 239 then n = 3
        elseif b >= 240 and b <= 244 then n = 4 end
        local valid = n > 0 and i + n - 1 <= #s
        for j = 1, n - 1 do
            local c = s:byte(i + j)
            if not c or c < 128 or c > 191 then valid = false end
        end
        local c = s:byte(i + 1)
        if n == 3 and c and ((b == 224 and c < 160) or (b == 237 and c >= 160)) then valid = false end
        if n == 4 and c and ((b == 240 and c < 144) or (b == 244 and c >= 144)) then valid = false end
        if valid then out[#out + 1] = s:sub(i, i + n - 1); i = i + n
        else out[#out + 1] = '\239\191\189'; i = i + 1 end
    end
    return table.concat(out)
end

local function close(handle)
    if handle and not handle:is_closing() then handle:close() end
end

function M.run_step(argv, opts, callback)
    opts = opts or {}
    callback = callback or opts.on_exit or function() end
    local started = uv.hrtime()
    local job = { stdout = '', stderr = '', stdout_truncated = false, stderr_truncated = false }
    local input, output, errors = uv.new_pipe(false), uv.new_pipe(false), uv.new_pipe(false)
    local process, pid, timer, exited, completed, reason, exit_code, exit_signal
    local eof = { stdout = false, stderr = false }
    local limit = opts.max_output or 1024 * 1024
    local function finish()
        if completed or not exited or not eof.stdout or not eof.stderr then return end
        completed = true
        close(timer); close(process); close(input); close(output); close(errors)
        job.stdout, job.stderr = M.clean_utf8(job.stdout), M.clean_utf8(job.stderr)
        job.status = reason or (exit_signal ~= 0 and 'failed' or exit_code == 0 and 'success' or 'failed')
        job.code = exit_signal == 0 and exit_code or nil
        job.signal = exit_signal ~= 0 and exit_signal or nil
        job.elapsed = (uv.hrtime() - started) / 1e6
        vim.schedule(function() callback(job) end)
    end
    local function kill_tree()
        if not pid then return end
        if windows then
            local killer
            killer = uv.spawn('taskkill', { args = { '/F', '/T', '/PID', tostring(pid) }, hide = true }, function()
                close(killer)
                if not exited and process then process:kill('sigkill') end
            end)
            if not killer and not exited then process:kill('sigkill') end
        else
            uv.kill(-pid, 'sigkill')
        end
    end
    function job.cancel(kind)
        if completed or reason then return false end
        reason = kind or 'cancelled'
        kill_tree()
        return true
    end
    local function failed(status, message)
        reason, job.message = status, tostring(message)
        exited, eof.stdout, eof.stderr = true, true, true
        exit_code, exit_signal = 0, 0
        finish()
    end
    if opts.cwd then
        local stat = uv.fs_stat(opts.cwd)
        if not stat or stat.type ~= 'directory' then
            failed('spawn_failed', 'working directory is not a directory: ' .. opts.cwd)
            return job
        end
    end
    local env = vim.fn.environ()
    for k, v in pairs(opts.env or {}) do env[k] = v end
    local env_list = {}
    for k, v in pairs(env) do env_list[#env_list + 1] = k .. '=' .. v end
    local args = {}; for i = 2, #argv do args[#args + 1] = argv[i] end
    local spawn_error
    process, spawn_error = uv.spawn(argv[1], {
        args = args, cwd = opts.cwd, env = env_list, stdio = { input, output, errors },
        detached = not windows, hide = true,
    }, function(code, signal)
        -- Kill descendants before closing the leader handle and draining pipes.
        kill_tree()
        exited, exit_code, exit_signal = true, code, signal
        finish()
    end)
    if not process then
        failed(tostring(spawn_error):find('ENOENT', 1, true) and 'not_found' or 'spawn_failed', spawn_error)
        job.program = argv[1]
        return job
    end
    pid = spawn_error
    job.pid = pid
    for name, pipe in pairs({ stdout = output, stderr = errors }) do
        pipe:read_start(function(err, data)
            if err then job.message = tostring(err) end
            if data then
                local room = math.max(0, limit - #job[name])
                job[name] = job[name] .. data:sub(1, room)
                if #data > room then job[name .. '_truncated'] = true end
                if opts.on_output and room > 0 then
                    -- Consumers receive raw bytes; final result is UTF-8 normalized.
                    local chunk = data:sub(1, room)
                    vim.schedule(function() if not completed then opts.on_output(name, chunk) end end)
                end
            else
                eof[name] = true
                close(pipe)
                finish()
            end
        end)
    end
    input:write(opts.stdin or '', function()
        if input:is_closing() then return end
        input:shutdown(function() close(input) end)
    end)
    if opts.timeout then
        timer = uv.new_timer()
        timer:start(math.max(1, math.floor(opts.timeout)), 0, function() job.cancel('timeout') end)
    end
    return job
end

return M
