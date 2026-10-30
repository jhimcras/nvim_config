local H = require('tests.spec.coderunner.helpers')
local runner = require('nvim_config.coderunner.run')
local command = require('nvim_config.coderunner.command')
local api = vim.api
local function entry(mode, ...) return { match = { 'python' }, cmd = H.tool(mode, ...) } end

describe('coderunner run service', function()
    local root, buf, ids, original, secure, notify
    local function setup(opts)
        require('nvim_config.coderunner').setup(vim.tbl_extend('force', {
            runners = { python = entry('echo', '{file}') },
        }, opts or {}))
    end
    local function start(selector, opts)
        local job, err = runner.start(buf, selector or '#one', vim.tbl_extend('force', { open = false }, opts or {}))
        if job then ids[#ids + 1] = job.id end
        return job, err
    end
    local function finish(job) H.wait(function() return job.result ~= nil end); return job.result end
    before_each(function()
        root, ids = H.workspace(), {}
        buf = H.buffer(root, '```python {#one}\nhello\n```\n')
        api.nvim_set_current_buf(buf)
        original, secure, notify = command.run, vim.secure.read, vim.notify
        vim.notify = function() end
        setup()
    end)
    after_each(function()
        command.run, vim.secure.read = original, secure
        vim.notify = notify
        for _, id in ipairs(ids) do
            local job = runner.get(id)
            if job then
                if not job.result then runner.cancel(id); finish(job) end
                runner.release(id)
            end
        end
        if api.nvim_buf_is_valid(buf) then api.nvim_buf_delete(buf, { force = true }) end
        vim.fn.delete(root, 'rf')
    end)
    it('selects cursor, key, id and language ordinal and rejects stale hashes', function()
        api.nvim_win_set_cursor(0, { 2, 0 })
        local b = assert(runner.select(buf, nil, root))
        for _, selector in ipairs({ b.key, '#one', 'python:1' }) do
            assert.equals(b.key, runner.select(buf, selector, root).key)
        end
        local block, err = runner.select(buf, { key = b.key, hash = 'old' }, root)
        assert.is_nil(block); assert.matches('stale', err)
        assert.equals('success', finish(assert(start({ key = b.key, hash = b.hash }))).status)
    end)
    it('returns an immediate id, final output and supports release', function()
        local job = assert(start())
        assert.is_number(job.id); assert.equals(job, runner.last(buf))
        local result = finish(job)
        assert.equals('success', result.status); assert.equals('hello\n', result.stdout)
        assert.is_number(job.started); assert.is_true(result.elapsed >= 0)
        local dir = result.tmpdir
        assert.is_true(runner.release(job.id)); assert.is_nil(runner.get(job.id))
        assert.is_nil(runner.last(buf)); assert.is_nil(vim.uv.fs_stat(dir))
    end)
    it('rejects duplicate ids, output blocks and languages without runners', function()
        api.nvim_buf_set_lines(buf, 0, -1, false, { '```python {#one}', 'x', '```', '```python {#one}', 'y', '```' })
        local job, err = start(); assert.is_nil(job); assert.matches('duplicate', err)
        api.nvim_buf_set_lines(buf, 0, -1, false, { '```output', 'x', '```' })
        job, err = start('output:1'); assert.is_nil(job); assert.matches('output blocks', err)
        api.nvim_buf_set_lines(buf, 0, -1, false, { '```lua', 'x', '```' })
        job, err = start('lua:1'); assert.is_nil(job); assert.matches('no runner', err)
    end)
    it('streams output then cancels and prohibits releasing active jobs', function()
        setup({ runners = { python = entry('emit-wait') } })
        local job = assert(start())
        local ok, err = runner.release(job.id)
        assert.is_false(ok); assert.matches('cancel', err)
        H.wait(function() return job.stdout:find('before', 1, true) end)
        assert.is_true(runner.cancel(job.id)); assert.equals('cancelled', finish(job).status)
        assert.matches('before', job.result.stdout)
    end)
    it('times out and inserts stdout for failed runs', function()
        setup({ timeout = '50ms', runners = { python = entry('hang') } })
        assert.equals('timeout', finish(assert(start())).status)
        setup({ runners = { python = entry('exit', '7') } })
        local job = assert(start(nil, { insert = true }))
        assert.equals('failed', finish(job).status)
        local text = table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
        assert.matches('```output {.error}\nstep 7\n```', text, 1, true)
    end)
    it('rejects source changes before inserting asynchronous results', function()
        setup({ runners = { python = { match = { 'python' }, steps = { H.tool('sleep-ms', '100'), H.tool('stdin') }, input = 'stdin' } } })
        local job = assert(start(nil, { insert = true }))
        api.nvim_buf_set_lines(buf, 1, 2, false, { 'changed' })
        finish(job); assert.matches('source changed', job.insert_error)
        assert.equals(3, api.nvim_buf_line_count(buf))
    end)
    it('reports tool and attribute errors as failed results with a reason', function()
        setup({ runners = { python = { match = { 'python' }, cmd = { root .. '/missing' } } } })
        local result = finish(assert(start()))
        assert.equals('failed', result.status); assert.equals('not_found', result.kind)
        assert.matches('missing', result.message)
        setup({ runners = { python = { match = { 'python' }, cmd = H.tool('dump', '{attr.missing}') } } })
        result = finish(assert(start()))
        assert.equals('failed', result.status); assert.equals('missing_attr', result.kind)
        assert.matches('missing_attr', result.message)
    end)
    it('does not execute runners on opening or saving documents', function()
        local calls = 0
        command.run = function(...) calls = calls + 1; return original(...) end
        api.nvim_exec_autocmds('BufReadPost', { buffer = buf })
        api.nvim_exec_autocmds('BufWritePost', { buffer = buf })
        vim.wait(50, function() return false end)
        assert.equals(0, calls)
    end)
    it('blocks denied workspace fallback and selects loaded workspace runners first', function()
        H.write(root .. '/.coderunner.lua', 'return { runners = { z = { match={"python"}, cmd={"' .. vim.v.progpath .. '", "--version"} } } }')
        vim.secure.read = function() return nil end
        local job, err = start(); assert.is_nil(job); assert.matches('not loaded', err)
        vim.secure.read = function(path) local f = assert(io.open(path)); local s = f:read('*a'); f:close(); return s end
        job = assert(start()); assert.equals('success', finish(job).status)
        assert.matches('NVIM', job.result.stdout)
    end)
    it('lists ordinary artifacts recursively, excludes only generated input and ignores symlinks', function()
        setup({ runners = { python = { match = { 'python' }, ext = 'py', steps = {
            H.tool('write', '{tmpdir}/input.extra', 'artifact'), H.tool('write', '{tmpdir}/result.txt', 'result'),
        } } } })
        local job = assert(start()); local result = finish(job)
        assert.same({ result.tmpdir .. '/input.extra', result.tmpdir .. '/result.txt' }, result.artifacts)
    end)
    it('updates queued jobs when they acquire a slot', function()
        setup({ max_jobs = 1, runners = { python = entry('hang') } })
        local first, second = assert(start()), assert(start())
        assert.equals('running', first.status); assert.equals('queued', second.status)
        assert.is_true(runner.cancel(first.id)); finish(first)
        H.wait(function() return second.status == 'running' end)
        assert.is_number(second.started)
        assert.is_true(runner.cancel(second.id)); finish(second)
    end)
    it('does not follow artifact symlinks or exclude user-created input names', function()
        local outside = H.write(root .. '/outside', 'private')
        command.run = function(_, _, _, callback)
            local dir = vim.fs.normalize(vim.fn.tempname()); vim.fn.mkdir(dir .. '/nested', 'p')
            H.write(dir .. '/input', 'generated'); H.write(dir .. '/nested/input.txt', 'artifact')
            H.write(dir .. '/.coderunner-result.json', 'user artifact')
            if vim.uv.os_uname().sysname ~= 'Windows_NT' then
                assert(vim.uv.fs_symlink(outside, dir .. '/link'))
                assert(vim.uv.fs_symlink(root, dir .. '/directory-link'))
            end
            local result = { status = 'success', stdout = '', stderr = '', elapsed = 0,
                tmpdir = dir, input_path = dir .. '/input' }
            vim.schedule(function() callback(result) end)
            return { status = 'running', cancel = function() end }
        end
        local job = assert(start()); local result = finish(job)
        assert.same({ result.tmpdir .. '/.coderunner-result.json', result.tmpdir .. '/nested/input.txt' }, result.artifacts)
    end)
    it('can cancel, reopen and release through commands while the result window is current', function()
        setup({ runners = { python = entry('hang') } })
        local job = assert(start(nil, { open = true }))
        local result_buf = api.nvim_get_current_buf()
        assert.equals(job, runner.last(result_buf))
        vim.cmd('CodeCancel'); assert.equals('cancelled', finish(job).status)
        vim.cmd('CodeOutput'); assert.equals(result_buf, api.nvim_get_current_buf())
        vim.cmd('CodeRelease'); assert.is_nil(runner.get(job.id))
    end)
    it('evicts oldest completed results beyond 100 and preserves running work', function()
        setup({ runners = { python = entry('hang') } })
        local running = assert(start())
        local dirs = {}
        command.run = function(_, _, _, callback)
            local dir = vim.fs.normalize(vim.fn.tempname()); vim.fn.mkdir(dir, 'p'); dirs[#dirs + 1] = dir
            local result = { status = 'success', stdout = '', stderr = '', tmpdir = dir, elapsed = 0 }
            vim.schedule(function() callback(result) end)
            return { status = 'running', cancel = function() end }
        end
        for _ = 1, 101 do finish(assert(start())) end
        assert.is_nil(runner.get(ids[2])); assert.is_nil(vim.uv.fs_stat(dirs[1]))
        assert.is_not_nil(runner.get(ids[102])); assert.is_not_nil(runner.get(running.id))
        assert.is_true(runner.cancel(running.id)); finish(running)
    end)
    it('keeps an oversized newest result and accounts artifact bytes for retention', function()
        command.run = function(_, _, _, callback)
            local result = { status = 'success', stdout = '', stderr = '', elapsed = 0 }
            local dir = vim.fs.normalize(vim.fn.tempname()); vim.fn.mkdir(dir, 'p'); result.tmpdir = dir
            local fd = assert(vim.uv.fs_open(dir .. '/big', 'w', 384))
            assert(vim.uv.fs_ftruncate(fd, 257 * 1024 * 1024)); vim.uv.fs_close(fd)
            vim.schedule(function() callback(result) end)
            return { status = 'running', cancel = function() end }
        end
        local first = assert(start()); finish(first)
        local second = assert(start()); finish(second)
        assert.is_nil(runner.get(first.id)); assert.is_not_nil(runner.get(second.id))
    end)
    it('cleans expired completed directories only when the owner process is dead', function()
        local dir = vim.uv.os_tmpdir() .. '/coderunner-2147483646-90004'
        vim.fn.mkdir(dir, 'p')
        H.write(dir .. '.result.json', vim.json.encode({ pid = 2147483646, finished = os.time() - 90000 }))
        runner.cleanup(); assert.is_nil(vim.uv.fs_stat(dir))
        vim.fn.mkdir(dir, 'p'); H.write(dir .. '/unmarked', 'keep')
        runner.cleanup(); assert.is_not_nil(vim.uv.fs_stat(dir)); vim.fn.delete(dir, 'rf')
    end)
end)
