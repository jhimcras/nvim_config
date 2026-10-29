local M = {}
local api, uv = vim.api, vim.uv
local cache = require('nvim_config.coderunner.cache')
local command = require('nvim_config.coderunner.command')
local config = require('nvim_config.coderunner.config')
local blocks = require('nvim_config.coderunner.blocks')
local runner = require('nvim_config.coderunner.run')
local trust = require('nvim_config.coderunner.trust')
local active = {}
local serial = 0
local function docdir(block)
    local path = block.path
    if not path:match('^/') and not path:match('^%a:[/\\]') then path = vim.fs.joinpath(block.root, path) end
    return vim.fs.dirname(path)
end
local function canonical(value)
    if type(value) ~= 'table' then return vim.json.encode(value) end
    local keys, out = {}, {}
    for key in pairs(value) do keys[#keys + 1] = key end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for _, key in ipairs(keys) do out[#out + 1] = canonical(key) .. ':' .. canonical(value[key]) end
    return '{' .. table.concat(out, ',') .. '}'
end
function M.key(block, entry, format)
    format = format or entry.formats[1]
    local prepared, err = command.prepare(entry, { workspace = block.root,
        docdir = docdir(block), kind = 'renderer', format = format,
        file = '/__coderunner__/file', tmpdir = '/__coderunner__/tmpdir', output = '/__coderunner__/output' })
    if not prepared then return nil, err end
    return vim.fn.sha256(canonical({ code = block.code, entry = entry, format = format, prepared = prepared }))
end
function M.describe(block, opts)
    opts = opts or {}
    if block.duplicate then return nil, 'duplicate-code-id: ' .. block.id end
    if block.lang == 'output' then return nil, 'output blocks cannot be rendered' end
    local cfg, status = require('nvim_config.coderunner').resolve(block.root, opts.explicit == true)
    if not trust.can_select(status) then return nil, 'workspace configuration must be loaded with :CodeRunnerLoad' end
    local entry, name = config.select(cfg, 'renderers', block.lang)
    if not entry then return nil, 'no renderer for ' .. tostring(block.lang) end
    if not trust.allowed(status, entry.source, 'renderers', opts.batch == true) then return nil, 'renderer is not trusted' end
    if opts.global_only and entry.source ~= 'global' then return nil, 'renderer is not global' end
    local format = opts.format or entry.formats[1]
    if not vim.tbl_contains(entry.formats, format) then return nil, 'unsupported render format: ' .. tostring(format) end
    local key, err = M.key(block, entry, format)
    if not key then return nil, err end
    local paths = cache.paths(block.root)
    return { block = block, config = cfg, entry = entry, name = name, format = format,
        key = key, paths = paths, path = cache.image(paths, block.lang, key, format) }
end
function M.lookup(block, opts)
    local desc, err = M.describe(block, opts)
    if not desc then return { status = 'none', error = err } end
    local result = cache.lookup(desc.paths, block.key, desc.key, desc.path)
    result.key = desc.key
    result.format = result.path and result.path:match('%.([^.]+)$') or desc.format
    for _, job in pairs(active) do
        if job.path == desc.path and job.block.key == block.key then result.status = 'pending'; break end
    end
    return result
end
local function event(buf)
    if buf and api.nvim_buf_is_valid(buf) then
        require('nvim_config.coderunner.diagnostics').refresh(buf)
        api.nvim_exec_autocmds('User', { pattern = 'CodeRunnerDiagrams', modeline = false, data = { buf = buf } })
    end
end
M.event = event

-- Read saved documents, never modified buffers. A failed scan/parser/trust
-- decision is incomplete and therefore cannot permit destructive collection.
function M.protected(root)
    local protected = {}
    local function scan(dir)
        local handle, err = uv.fs_scandir(dir)
        if not handle then return nil, err end
        while true do
            local name, typ = uv.fs_scandir_next(handle)
            if not name then break end
            local path = vim.fs.joinpath(dir, name)
            if typ == 'directory' and name ~= '.git' then
                local ok; ok, err = scan(path); if not ok then return nil, err end
            elseif typ == 'file' and (name:lower():match('%.md$') or name:lower():match('%.markdown$')) then
                local text = cache.read(path)
                if not text then return nil, 'cannot read ' .. path end
                local list; list, err = blocks.parse(text, { path = path, root = root })
                if not list then return nil, err end
                for _, block in ipairs(list) do
                    if not block.duplicate and block.lang ~= 'output' then
                        local cfg, status = require('nvim_config.coderunner').resolve(root, false)
                        if not trust.can_select(status) then return nil, 'workspace configuration is not loaded' end
                        if config.select(cfg, 'renderers', block.lang) then
                            local entry = config.select(cfg, 'renderers', block.lang)
                            for _, format in ipairs(entry.formats) do
                                local desc; desc, err = M.describe(block, { format = format })
                                if not desc then return nil, err end
                                protected[desc.path] = true
                                if not cache.nonempty(desc.path) then
                                    local found = cache.lookup(desc.paths, block.key, desc.key, desc.path)
                                    if found.path then protected[found.path] = true end
                                end
                            end
                        end
                    end
                end
            end
        end
        return true
    end
    local ok, err = scan(root)
    return protected, ok == true, err
end
local function trim_cache(desc)
    local protected, complete = M.protected(desc.paths.root)
    protected[desc.path] = true
    local result = cache.prune(desc.paths, protected, complete, desc.config.render_max_size)
    if result and result.over_limit then vim.notify('coderunner: protected images exceed render_max_size', vim.log.levels.WARN) end
end
function M.start(block, opts, callback)
    opts = opts or {}
    callback = callback or opts.on_complete or function() end
    local desc, err = M.describe(block, opts)
    if not desc then return nil, err end
    require('nvim_config.coderunner.queue').set_max_jobs(desc.config.max_jobs)
    serial = serial + 1
    local job = { id = serial, block = block, key = desc.key, path = desc.path, format = desc.format,
        status = 'pending', buf = opts.buf }
    active[job.id] = job; cache.use(desc.path, 1)
    local release_key, key_lock, guard_lock, publish_lock, execution, finished, cancelled
    local function finish(result)
        if finished then return end
        finished = true
        job.result, job.status = result, result.status
        active[job.id] = nil
        require('nvim_config.launcher.registry').unregister('coderunner:render:' .. job.id)
        if release_key then release_key(); release_key = nil end
        if result.status == 'ready' then trim_cache(desc) end
        cache.use(desc.path, -1)
        event(job.buf)
        callback(job)
    end
    function job.cancel()
        if finished then return false end
        cancelled = true
        if execution and (execution.status == 'running' or execution.status == 'queued') then
            execution.cancel()
        else
            if key_lock then key_lock.cancel() end
            if guard_lock then guard_lock.cancel() end
            if publish_lock then publish_lock.cancel() end
            finish({ status = 'cancelled' })
        end
        return true
    end
    require('nvim_config.launcher.registry').register('coderunner:render:' .. job.id, {
        type = 'coderunner', title = 'Render ' .. block.key, buf = opts.buf, terminate = job.cancel,
    })
    local function record(result, success, bytes)
        publish_lock = cache.update(desc.paths, block.key, function(item)
            if success and bytes then
                local ok, message = cache.atomic(desc.path, bytes)
                if not ok then success = false; result.status, result.error = 'failed', message end
            end
            if success then
                item.success = { key = desc.key, path = desc.path, time = os.time() }
                if item.failure and item.failure.key == desc.key then item.failure = nil end
            else item.failure = { key = desc.key, message = vim.fn.strcharpart(result.error or 'render failed', 0, 1024) } end
        end, function(ok, message)
            if not ok then result.status, result.error = 'failed', message end
            finish(result)
        end)
    end
    local function execute()
        if not opts.force and cache.nonempty(desc.path) then
            record({ status = 'ready', path = desc.path, cached = true, stale = false }, true); return
        end
        job.executed = true
        execution = command.run(desc.entry, { code = block.code, attrs = block.attrs,
            workspace = block.root, docdir = docdir(block), kind = 'renderer', format = desc.format },
            { timeout = desc.config.timeout, max_output = desc.config.max_output }, function(result)
                if cancelled or result.status == 'cancelled' then command.release(result); finish({ status = 'cancelled' }); return end
                if result.status ~= 'success' then
                    local message = result.stderr ~= '' and result.stderr or result.message or result.status
                    command.release(result); record({ status = 'failed', error = message }, false); return
                end
                local bytes = desc.entry.output == 'stdout' and result.stdout or cache.read(result.output_path)
                command.release(result)
                if not bytes or #bytes == 0 then
                    record({ status = 'failed', error = 'renderer produced no image bytes' }, false); return
                end
                record({ status = 'ready', path = desc.path, stale = false }, true, bytes)
            end)
    end
    -- Cross-instance key locks also serialize this process's equal-key jobs.
    key_lock = cache.lock(desc.path .. '.lock', function(release, message)
        if finished then if release then release() end; return end
        if not release then finish({ status = 'failed', error = message }); return end
        release_key = release
        guard_lock = cache.lock(desc.paths.dir .. '/gc.lock', function(release_gc, gc_error)
            if not release_gc then finish({ status = 'failed', error = gc_error }); return end
            release_gc()
            execute()
        end)
    end)
    return job
end
function M.request(buf, selector, opts, callback)
    opts = vim.tbl_extend('force', { explicit = true, buf = buf }, opts or {})
    local block, err = runner.select(buf, selector, runner.root(buf))
    if not block then return nil, err end
    return M.start(block, opts, callback)
end
function M.cancel_buffer(buf)
    for _, job in pairs(active) do if job.buf == buf then job.cancel() end end
end
function M.gc(root, opts)
    opts = opts or {}
    local paths = cache.paths(root)
    if cache.busy(paths) then return { skipped = true, removed = {} } end
    local fd, err = uv.fs_open(paths.dir .. '/gc.lock', 'wx', 384)
    if not fd then return { skipped = true, removed = {} } end
    uv.fs_write(fd, vim.json.encode({ pid = uv.os_getpid(), token = tostring(uv.hrtime()) }), 0)
    uv.fs_close(fd)
    -- Jobs publish their key lock before waiting on this guard. Recheck those
    -- locks while holding the guard so a new renderer cannot race deletion.
    if cache.busy(paths, true) then
        uv.fs_unlink(paths.dir .. '/gc.lock'); return { skipped = true, removed = {} }
    end
    local protected, complete; protected, complete, err = M.protected(root)
    local result
    if complete then result, err = cache.prune(paths, protected, true, nil, opts.dry_run) end
    uv.fs_unlink(paths.dir .. '/gc.lock')
    return result, err
end
function M.setup()
    api.nvim_create_user_command('CodeRender', function(args)
        local job, err = M.request(api.nvim_get_current_buf(), args.args, { force = args.bang })
        if not job then vim.notify('coderunner: ' .. tostring(err), vim.log.levels.ERROR) end
    end, { nargs = '?', bang = true })
    api.nvim_create_user_command('CodeRenderAll', function()
        local buf = api.nvim_get_current_buf()
        local list, err = blocks.get(buf, runner.root(buf))
        if not list then vim.notify(err, vim.log.levels.ERROR); return end
        for _, block in ipairs(list) do
            local cfg = require('nvim_config.coderunner').resolve(block.root, false)
            if config.select(cfg, 'renderers', block.lang) and not block.duplicate then
                local _, message = M.start(block, { buf = buf, batch = true })
                if message then vim.notify(message, vim.log.levels.ERROR) end
            end
        end
    end, {})
    api.nvim_create_user_command('CodeGc', function(args)
        if args.args ~= '' and args.args ~= 'dry-run' and not (args.bang and args.args == 'all') then
            vim.notify('coderunner: use CodeGc [dry-run] or CodeGc! all', vim.log.levels.ERROR); return
        end
        local roots, err = { runner.root(api.nvim_get_current_buf()) }
        if args.bang and args.args == 'all' then roots, err = cache.roots() end
        if not roots then vim.notify(err, vim.log.levels.ERROR); return end
        -- Validate every workspace before deleting from any workspace.
        for _, root in ipairs(roots) do
            local _, complete, message = M.protected(root)
            if not complete then vim.notify(message, vim.log.levels.ERROR); return end
        end
        for _, root in ipairs(roots) do
            local result; result, err = M.gc(root, { dry_run = args.args == 'dry-run' })
            if not result then vim.notify(err, vim.log.levels.ERROR)
            else vim.notify(('coderunner: %s %d cache images%s'):format(args.args == 'dry-run' and 'would remove' or 'removed',
                #result.removed, result.skipped and ' (busy workspace skipped)' or '')) end
        end
    end, { nargs = '?', bang = true })
    require('nvim_config.coderunner.diagnostics').setup()
end
return M
