local H = require('tests.spec.coderunner.helpers')
local command = require('nvim_config.coderunner.command')
local queue = require('nvim_config.coderunner.queue')
local function run(entry, ctx, opts)
    local result
    command.run(entry, ctx, opts, function(r) result = r end)
    H.wait(function() return result ~= nil end)
    return result
end

describe('coderunner command', function()
    local root, results, ctx
    before_each(function()
        root, results = H.workspace(), {}
        vim.fn.mkdir(root .. '/docs', 'p')
        ctx = { workspace = root, docdir = root .. '/docs', code = '한글\n', attrs = {}, kind = 'runner' }
    end)
    after_each(function()
        for _, result in ipairs(results) do command.release(result) end
        vim.fn.delete(root, 'rf')
    end)
    local function execute(entry, context, opts)
        local result = run(entry, context or ctx, opts)
        results[#results + 1] = result
        return result
    end
    it('expands once and preserves unknown placeholders and argument boundaries', function()
        ctx.attrs = { value = 'two words; $(x) {workspace}' }
        local p = assert(command.prepare({ cmd = { '{file}', '{attr.value}', '{unknown}', '{format}', '{output}' },
            env = { VALUE = '{docdir}' }, cwd = 'docs' }, vim.tbl_extend('force', ctx, {
                file = '/tmp/input', format = 'svg', output = '/tmp/output.svg', tmpdir = '/tmp/work',
            })))
        assert.same({ '/tmp/input', 'two words; $(x) {workspace}', '{unknown}', 'svg', '/tmp/output.svg' }, p.steps[1])
        assert.equals(ctx.docdir, p.env.VALUE); assert.equals(ctx.docdir, p.cwd)
    end)
    it('writes private input files and uses runner docdir by default', function()
        local result = execute({ ext = 'py', cmd = H.tool('echo', '{file}') })
        assert.equals('success', result.status); assert.equals(ctx.code, result.stdout)
        assert.equals(result.tmpdir .. '/input.py', result.input_path)
        if vim.uv.os_uname().sysname ~= 'Windows_NT' then
            assert.equals(448, bit.band(vim.uv.fs_stat(result.tmpdir).mode, 511))
        end
        local dump = execute({ cmd = H.tool('dump') })
        assert.equals(ctx.docdir, vim.json.decode(dump.stdout).cwd)
        assert.equals('', vim.json.decode(dump.stdout).stdin)
        command.release(result); assert.is_nil(vim.uv.fs_stat(result.tmpdir))
    end)
    it('keeps renderer stdout as raw bytes but still cleans runner stdout and stderr', function()
        local bytes = '\137PNG\r\n\26\n\0\0\0\rIHDR\255'
        ctx.code, ctx.kind, ctx.format = bytes, 'renderer', 'png'
        local image = execute({ input = 'stdin', output = 'stdout', cmd = H.tool('stdin') })
        assert.equals('success', image.status); assert.equals(bytes, image.stdout)
        ctx.kind = 'runner'
        local text = execute({ input = 'stdin', cmd = H.tool('stdin') })
        assert.equals(require('nvim_config.coderunner.exec').clean_utf8(bytes), text.stdout)
        assert.not_equals(bytes, text.stdout)
    end)
    it('uses renderer tmpdir and sends stdin on every step', function()
        ctx.kind, ctx.format = 'renderer', 'svg'
        local result = execute({ input = 'stdin', cmd = H.tool('dump', '{output}') })
        assert.equals('success', result.status)
        local report = vim.json.decode(result.stdout)
        assert.equals(result.tmpdir, report.cwd); assert.equals(ctx.code, report.stdin)
        assert.same({ result.tmpdir .. '/output.svg' }, report.args)
    end)
    it('rejects missing attrs in later steps, env and cwd before execution', function()
        for _, entry in ipairs({
            { steps = { H.tool('exit', '0'), H.tool('dump', '{attr.nope}') } },
            { cmd = H.tool('dump'), env = { X = '{attr.nope}' } },
            { cmd = H.tool('dump'), cwd = '{attr.nope}' },
        }) do
            local result = execute(entry)
            assert.equals('missing_attr', result.status); assert.is_nil(result.tmpdir)
            assert.matches('nope', result.message)
        end
    end)
    it('stops steps on failure and caps the aggregate output', function()
        local result = execute({ steps = { H.tool('exit', '7'), H.tool('exit', '0') } })
        assert.equals('failed', result.status); assert.equals(7, result.code)
        assert.equals('step 7\n', result.stdout)
        result = execute({ steps = { H.tool('flood', '70'), H.tool('flood', '70') } }, ctx, { max_output = 100 })
        assert.equals('success', result.status); assert.equals(100, #result.stdout)
        assert.is_true(result.stdout_truncated); assert.is_true(result.stderr_truncated)
    end)
    it('reports missing later tools and cancels running commands', function()
        local result = execute({ steps = { H.tool('exit', '0'), { root .. '/missing-tool' } } })
        assert.equals('not_found', result.status); assert.equals('step 0\n', result.stdout)
        local finished
        local job = command.run({ cmd = H.tool('hang') }, ctx, {}, function(r) finished = r; results[#results + 1] = r end)
        assert.is_true(job.cancel())
        H.wait(function() return finished ~= nil end)
        assert.equals('cancelled', finished.status)
    end)
    it('prefers entry timeout to the global budget', function()
        local result = execute({ timeout = '30ms', cmd = H.tool('sleep-ms', '100') }, ctx, { timeout = 1000 })
        assert.equals('timeout', result.status)
    end)
    it('passes shell metacharacters literally through actual process execution', function()
        ctx.attrs.value = '; rm -rf $(x) two words'
        local result = execute({ cmd = H.tool('dump', '{attr.value}'), env = { CODERUNNER_TEST_VAR = '{attr.value}' } })
        local report = vim.json.decode(result.stdout)
        assert.same({ ctx.attrs.value }, report.args); assert.equals(ctx.attrs.value, report.var)
    end)
    it('applies one timeout budget to all steps', function()
        local result = execute({ steps = { H.tool('sleep-ms', '80'), H.tool('sleep-ms', '80') } }, ctx, { timeout = 140 })
        assert.equals('timeout', result.status)
        assert.is_true(result.elapsed < 250)
    end)
    it('excludes queue wait from timeout and creates no tempdir for queued cancellation', function()
        local q, first, second, cancelled = queue.new(1)
        command.run({ cmd = H.tool('sleep-ms', '150') }, ctx, { queue = q }, function(r) first = r; results[#results + 1] = r end)
        command.run({ cmd = H.tool('exit', '0') }, ctx, { queue = q, timeout = 100 }, function(r) second = r; results[#results + 1] = r end)
        local pending = command.run({ cmd = H.tool('hang') }, ctx, { queue = q }, function(r) cancelled = r end)
        assert.is_nil(pending.tmpdir); assert.is_true(pending.cancel())
        H.wait(function() return first and second and cancelled end)
        assert.equals('success', second.status); assert.equals('cancelled', cancelled.status)
        assert.is_nil(cancelled.tmpdir)
    end)
end)
