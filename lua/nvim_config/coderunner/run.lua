local M = {}
local api, uv = vim.api, vim.uv
local blocks = require('nvim_config.coderunner.blocks')
local command = require('nvim_config.coderunner.command')
local config = require('nvim_config.coderunner.config')
local output = require('nvim_config.coderunner.output_fence')
local view = require('nvim_config.coderunner.result_view')
local progress = require('nvim_config.coderunner.progress')
local jobs, latest, completed, serial = {}, {}, {}, 0
local timer
local max_count, max_bytes = 100, 256 * 1024 * 1024

function M.root(buf)
    local path = api.nvim_buf_get_name(buf)
    return require('nvim_config.prjroot').GetProjectRoot(path) or vim.fs.dirname(path) or vim.fn.getcwd()
end

function M.select(buf, selector, root)
    local list, err = blocks.get(buf, root)
    if not list then return nil, err end
    local row = api.nvim_win_get_cursor(0)[1] - 1
    local hash
    if type(selector) == 'table' then hash, selector = selector.hash, selector.key end
    for _, block in ipairs(list) do
        if (not selector or selector == '') and row >= block.start_row and row <= block.end_row
            or selector == block.key or block.id and selector == '#' .. block.id
            or block.lang and selector == block.lang .. ':' .. block.ordinal then
            if block.duplicate then return nil, 'duplicate-code-id: ' .. block.id end
            if block.lang == 'output' then return nil, 'output blocks cannot be executed' end
            if hash and hash ~= block.hash then return nil, 'stale content hash' end
            return block
        end
    end
    return nil, 'code block not found'
end

local function artifacts(dir, input)
    local files, size = {}, 0
    local function scan(path)
        local handle = uv.fs_scandir(path)
        if not handle then return end
        while true do
            local name = uv.fs_scandir_next(handle)
            if not name then break end
            local full = vim.fs.joinpath(path, name)
            local stat = uv.fs_lstat(full)
            if stat and stat.type == 'directory' then scan(full)
            elseif stat and stat.type == 'file' then
                size = size + stat.size
                if full ~= input then files[#files + 1] = full end
            end
        end
    end
    if dir then scan(dir) end
    table.sort(files)
    return files, size
end

function M.get(id) return jobs[id] end
function M.last(buf)
    buf = buf == 0 and api.nvim_get_current_buf() or buf
    return jobs[latest[buf] or vim.b[buf].coderunner_job_id]
end
function M.cancel(id)
    local job = id and jobs[id] or M.last(api.nvim_get_current_buf())
    if not job or job.result then return false, 'no running job' end
    return job.command.cancel()
end
function M.release(id)
    local job = jobs[id]
    if not job then return false, 'no result' end
    if not job.result then return false, 'job is running; cancel it first' end
    command.release(job.result)
    if job.result.tmpdir then uv.fs_unlink(job.result.tmpdir .. '.result.json') end
    view.release(id); jobs[id] = nil
    for buf, last in pairs(latest) do if last == id then latest[buf] = nil end end
    for i, done in ipairs(completed) do if done == id then table.remove(completed, i); break end end
    return true
end
local function prune()
    local bytes = 0
    for _, id in ipairs(completed) do bytes = bytes + jobs[id].size end
    while #completed > 1 and (#completed > max_count or bytes > max_bytes) do
        local first = jobs[completed[1]]
        bytes = bytes - first.size; M.release(first.id)
    end
    if bytes > max_bytes then vim.notify('coderunner: newest result exceeds retention limit', vim.log.levels.WARN) end
end

-- Only service-owned completed directories from dead processes are eligible.
function M.cleanup(now)
    now = now or os.time()
    local scan = uv.fs_scandir(uv.os_tmpdir())
    if not scan then return end
    while true do
        local name = uv.fs_scandir_next(scan)
        if not name then break end
        local pid = tonumber(name:match('^coderunner%-(%d+)%-%d+$'))
        if pid and not uv.kill(pid, 0) then
            local dir = vim.fs.joinpath(uv.os_tmpdir(), name)
            local stat = uv.fs_lstat(dir)
            if stat and stat.type == 'directory' then
                local file = io.open(dir .. '.result.json', 'rb')
                if file then
                    local ok, marker = pcall(vim.json.decode, file:read('*a')); file:close()
                    if ok and type(marker) == 'table' and marker.pid == pid and type(marker.finished) == 'number'
                        and now - marker.finished >= 24 * 60 * 60 then
                        vim.fn.delete(dir, 'rf'); uv.fs_unlink(dir .. '.result.json')
                    end
                end
            end
        end
    end
end

local function retain_marker(result)
    if not result.tmpdir then return end
    local file = io.open(result.tmpdir .. '.result.json', 'wb')
    if file then file:write(vim.json.encode({ pid = uv.os_getpid(), finished = os.time() })); file:close() end
end

local function retain_session()
    for _, id in ipairs(completed) do retain_marker(jobs[id].result) end
end

function M.start(buf, selector, opts)
    opts = opts or {}
    buf = buf == 0 and api.nvim_get_current_buf() or buf
    local root = M.root(buf)
    local block, err = M.select(buf, selector, root)
    local function reject(reason) vim.notify('coderunner: ' .. reason, vim.log.levels.WARN); return nil, reason end
    if not block then return reject(err) end
    local settings, trust = require('nvim_config.coderunner').resolve(root, true)
    if not require('nvim_config.coderunner.trust').can_select(trust) then
        return reject('workspace configuration is not loaded; use :CodeRunnerLoad (global fallback is blocked)')
    end
    local runner = config.select(settings, 'runners', block.lang)
    if not runner then return reject('no runner for ' .. tostring(block.lang)) end
    if not require('nvim_config.coderunner.trust').allowed(trust, runner.source, 'runners', false) then
        return reject('runner is not trusted')
    end
    require('nvim_config.coderunner.queue').set_max_jobs(settings.max_jobs)
    serial = serial + 1
    local job = { id = serial, buf = buf, block = block, status = 'queued', stdout = '', stderr = '',
        requested = uv.hrtime() }
    jobs[job.id], latest[buf] = job, job.id
    local snapshot = opts.insert and output.capture(buf, block)
    require('nvim_config.launcher.registry').register('coderunner:run:' .. job.id, {
        type = 'coderunner', title = 'Run ' .. block.key, buf = buf, terminate = function() M.cancel(job.id) end,
    })
    progress.start(job)
    job.command = command.run(runner, { code = block.code, attrs = block.attrs, workspace = root,
        docdir = vim.fs.dirname(api.nvim_buf_get_name(buf)), kind = 'runner' }, {
        timeout = settings.timeout, max_output = settings.max_output,
        on_start = function(started) job.status, job.started = 'running', started; view.update(job) end,
        on_output = function(stream, chunk)
            if job.result then return end
            local room = math.max(0, settings.max_output - #job[stream])
            job[stream] = job[stream] .. chunk:sub(1, room)
            job[stream .. '_truncated'] = job[stream .. '_truncated'] or #chunk > room
            job.status = 'running'
            view.update(job)
        end,
    }, function(result)
        result.kind = result.status
        if result.kind == 'not_found' then
            result.message = 'tool not found: ' .. tostring(result.program) .. ' (' .. tostring(result.message or '') .. ')'
        end
        if result.status ~= 'success' and result.status ~= 'cancelled' and result.status ~= 'timeout' then
            result.status = 'failed'
            result.message = result.message or (result.kind ~= 'failed' and (result.kind .. ': ' .. tostring(result.program or '')) or nil)
        end
        job.result, job.status = result, result.status
        job.stdout, job.stderr = result.stdout, result.stderr
        job.started = job.command.started
        result.artifacts, job.size = artifacts(result.tmpdir, result.input_path)
        job.size = job.size + #result.stdout + #result.stderr
        retain_marker(result)
        completed[#completed + 1] = job.id
        require('nvim_config.launcher.registry').unregister('coderunner:run:' .. job.id)
        progress.stop(job)
        if snapshot then
            if result.status == 'success' or result.status == 'failed' then
                local ok, reason = output.apply(snapshot, result)
                if not ok then job.insert_error = reason; vim.notify('coderunner: ' .. reason, vim.log.levels.WARN) end
            end
            output.clear(snapshot)
        end
        view.update(job); prune()
        if opts.on_complete then opts.on_complete(job) end
    end)
    job.status = job.command.status
    if opts.open ~= false then view.open(job) end
    return job
end

function M.setup()
    M.cleanup()
    if not timer then
        timer = uv.new_timer()
        timer:start(3600000, 3600000, vim.schedule_wrap(function() retain_session(); M.cleanup() end))
        api.nvim_create_autocmd('VimLeavePre', {
            group = api.nvim_create_augroup('CodeRunnerRun', { clear = true }),
            callback = function()
                retain_session()
                for _, job in pairs(jobs) do
                    if not job.result then retain_marker(job.command); job.command.cancel() end
                end
            end,
        })
    end
    local function current(action)
        local job = M.last(api.nvim_get_current_buf())
        if not job then vim.notify('coderunner: no result'); return end
        local ok, err = action(job)
        if not ok and err then vim.notify('coderunner: ' .. err, vim.log.levels.WARN) end
    end
    api.nvim_create_user_command('CodeRun', function(args)
        M.start(0, args.args, { insert = args.bang })
    end, { nargs = '?', bang = true })
    api.nvim_create_user_command('CodeCancel', function() current(function(job) return M.cancel(job.id) end) end, {})
    api.nvim_create_user_command('CodeOutput', function() current(view.open) end, {})
    api.nvim_create_user_command('CodeRelease', function() current(function(job) return M.release(job.id) end) end, {})
end
return M
