local H = require('tests.spec.coderunner.helpers')
local render = require('nvim_config.coderunner.render')
local cache = require('nvim_config.coderunner.cache')
local blocks = require('nvim_config.coderunner.blocks')
local api = vim.api

describe('coderunner rendering', function()
    local root, buf, notify, jobs, paths
    local function setup(entry, opts)
        require('nvim_config.coderunner').setup(vim.tbl_extend('force', {
            renderers = { fake = entry or { match = { 'dot' }, formats = { 'png', 'svg' },
                cmd = H.tool('write', '{output}', '{format}') } },
        }, opts or {}))
    end
    local function block() return assert(blocks.get(buf, root))[1] end
    local function start(opts)
        local job = assert(render.start(block(), vim.tbl_extend('force', { buf = buf }, opts or {})))
        jobs[#jobs + 1] = job; return job
    end
    local function finish(job) H.wait(function() return job.result ~= nil end); return job.result end
    before_each(function()
        root, jobs = H.workspace(), {}
        buf = H.buffer(root, '```dot {#one}\nx\n```\n')
        api.nvim_set_current_buf(buf)
        notify = vim.notify; vim.notify = function() end
        setup(); paths = cache.paths(root)
    end)
    after_each(function()
        for _, job in ipairs(jobs) do if not job.result then job.cancel(); finish(job) end end
        if api.nvim_buf_is_valid(buf) then api.nvim_buf_delete(buf, { force = true }) end
        vim.fn.delete(paths.dir, 'rf'); vim.fn.delete(root, 'rf'); vim.notify = notify
    end)
    it('keys include code, config, format, and only substituted document paths', function()
        local b = block()
        local cfg = require('nvim_config.coderunner').resolve(root, false)
        local entry = cfg.renderers.fake
        local key = render.key(b, entry)
        assert.equals(key, render.key(b, vim.deepcopy(entry)))
        local other = vim.deepcopy(b); other.path = root .. '/else/note.md'
        assert.equals(key, render.key(other, entry))
        other.code = 'changed'; assert.is_not.equals(key, render.key(other, entry))
        assert.is_not.equals(key, render.key(b, entry, 'svg'))
        entry.env = { DIR = '{docdir}' }
        assert.is_not.equals(render.key(b, entry), render.key(other, entry))
        other.code = b.code
        assert.is_not.equals(render.key(b, entry), render.key(other, entry))
        entry.env = { DIR = 'different' }; assert.is_not.equals(key, render.key(b, entry))
    end)
    it('renders once, reuses cache after relocation, and forces replacement', function()
        local first = start(); local result = finish(first)
        assert.equals('ready', result.status); assert.equals('png', cache.read(result.path))
        local second = start(); assert.is_true(finish(second).cached); assert.is_nil(second.executed)
        api.nvim_buf_set_lines(buf, 0, 0, false, { 'paragraph', '' })
        assert.equals(result.path, render.lookup(block()).path)
        H.write(result.path, 'old')
        assert.equals('ready', finish(start({ force = true })).status)
        assert.equals('png', cache.read(result.path))
    end)
    it('returns stale last success and records only the current failed key', function()
        local image = finish(start()).path
        setup({ match = { 'dot' }, formats = { 'png' }, cmd = H.tool('exit', '7') })
        local before = render.lookup(block()); assert.is_true(before.stale); assert.equals(image, before.path)
        local failed = finish(start()); assert.equals('failed', failed.status)
        local found = render.lookup(block()); assert.equals('failed', found.status); assert.equals(image, found.path)
        api.nvim_buf_set_lines(buf, 1, 2, false, { 'new' })
        assert.equals('ready', render.lookup(block()).status)
        setup(); assert.equals('ready', finish(start()).status)
        assert.is_false(render.lookup(block()).stale)
    end)
    it('serializes equal keys, rechecks cache and cancels lock waiters', function()
        local first, second, third = start(), start(), start()
        assert.is_true(third.cancel()); assert.equals('cancelled', finish(third).status)
        assert.equals('ready', finish(first).status)
        assert.is_true(finish(second).cached); assert.is_nil(second.executed)
    end)
    it('publishes no image or failure for cancelled rendering', function()
        setup({ match = { 'dot' }, formats = { 'png' }, cmd = H.tool('hang') })
        local job = start(); H.wait(function() return job.executed end)
        job.cancel(); assert.equals('cancelled', finish(job).status)
        assert.is_nil(vim.uv.fs_stat(job.path)); assert.equals('none', render.lookup(block()).status)
    end)
    it('rejects empty output and preserves previous bytes on failed force', function()
        local image = finish(start()).path
        setup({ match = { 'dot' }, formats = { 'png' }, output = 'stdout', cmd = H.tool('sleep-ms', '1') })
        local job = start(); assert.equals('failed', finish(job).status)
        assert.matches('no image', job.result.error)
        setup(); local desc = assert(render.describe(block()))
        local atomic = cache.atomic
        cache.atomic = function(path, bytes)
            if path == desc.path then return nil, 'replacement failed' end
            return atomic(path, bytes)
        end
        local forced = start({ force = true }); finish(forced); cache.atomic = atomic
        assert.equals('failed', forced.status); assert.equals('png', cache.read(image))
    end)
    it('supports stdout SVG and emits one completion event per request', function()
        setup({ match = { 'dot' }, formats = { 'svg' }, output = 'stdout', cmd = H.tool('stdin'), input = 'stdin' })
        local count = 0
        local id = api.nvim_create_autocmd('User', { pattern = 'CodeRunnerDiagrams', callback = function(a)
            if a.data.buf == buf then count = count + 1 end
        end })
        local job = start(); assert.equals('ready', finish(job).status)
        assert.equals('x\n', cache.read(job.path)); assert.equals('svg', render.lookup(block()).format)
        assert.equals(1, count); api.nvim_del_autocmd(id)
    end)
    it('rejects untrusted, duplicate and unsupported requests without execution', function()
        local b = block()
        local job, err = render.start(b, { format = 'jpeg' }); assert.is_nil(job); assert.matches('unsupported', err)
        H.write(root .. '/.coderunner.lua', 'return {}')
        job, err = render.start(b); assert.is_nil(job); assert.matches('Load', err)
        vim.fn.delete(root .. '/.coderunner.lua')
        b.duplicate = true
        job, err = render.start(b); assert.is_nil(job); assert.matches('duplicate', err)
    end)
    it('gc protects disk images and stale previews, skips busy workspaces', function()
        local image = finish(start()).path
        local orphan = cache.image(paths, 'dot', string.rep('a', 64), 'png'); H.write(orphan, 'orphan')
        local dry = assert(render.gc(root, { dry_run = true }))
        assert.same({ orphan }, dry.removed); assert.is_truthy(vim.uv.fs_stat(orphan))
        H.write(root .. '/note.md', '```dot {#one}\nchanged\n```\n')
        local collected = assert(render.gc(root)); assert.same({ orphan }, collected.removed)
        assert.is_truthy(vim.uv.fs_stat(image))
        local job = start({ force = true })
        assert.is_true(render.gc(root).skipped); finish(job)
    end)
    it('cancels while waiting to publish without replacing a previous image', function()
        local image = finish(start()).path
        H.write(image, 'previous')
        local release
        cache.lock(paths.dir .. '/manifest.lock', function(r) release = r end)
        local job = start({ force = true })
        H.wait(function() return job.executed and #vim.fn.readdir(paths.images) > 1 end)
        -- Allow the renderer to finish and reach the occupied manifest lock.
        vim.wait(100, function() return false end, 10)
        assert.is_true(job.cancel()); assert.equals('cancelled', finish(job).status)
        release(); vim.wait(50, function() return false end, 10)
        assert.equals('previous', cache.read(image))
    end)
    it('runs different keys in parallel through the shared job slots', function()
        -- A marker written before a long step proves both jobs have started.
        setup({ match = { 'dot' }, formats = { 'png' }, steps = {
            H.tool('write', '{tmpdir}/started', 'yes'), H.tool('sleep-ms', '200'),
            H.tool('write', '{output}', 'image'),
        } }, { max_jobs = 2 })
        local run = require('nvim_config.coderunner.command').run
        local commands = {}
        require('nvim_config.coderunner.command').run = function(...)
            local job = run(...); commands[#commands + 1] = job; return job
        end
        local first = start()
        api.nvim_buf_set_lines(buf, 1, 2, false, { 'other code' })
        local second = start()
        H.wait(function()
            return #commands == 2 and commands[1].tmpdir and commands[2].tmpdir
                and cache.read(commands[1].tmpdir .. '/started') and cache.read(commands[2].tmpdir .. '/started')
        end)
        require('nvim_config.coderunner.command').run = run
        assert.is_nil(first.result); assert.is_nil(second.result)
        assert.equals('ready', finish(first).status); assert.equals('ready', finish(second).status)
    end)
    it('refuses gc on incomplete disk parsing or unreadable trust state', function()
        local orphan = cache.image(paths, 'dot', string.rep('a', 64), 'png'); H.write(orphan, 'orphan')
        H.write(root .. '/.coderunner.lua', 'return {}')
        local result, err = render.gc(root)
        assert.is_nil(result); assert.matches('not loaded', err)
        assert.is_truthy(vim.uv.fs_stat(orphan))
        vim.fn.delete(root .. '/.coderunner.lua')
        local parse = blocks.parse
        blocks.parse = function() return nil, 'parser unavailable' end
        result, err = render.gc(root); blocks.parse = parse
        assert.is_nil(result); assert.matches('parser unavailable', err)
        assert.is_truthy(vim.uv.fs_stat(orphan))
    end)

end)
