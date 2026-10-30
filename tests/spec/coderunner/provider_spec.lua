local H = require('tests.spec.coderunner.helpers')
local provider = require('nvim_config.coderunner.provider')
local render = require('nvim_config.coderunner.render')
local cache = require('nvim_config.coderunner.cache')
local registry = require('nvim_config.launcher.registry')
local api = vim.api

describe('coderunner provider', function()
    local root, buf, notify, events, event_id
    local function setup(entry)
        require('nvim_config.coderunner').setup({ auto_render = false, renderers = {
            fake = entry or { match = { 'dot' }, formats = { 'png' }, input = 'stdin', output = 'stdout', cmd = H.tool('stdin') },
        } })
    end
    local function item() return provider.diagrams(buf)[1] end
    local function ready() H.wait(function() return item() and item().status ~= 'pending' end) end
    before_each(function()
        root = H.workspace()
        buf = H.buffer(root, '```dot {#one}\nsaved\n```\n')
        api.nvim_set_current_buf(buf); vim.bo[buf].filetype = 'markdown'
        notify = vim.notify; vim.notify = function() end
        setup(); events = 0
        event_id = api.nvim_create_autocmd('User', { pattern = 'CodeRunnerDiagrams', callback = function(a)
            if a.data.buf == buf then events = events + 1 end
        end })
    end)
    after_each(function()
        render.cancel_buffer(buf)
        api.nvim_del_autocmd(event_id)
        if api.nvim_buf_is_valid(buf) then api.nvim_buf_delete(buf, { force = true }) end
        vim.fn.delete(cache.paths(root).dir, 'rf'); vim.fn.delete(root, 'rf'); vim.notify = notify
    end)
    it('exposes none/pending/ready and renders unsaved text through the public API', function()
        local coderunner = require('nvim_config.coderunner')
        assert.equals('none', coderunner.diagrams(buf)[1].status)
        api.nvim_buf_set_lines(buf, 1, 2, false, { 'unsaved' })
        assert.is_true(coderunner.request_live(buf, 1)); assert.equals('pending', item().status)
        ready(); assert.equals('ready', item().status)
        assert.equals('unsaved\n', cache.read(item().path)); assert.equals(1, events)
        assert.is_false(item().stale)
    end)
    it('coalesces pending live requests and reuses the cache after relocation', function()
        local original = require('nvim_config.coderunner.command').run
        local calls = 0
        require('nvim_config.coderunner.command').run = function(...)
            calls = calls + 1; return original(...)
        end
        assert.is_true(provider.request_live(buf, 1)); assert.is_true(provider.request_live(buf, 1))
        ready(); local path = item().path
        api.nvim_buf_set_lines(buf, 0, 0, false, { 'paragraph', '' })
        assert.equals(2, item().start_row); assert.equals(path, item().path)
        assert.is_true(provider.request_live(buf, 3)); ready()
        require('nvim_config.coderunner.command').run = original
        assert.equals(1, calls); assert.equals(2, events)
    end)
    it('returns SVG, stale previews, and only the first failure line', function()
        setup({ match = { 'dot' }, formats = { 'svg' }, input = 'stdin', output = 'stdout', cmd = H.tool('stdin') })
        provider.request_live(buf, 1); ready(); assert.equals('svg', item().format)
        local path = item().path
        api.nvim_buf_set_lines(buf, 1, 2, false, { 'changed' })
        assert.is_true(item().stale); assert.equals(path, item().path)
        setup({ match = { 'dot' }, formats = { 'svg' }, cmd = { vim.v.progpath, '-u', 'NONE', '-i', 'NONE', '-l',
            H.write(root .. '/fail.lua', "io.stderr:write('first\\nsecond\\n'); os.exit(1)") } })
        provider.request_live(buf, 1); ready()
        assert.equals('failed', item().status); assert.equals('first', item().error)
        assert.equals(path, item().path); assert.is_true(item().stale)
    end)
    it('never prompts or executes an unloaded workspace configuration', function()
        H.write(root .. '/.coderunner.lua', "error('must not execute')")
        local secure = vim.secure.read
        vim.secure.read = function() error('must not prompt') end
        local accepted = provider.request_live(buf, 1)
        local items = provider.diagrams(buf)
        vim.secure.read = secure
        assert.is_false(accepted); assert.same({}, items); assert.equals(0, events)
    end)
    it('accepts a loaded workspace renderer without prompting again', function()
        H.write(root .. '/.coderunner.lua', "return {renderers={localtool={match={'dot'},formats={'png'},input='stdin',output='stdout',cmd=" .. vim.inspect(H.tool('stdin')) .. '}}}')
        local secure = vim.secure.read
        vim.secure.read = function(path) return cache.read(path) end
        require('nvim_config.coderunner.trust').load(root)
        vim.secure.read = function() error('must not prompt') end
        assert.is_true(provider.request_live(buf, 1)); ready()
        vim.secure.read = secure
        assert.equals('ready', item().status)
    end)
    it('emits one event for a changed block list and no event for an unchanged list', function()
        api.nvim_buf_set_lines(buf, 0, 0, false, { '' })
        api.nvim_exec_autocmds('TextChanged', { buffer = buf })
        assert.equals(1, events)
        api.nvim_exec_autocmds('TextChanged', { buffer = buf })
        assert.equals(1, events); assert.equals(1, item().start_row)
    end)
    it('rejects invalid rows, duplicate ids and output blocks', function()
        assert.is_false(provider.request_live(buf, 100))
        api.nvim_buf_set_lines(buf, 3, 3, false, { '```dot {#one}', 'duplicate', '```', '```output', 'x', '```' })
        assert.is_false(provider.request_live(buf, 1)); assert.is_false(provider.request_live(buf, 7))
        assert.same({}, provider.diagrams(buf))
    end)
    it('registers renders in the process list and connects termination', function()
        setup({ match = { 'dot' }, formats = { 'png' }, cmd = H.tool('hang') })
        assert.is_true(provider.request_live(buf, 1))
        local found
        for _, process in ipairs(registry.list()) do
            if process.buf == buf and process.key:match('coderunner:render:') then found = process end
        end
        assert.is_truthy(found); registry.terminate(found.key)
        assert.is_nil(registry.processes[found.key]); ready(); assert.equals('none', item().status)
    end)
    it('registers runner jobs and removes completed entries', function()
        require('nvim_config.coderunner').setup({ auto_render = false, runners = {
            fake = { match = { 'dot' }, cmd = H.tool('hang') },
        } })
        local run = require('nvim_config.coderunner.run')
        local job = assert(run.start(buf, '#one', { open = false }))
        local key = 'coderunner:run:' .. job.id
        assert.is_truthy(registry.processes[key]); registry.terminate(key)
        H.wait(function() return job.result ~= nil end)
        assert.equals('cancelled', job.status); assert.is_nil(registry.processes[key])
        run.release(job.id)
    end)
    it('binds markdown commands locally', function()
        local mapped = {}
        for _, m in ipairs(api.nvim_buf_get_keymap(buf, 'n')) do mapped[m.desc] = m.rhs end
        assert.equals('<Cmd>CodeRun<CR>', mapped.CodeRun)
        assert.equals('<Cmd>CodeRender!<CR>', mapped['CodeRender!'])
    end)
    it('uses the absolute document folder in render commands and keys', function()
        vim.fn.mkdir(root .. '/nested', 'p')
        api.nvim_buf_set_name(buf, root .. '/nested/note.md')
        setup({ match = { 'dot' }, formats = { 'png' }, output = 'stdout', cmd = H.tool('dump'), cwd = '{docdir}' })
        assert.is_true(provider.request_live(buf, 1)); ready()
        local dump = vim.json.decode(cache.read(item().path))
        assert.equals(root .. '/nested', vim.fs.normalize(dump.cwd))
        local b = require('nvim_config.coderunner.blocks').get(buf, root)[1]
        local entry = require('nvim_config.coderunner').resolve(root).renderers.fake
        local absolute = vim.deepcopy(b); absolute.path = root .. '/nested/note.md'
        assert.equals(render.key(absolute, entry), render.key(b, entry))
    end)
end)
