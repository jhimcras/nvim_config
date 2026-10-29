local C = require('nvim_config.coderunner.config')
local function runner(extra)
    return vim.tbl_extend('force', { match = { 'py' }, cmd = { 'python', '{file}' } }, extra or {})
end
local function renderer(extra)
    return vim.tbl_extend('force', runner(), { formats = { 'svg', 'png' } }, extra or {})
end
local function errors(ds)
    return vim.tbl_filter(function(d) return d.level == 'error' end, ds)
end

describe('coderunner config', function()
    it('uses defaults and parses exact positive CF-4 quantities', function()
        local cfg = C.merge()
        assert.equals(30000, cfg.timeout)
        assert.equals(4, cfg.max_jobs)
        assert.equals(1048576, cfg.max_output)
        for value, n in pairs({ ['1ms'] = 1, ['30s'] = 30000, ['2m'] = 120000, ['1h'] = 3600000 }) do
            assert.equals(n, C.parse_time(value))
        end
        for value, n in pairs({ ['1B'] = 1, ['1KB'] = 1024, ['1MB'] = 1048576, ['1GB'] = 1073741824 }) do
            assert.equals(n, C.parse_size(value))
        end
        for _, value in ipairs({ '0ms', '01s', '1.5s', ' 1s', '1s ', '-1s', '1m30s', '999999999999999999h', 100 }) do
            assert.is_nil(C.parse_time(value))
        end
        for _, value in ipairs({ '0B', '0', '1MiB', '1 MB', '1.5MB', '999999999999999999GB', 0 }) do
            assert.is_nil(C.parse_size(value))
        end
    end)

    it('validates global options and keeps other options on error', function()
        local cfg, ds = C.validate({ timeout = '2m', max_output = '2KB', render_max_size = 'unlimited',
            max_jobs = 2, auto_render = false, diagnostics = false, render_on_open = true,
            auto_render_debounce = '10ms', attachments = 'images', link_style = 'wiki',
            create_attachments_dir = 'always' })
        assert.equals(0, #ds)
        assert.equals(120000, cfg.timeout)
        assert.equals(2048, cfg.max_output)
        assert.equals('unlimited', cfg.render_max_size)
        assert.is_false(cfg.diagnostics)
        for key, value in pairs({ max_jobs = 0, timeout = 30, max_output = '0B', render_max_size = '0B',
            auto_render = 1, diagnostics = 'yes', render_on_open = 1, auto_render_debounce = '0ms',
            link_style = 'html', create_attachments_dir = true }) do
            local layer, diagnostics = C.validate({ [key] = value })
            assert.equals(1, #errors(diagnostics), key)
            assert.is_nil(layer[key])
        end
        for _, value in ipairs({ '../assets', './a/../b', '/assets', 'C:/assets', 'a\\b', '' }) do
            local _, diagnostics = C.validate({ attachments = value })
            assert.equals(1, #errors(diagnostics), value)
        end
    end)

    it('rejects invalid entries independently with named errors', function()
        local cases = {
            false, {}, runner({ match = {} }), runner({ match = { '' } }), runner({ match = 'py' }),
            runner({ cmd = {} }), runner({ cmd = 'python' }), runner({ cmd = { 1 } }),
            runner({ cmd = { '' } }), runner({ steps = { { 'python' } } }),
            { match = { 'py' }, steps = {} }, { match = { 'py' }, steps = { {} } },
            runner({ timeout = '0s' }), runner({ ext = 1 }), runner({ ext = '../x' }),
            runner({ cwd = '' }), runner({ input = 'pipe' }), runner({ env = { A = 1 } }),
            runner({ env = 'x' }), runner({ cmd = { 'p\0x' } }),
        }
        for _, bad in ipairs(cases) do
            local cfg, ds = C.validate({ runners = { bad = bad, good = runner() } }, 'global')
            assert.is_false(cfg.runners.bad)
            assert.is_table(cfg.runners.good)
            assert.is_true(#errors(ds) > 0)
            for _, d in ipairs(ds) do assert.is_truthy(d.message:find('runners.bad', 1, true)) end
        end
    end)

    it('accepts steps and empty arguments, and warns on unsupported keys', function()
        local cfg, ds = C.validate({ runners = { cpp = { match = { 'cpp' },
            steps = { { 'cc', '{file}' }, { '{tmpdir}/a.out', '' } }, output = 'stdout', formats = { 'svg' } } }, mystery = true })
        assert.equals(0, #errors(ds))
        assert.equals(3, #ds)
        assert.equals('', cfg.runners.cpp.steps[2][2])
        assert.is_nil(cfg.runners.cpp.output)
    end)

    it('validates renderer formats/output and rejects attribute placeholders in every command field', function()
        local cases = { renderer({ formats = {} }), renderer({ formats = { 'pdf' } }),
            renderer({ formats = { 'svg', 'svg' } }), renderer({ output = 'path' }),
            renderer({ cmd = { 'p', '{attr.x}' } }), renderer({ env = { X = '{attr.x}' } }),
            renderer({ cwd = '{attr.dir}' }), { match = { 'py' }, formats = { 'svg' }, steps = { { 'p' }, { 'p', '{attr.x}' } } }, runner() }
        for _, bad in ipairs(cases) do
            local cfg, ds = C.validate({ renderers = { bad = bad } })
            assert.is_false(cfg.renderers.bad)
            assert.is_true(#errors(ds) > 0)
        end
        local cfg, ds = C.validate({ renderers = { good = renderer({ cmd = { 'p', '{attr.}', '{attr.x', '{format}' } }) },
            runners = { good = runner({ cmd = { 'p', '{attr.x}' } }) } })
        assert.equals(0, #ds)
        assert.equals('file', cfg.renderers.good.output)
        assert.equals('{tmpdir}', cfg.renderers.good.cwd)
        assert.equals('{docdir}', cfg.runners.good.cwd)
    end)

    it('replaces whole entries, preserves origins and selects workspace then byte order', function()
        local g = C.validate({ runners = { python = runner({ timeout = '1s', env = { X = '1' } }), aaa = runner() } }, 'global')
        local w = C.validate({ runners = { python = runner(), zzz = runner() } }, 'workspace')
        local cfg = C.merge(g, w)
        assert.is_nil(cfg.runners.python.timeout)
        assert.same({}, cfg.runners.python.env)
        local e, name = C.select(cfg, 'runners', 'py')
        assert.equals('python', name)
        assert.equals('workspace', e.source)
        assert.equals('global', cfg.runners.aaa.source)
        assert.is_nil(C.select(cfg, 'runners', 'none'))
        local invalid = C.validate({ runners = { python = false } }, 'workspace')
        assert.is_false(C.merge(g, invalid).runners.python)
        cfg.runners.python.cmd[1] = 'changed'
        assert.equals('python', w.runners.python.cmd[1])
    end)
end)
