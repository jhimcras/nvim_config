local M = {}
local uv = vim.uv
local exec = require('nvim_config.coderunner.exec')
local queue = require('nvim_config.coderunner.queue')
local serial = 0

function M.expand(value, context)
    local missing
    local result = value:gsub('{([^{}]+)}', function(key)
        local attr = key:match('^attr%.(.+)$')
        if attr then
            local v = (context.attrs or {})[attr]
            if v == nil then missing = attr; return '{' .. key .. '}' end
            return tostring(v)
        end
        return context[key] or '{' .. key .. '}'
    end)
    if missing then return nil, 'missing_attr: ' .. missing end
    return result
end

-- Also used with fixed file/tmpdir/output tokens when computing render keys.
function M.prepare(entry, context)
    local prepared = { steps = {}, env = {} }
    local function expand(value)
        local out, err = M.expand(value, context)
        if not out then error(err, 0) end
        return out
    end
    local ok, err = pcall(function()
        for _, step in ipairs(entry.steps or { entry.cmd }) do
            local argv = {}
            for _, arg in ipairs(step) do argv[#argv + 1] = expand(arg) end
            prepared.steps[#prepared.steps + 1] = argv
        end
        for k, v in pairs(entry.env or {}) do prepared.env[k] = expand(v) end
        prepared.cwd = expand(entry.cwd or (context.kind == 'renderer' and '{tmpdir}' or '{docdir}'))
        if not prepared.cwd:match('^[/\\]') and not prepared.cwd:match('^%a:[/\\]') then
            prepared.cwd = vim.fs.joinpath(context.workspace, prepared.cwd)
        end
        prepared.cwd = vim.fs.normalize(prepared.cwd)
    end)
    if not ok then return nil, tostring(err) end
    return prepared
end

local function tempdir()
    while true do
        serial = serial + 1
        local path = vim.fs.joinpath(uv.os_tmpdir(), 'coderunner-' .. uv.os_getpid() .. '-' .. serial)
        local ok, err = uv.fs_mkdir(path, 448)
        if ok then return path end
        if not tostring(err):find('EEXIST', 1, true) then return nil, err end
    end
end

function M.release(result)
    if result and result.tmpdir then vim.fn.delete(result.tmpdir, 'rf') end
end

-- context: code, attrs, workspace, docdir, kind ('runner'/'renderer'), format.
-- Returns immediately, including when waiting for the shared FIFO slot.
function M.run(entry, context, opts, callback)
    opts = opts or {}
    callback = callback or opts.on_exit or function() end
    local job = { status = 'queued', stdout = '', stderr = '', stdout_truncated = false, stderr_truncated = false }
    local active, ticket, done, started, completed
    local timeout = entry.timeout or opts.timeout or 30000
    if type(timeout) == 'string' then timeout = require('nvim_config.coderunner.config').parse_time(timeout) end
    local limit = opts.max_output or 1024 * 1024
    local function finish(status, message)
        if completed then return end
        completed = true
        job.status, job.message = status, message
        job.elapsed = started and (uv.hrtime() - started) / 1e6 or 0
        if done then done() end
        vim.schedule(function() callback(job) end)
    end
    function job.cancel()
        if completed then return false end
        if ticket and ticket.cancel() then return true end
        if active and active.cancel() then return true end
        finish('cancelled')
        return true
    end
    local function start(release_slot)
        done, started, job.status = release_slot, uv.hrtime(), 'running'
        job.started = started
        if opts.on_start then opts.on_start(started) end
        local ctx = vim.deepcopy(context)
        local err
        ctx.tmpdir, err = tempdir()
        if not ctx.tmpdir then finish('spawn_failed', err); return end
        job.tmpdir = ctx.tmpdir
        ctx.file = vim.fs.joinpath(ctx.tmpdir, 'input' .. (entry.ext and '.' .. entry.ext or ''))
        ctx.output = vim.fs.joinpath(ctx.tmpdir, 'output.' .. (ctx.format or 'png'))
        job.input_path, job.output_path = ctx.file, ctx.output
        local prepared
        prepared, err = M.prepare(entry, ctx)
        if not prepared then finish('missing_attr', err); return end
        local fd
        fd, err = uv.fs_open(ctx.file, 'w', 384)
        if not fd then finish('spawn_failed', err); return end
        local written
        written, err = uv.fs_write(fd, ctx.code or '', 0)
        uv.fs_close(fd)
        if not written then finish('spawn_failed', err); return end
        local index = 0
        local function next_step()
            if completed then return end
            local remaining = timeout - (uv.hrtime() - started) / 1e6
            if remaining <= 0 then finish('timeout'); return end
            index = index + 1
            if not prepared.steps[index] then finish('success'); return end
            active = exec.run_step(prepared.steps[index], {
                cwd = prepared.cwd, env = prepared.env, timeout = remaining,
                stdin = entry.input == 'stdin' and ctx.code or '', max_output = limit,
                raw_stdout = entry.output == 'stdout',
                on_output = function(stream, chunk)
                    if not completed and opts.on_output then opts.on_output(stream, chunk) end
                end,
            }, function(result)
                if completed then return end
                for _, stream in ipairs({ 'stdout', 'stderr' }) do
                    local room = math.max(0, limit - #job[stream])
                    job[stream] = job[stream] .. result[stream]:sub(1, room)
                    job[stream .. '_truncated'] = job[stream .. '_truncated'] or result[stream .. '_truncated'] or #result[stream] > room
                    if stream == 'stderr' or entry.output ~= 'stdout' then job[stream] = exec.clean_utf8(job[stream]) end
                end
                job.code, job.signal, job.program = result.code, result.signal, result.program
                if result.status ~= 'success' then finish(result.status, result.message)
                else next_step() end
            end)
        end
        next_step()
    end
    -- Validate attributes before any temporary file or process is created.
    local check = vim.tbl_extend('force', context, { file = '{file}', tmpdir = '{tmpdir}', output = '{output}' })
    local prepared, err = M.prepare(entry, check)
    if not prepared then finish('missing_attr', err); return job end
    ticket = (opts.queue or queue).submit(start, function() finish('cancelled') end)
    return job
end

return M
