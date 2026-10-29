local H = require('tests.spec.coderunner.helpers')
local api = vim.api
local auto = require('nvim_config.coderunner.autorender')
local render = require('nvim_config.coderunner.render')
local cache = require('nvim_config.coderunner.cache')

describe('coderunner automatic rendering', function()
    local root, buf, calls, original, notify, secure, paths
    local text = '```dot {#one}\na\n```\n\n```dot {#two}\nb\n```\n'
    local function setup(opts)
        require('nvim_config.coderunner').setup(vim.tbl_extend('force', {
            auto_render_debounce = '20ms', renderers = { fake = {
                match = { 'dot' }, formats = { 'svg' }, cmd = H.tool('write', '{output}', 'image'),
            } },
        }, opts or {}))
    end
    local function event(name)
        api.nvim_exec_autocmds(name, { buffer = buf, modeline = false })
    end
    local function save(value)
        H.write(root .. '/note.md', value)
        event('BufWritePost')
    end
    local function settle() vim.wait(80, function() return false end, 5) end
    before_each(function()
        root, calls = H.workspace(), {}
        buf = H.buffer(root, text); api.nvim_set_current_buf(buf)
        notify = vim.notify; vim.notify = function() end
        secure = vim.secure.read
        original = render.start
        render.start = function(block, opts, cb)
            local job = { block = block, opts = opts, callback = cb, cancelled = false }
            function job.cancel() job.cancelled = true; return true end
            calls[#calls + 1] = job
            return job
        end
        setup(); paths = cache.paths(root)
    end)
    after_each(function()
        auto.close(buf); render.start = original; vim.secure.read = secure
        if api.nvim_buf_is_valid(buf) then api.nvim_buf_delete(buf, { force = true }) end
        vim.fn.delete(paths.dir, 'rf'); vim.fn.delete(root, 'rf'); vim.notify = notify
    end)
    it('records the disk baseline without running on read or ordinary open', function()
        event('BufReadPost'); event('BufWinEnter'); save(text); settle()
        assert.equals(0, #calls)
    end)
    it('renders only changed saved blocks, using disk rather than unsaved buffer text', function()
        api.nvim_buf_set_lines(buf, 1, 2, false, { 'unsaved' })
        save(text:gsub('\na\n', '\nsaved\n')); H.wait(function() return #calls == 1 end)
        assert.equals('saved\n', calls[1].block.code)
        assert.equals('one', calls[1].block.id)
        assert.is_true(calls[1].opts.batch); assert.is_nil(calls[1].opts.explicit)
        save(text:gsub('\na\n', '\nsaved\n')); settle(); assert.equals(1, #calls)
    end)
    it('reuses identical disk facts but invalidates snapshots when workspace trust changes', function()
        local blocks = require('nvim_config.coderunner.blocks')
        local parse, count = blocks.parse, 0
        blocks.parse = function(...) count = count + 1; return parse(...) end
        save(text); save(text)
        blocks.parse = parse
        assert.equals(0, count)
        H.write(root .. '/.coderunner.lua', 'return {}')
        save(text); settle(); assert.equals(0, #calls)
        vim.secure.read = function(path) return cache.read(path) end
        require('nvim_config.coderunner.trust').load(root)
        save(text); H.wait(function() return #calls == 2 end)
        for _, job in ipairs(calls) do assert.is_true(job.opts.batch) end
    end)
    it('debounces successive saves and cancels running predecessors', function()
        save(text:gsub('\na\n', '\nfirst\n'))
        save(text:gsub('\na\n', '\nsecond\n'))
        H.wait(function() return #calls == 1 end)
        assert.equals('second\n', calls[1].block.code)
        save(text:gsub('\na\n', '\nthird\n'))
        assert.is_true(calls[1].cancelled)
        H.wait(function() return #calls == 2 end)
        assert.equals('third\n', calls[2].block.code)
    end)
    it('keeps jobs while editing and cancels them on unload or deletion', function()
        save(text:gsub('\na\n', '\nchanged\n')); H.wait(function() return #calls == 1 end)
        api.nvim_buf_set_lines(buf, 1, 2, false, { 'edit after save' }); event('TextChanged')
        assert.is_false(calls[1].cancelled)
        event('BufUnload'); assert.is_true(calls[1].cancelled)
        settle(); assert.equals(1, #calls)
    end)
    it('cancels debounced jobs when closing and when blocks are removed', function()
        save(text:gsub('\na\n', '\nchanged\n')); save('ordinary paragraph\n'); settle()
        assert.equals(0, #calls)
        save(text); event('BufDelete'); settle(); assert.equals(0, #calls)
    end)
    it('renders the first saved content of a new document', function()
        auto.close(buf)
        vim.fn.delete(root .. '/note.md')
        event('BufNewFile')
        save(text); H.wait(function() return #calls == 2 end)
    end)
    it('rechecks disabled automatic rendering during debounce', function()
        save(text:gsub('\na\n', '\nchanged\n'))
        local resolve = require('nvim_config.coderunner').resolve
        require('nvim_config.coderunner').resolve = function(...)
            local cfg, status = resolve(...); cfg.auto_render = false; return cfg, status
        end
        settle()
        require('nvim_config.coderunner').resolve = resolve
        assert.equals(0, #calls)
    end)
    it('does not prompt or render for unloaded or invalidated workspace configuration', function()
        H.write(root .. '/.coderunner.lua', 'return {}')
        vim.secure.read = function() error('automatic path prompted') end
        save(text:gsub('\na\n', '\nchanged\n')); settle(); assert.equals(0, #calls)
        vim.secure.read = function(path) return cache.read(path) end
        assert.equals('loaded', require('nvim_config.coderunner.trust').load(root).state)
        save(text:gsub('\na\n', '\ntrusted\n')); H.wait(function() return #calls == 2 end)
        H.write(root .. '/.coderunner.lua', 'return { auto_render = true }')
        vim.secure.read = function() error('automatic path prompted') end
        save(text:gsub('\na\n', '\ninvalidated\n')); settle()
        assert.equals(2, #calls); assert.is_true(calls[1].cancelled)
    end)
    it('does not repeat a failed saved key until code changes', function()
        local changed = text:gsub('\na\n', '\nchanged\n')
        save(changed); H.wait(function() return #calls == 1 end)
        calls[1].result = { status = 'failed' }; calls[1].callback(calls[1])
        save(changed); settle(); assert.equals(1, #calls)
        save(text); H.wait(function() return #calls == 2 end)
    end)
    it('can disable saving independently of opt-in render on open', function()
        setup({ auto_render = false })
        save(text:gsub('\na\n', '\nchanged\n')); settle(); assert.equals(0, #calls)
        setup({ auto_render = false, render_on_open = true })
        event('BufWinEnter'); H.wait(function() return #calls > 0 end)
        assert.is_true(calls[1].opts.global_only)
    end)
    it('open rendering uses visible global blocks only and deduplicates pending keys', function()
        setup({ render_on_open = true })
        event('BufWinEnter'); event('BufWinEnter')
        H.wait(function() return #calls > 0 end); local count = #calls
        event('BufWinEnter'); settle(); assert.equals(count, #calls)
        for _, job in ipairs(calls) do assert.is_true(job.opts.global_only) end
        auto.close(buf)
        H.write(root .. '/.coderunner.lua', "return { renderers = { localdot = { match = {'dot'}, formats = {'svg'}, cmd = {'local-tool'} } } }")
        vim.secure.read = function(path) return cache.read(path) end
        require('nvim_config.coderunner.trust').load(root)
        auto.read(buf); event('BufWinEnter'); settle(); assert.equals(count, #calls)
    end)
    it('skips existing current images and suppresses repeated open failures', function()
        setup({ render_on_open = true })
        local list = require('nvim_config.coderunner.blocks').get(buf, root)
        for _, block in ipairs(list) do
            local desc = assert(render.describe(block)); H.write(desc.path, 'cached')
        end
        event('BufWinEnter'); settle(); assert.equals(0, #calls)
        local desc = render.describe(list[1]); vim.fn.delete(desc.path)
        event('BufWinEnter'); H.wait(function() return #calls == 1 end)
        calls[1].result = { status = 'failed' }; calls[1].callback(calls[1])
        event('BufWinEnter'); settle(); assert.equals(1, #calls)
    end)
    it('does not request blocks outside the current window', function()
        local lines = { 'visible heading' }
        for _ = 1, 100 do lines[#lines + 1] = '' end
        vim.list_extend(lines, { '```dot', 'hidden', '```' })
        api.nvim_buf_set_lines(buf, 0, -1, false, lines)
        api.nvim_win_set_cursor(0, { 1, 0 }); vim.cmd('normal! zt')
        setup({ render_on_open = true })
        event('BufWinEnter'); settle(); assert.equals(0, #calls)
    end)
    it('integrates a real save render and cancels a superseded result before publication', function()
        render.start = original
        setup({ renderers = { fake = { match = { 'dot' }, formats = { 'svg' },
            steps = { H.tool('sleep-ms', '150'), H.tool('write', '{output}', 'saved image') } } } })
        local changed = text:gsub('\na\n', '\nchanged\n')
        save(changed)
        local old = require('nvim_config.coderunner.blocks').parse(changed, { path = root .. '/note.md', root = root })[1]
        H.wait(function() return render.lookup(old).status == 'pending' end)
        save(text:gsub('\na\n', '\nnewest\n'))
        local latest = require('nvim_config.coderunner.blocks').parse(cache.read(root .. '/note.md'), { path = root .. '/note.md', root = root })[1]
        H.wait(function() return render.lookup(latest).status == 'ready' end)
        assert.is_nil(vim.uv.fs_stat(render.describe(old).path))
        assert.is_true(render.lookup(old).stale)
        assert.equals('saved image', cache.read(render.lookup(latest).path))
    end)
end)
