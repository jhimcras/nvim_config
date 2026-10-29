local H = require('tests.spec.coderunner.helpers')
local diagnostics = require('nvim_config.coderunner.diagnostics')
local render = require('nvim_config.coderunner.render')
local blocks = require('nvim_config.coderunner.blocks')
local cache = require('nvim_config.coderunner.cache')
local api = vim.api

describe('coderunner diagnostics', function()
    local root, buf, notify, paths
    local function setup(cmd, enabled)
        require('nvim_config.coderunner').setup({ diagnostics = enabled ~= false,
            renderers = { dot = { match = { 'dot' }, formats = { 'png' }, cmd = cmd } } })
    end
    local function finish()
        local job = assert(render.start(blocks.get(buf, root)[1], { buf = buf }))
        H.wait(function() return job.result ~= nil end)
    end
    local function get() return vim.diagnostic.get(buf, { namespace = diagnostics.namespace }) end
    before_each(function()
        root = H.workspace(); buf = H.buffer(root, '```dot {#a}\nx\n```\n')
        api.nvim_set_current_buf(buf); paths = cache.paths(root)
        notify = vim.notify; vim.notify = function() end
        setup(H.tool('exit', '9'))
    end)
    after_each(function()
        api.nvim_buf_delete(buf, { force = true }); vim.fn.delete(root, 'rf'); vim.fn.delete(paths.dir, 'rf')
        vim.notify = notify
    end)
    it('reports render failures only after execution and removes them on key change', function()
        diagnostics.refresh(buf); assert.same({}, get())
        finish(); assert.equals('render-failed', get()[1].code)
        assert.equals(vim.diagnostic.severity.WARN, get()[1].severity); assert.equals(0, get()[1].lnum)
        api.nvim_buf_set_lines(buf, 1, 2, false, { 'changed' })
        diagnostics.refresh(buf); assert.same({}, get())
        setup(H.tool('write', '{output}', 'image')); finish(); assert.same({}, get())
    end)
    it('reports every duplicate ID and honors diagnostics=false', function()
        api.nvim_buf_set_lines(buf, -1, -1, false, { '```dot {#a}', 'y', '```' })
        diagnostics.refresh(buf); assert.equals(2, #get())
        assert.equals('duplicate-code-id', get()[1].code)
        assert.equals(vim.diagnostic.severity.ERROR, get()[1].severity)
        setup(H.tool('exit', '9'), false); assert.same({}, get())
    end)
    it('keeps only the stderr first line in diagnostics and bounds persisted Unicode errors', function()
        local script = H.write(root .. '/error.lua', [[
io.stderr:write('first line\n' .. string.rep('가', 1100))
os.exit(1)
]])
        setup({ vim.v.progpath, '-u', 'NONE', '-i', 'NONE', '-l', script })
        finish()
        assert.equals('first line', get()[1].message)
        local record = cache.manifest(paths)[blocks.get(buf, root)[1].key]
        assert.equals(1024, vim.fn.strchars(record.failure.message))
        assert.equals(record.failure.message, require('nvim_config.coderunner.exec').clean_utf8(record.failure.message))
    end)

end)
