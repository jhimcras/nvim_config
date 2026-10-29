local H = require('tests.spec.coderunner.helpers')
local export = require('nvim_config.coderunner.export')
local render = require('nvim_config.coderunner.render')
local cache = require('nvim_config.coderunner.cache')
local blocks = require('nvim_config.coderunner.blocks')
local api = vim.api

describe('coderunner export application', function()
    local root, buf, notify, paths, secure
    local function setup(opts)
        require('nvim_config.coderunner').setup(vim.tbl_extend('force', {
            auto_render = false, renderers = { fake = { match = { 'dot' }, formats = { 'svg', 'png' },
                cmd = H.tool('write', '{output}', 'image-{format}') } },
        }, opts or {}))
    end
    local function block() return assert(blocks.get(buf, root))[1] end
    local function start(opts)
        local done, result, err
        export.start(buf, '#one', opts, function(r, e) result, err, done = r, e, true end)
        H.wait(function() return done end)
        return result, err
    end
    local function all()
        local result
        export.all(buf, function(r) result = r end)
        H.wait(function() return result ~= nil end)
        return result
    end
    before_each(function()
        root = H.workspace()
        buf = H.buffer(root, '```dot {#one}\nx\n```\n')
        api.nvim_set_current_buf(buf)
        notify, secure = vim.notify, vim.secure.read; vim.notify = function() end
        setup({ create_attachments_dir = 'always' }); paths = cache.paths(root)
    end)
    after_each(function()
        if api.nvim_buf_is_valid(buf) then api.nvim_buf_delete(buf, { force = true }) end
        vim.fn.delete(root, 'rf'); vim.fn.delete(paths.dir, 'rf')
        vim.notify, vim.secure.read = notify, secure
    end)
    it('renders and exports then updates existing bytes and clears stale diagnostics', function()
        local result = assert(start())
        assert.equals('new', result.action); assert.equals('image-svg', cache.read(result.path))
        assert.equals('![](assets/note-one.svg)', api.nvim_buf_get_lines(buf, 4, 5, false)[1])
        H.write(result.path, 'old')
        require('nvim_config.coderunner.diagnostics').refresh(buf)
        local ds = vim.diagnostic.get(buf, { namespace = require('nvim_config.coderunner.diagnostics').namespace })
        assert.equals('stale-export', ds[1].code); assert.equals(4, ds[1].lnum); assert.matches(':CodeExport', ds[1].message)
        assert.equals('update', assert(start()).action)
        assert.equals('image-svg', cache.read(result.path))
        assert.same({}, vim.diagnostic.get(buf, { namespace = require('nvim_config.coderunner.diagnostics').namespace }))
    end)
    it('reuses identical files across gaps and creates the next free collision name', function()
        H.write(root .. '/assets/note-one.svg', 'old')
        H.write(root .. '/assets/note-one-3.svg', 'image-svg')
        local r = assert(start()); assert.equals('reuse', r.action); assert.matches('one%-3.svg$', r.path)
        assert.is_nil(vim.uv.fs_stat(root .. '/assets/note-one-2.svg'))
    end)
    it('retains copied image after link failure and reuses it on retry', function()
        local set = api.nvim_buf_set_lines
        api.nvim_buf_set_lines = function(...) error('forced link failure') end
        local r, err = start()
        api.nvim_buf_set_lines = set
        assert.is_nil(r); assert.matches('link insertion failed', err)
        assert.equals('image-svg', cache.read(root .. '/assets/note-one.svg'))
        r = assert(start()); assert.equals('reuse', r.action)
        assert.equals(1, #vim.fn.readdir(root .. '/assets'))
    end)
    it('refuses missing folder under never and handles ask decline and acceptance', function()
        setup({ create_attachments_dir = 'never' })
        local r, err = start(); assert.is_nil(r); assert.matches('does not exist', err)
        local confirm = vim.fn.confirm
        setup({ create_attachments_dir = 'ask' })
        vim.fn.confirm = function() return 2 end
        r, err = start(); assert.is_nil(r); assert.matches('declined', err)
        vim.fn.confirm = function() return 1 end
        r, err = start(); vim.fn.confirm = confirm
        assert.is_truthy(r, err)
    end)
    it('preserves CRLF and makes link insertion one undo unit', function()
        vim.bo[buf].fileformat = 'dos'
        vim.cmd('silent write')
        local before = api.nvim_buf_get_lines(buf, 0, -1, false)
        assert(start())
        vim.cmd('undo')
        assert.same(before, api.nvim_buf_get_lines(buf, 0, -1, false))
        assert(start()); vim.cmd('silent write')
        local bytes = cache.read(root .. '/note.md')
        assert.is_truthy(bytes:find('\r\n![](', 1, true)); assert.is_nil(bytes:gsub('\r\n', ''):find('\n', 1, true))
    end)
    it('preserves quote/list prefix and original code when inserting', function()
        for _, lines in ipairs({ { '> ```dot {#one}', '> x', '> ```' }, { '- ```dot {#one}', '  x', '  ```' } }) do
            api.nvim_buf_set_lines(buf, 0, -1, false, lines)
            local before = block().code
            assert(start()); assert.equals(before, block().code); assert.equals(1, #block().images)
        end
    end)
    it('refuses format mismatch and unnamed or nonmodifiable documents', function()
        api.nvim_buf_set_lines(buf, 3, -1, false, { '![](assets/existing.png)' })
        local r, err = start({ format = 'svg' }); assert.is_nil(r); assert.matches('format', err)
        vim.bo[buf].modifiable = false
        r, err = start(); assert.is_nil(r); assert.matches('modifiable', err); vim.bo[buf].modifiable = true
        api.nvim_buf_set_name(buf, '')
        r, err = start(); assert.is_nil(r); assert.matches('save', err)
    end)
    it('recovers missing adjacent targets and preserves their format and links in all', function()
        api.nvim_buf_set_lines(buf, 3, -1, false, { '![[assets/missing.png]]', '', '```dot {#two}', 'y', '```' })
        local before = api.nvim_buf_get_lines(buf, 0, -1, false)
        local result = all()
        assert.equals(1, #result.applied); assert.same({}, result.failed)
        assert.equals('image-png', cache.read(root .. '/assets/missing.png'))
        assert.same(before, api.nvim_buf_get_lines(buf, 0, -1, false))
        assert.equals(1, #vim.fn.readdir(root .. '/assets'))
    end)
    it('reports partial all failure while applying independent valid targets', function()
        api.nvim_buf_set_lines(buf, 3, -1, false, { '![](assets/one.png)', '', '```unknown {#two}', 'y', '```', '![](assets/two.png)' })
        local result = all()
        assert.equals(1, #result.applied); assert.equals(1, #result.failed)
        assert.matches('no renderer', result.failed[1].error)
        assert.equals('image-png', cache.read(root .. '/assets/one.png'))
        assert.is_nil(cache.read(root .. '/assets/two.png'))
    end)
    it('uses basename wiki targets inside attachments and preserves link text', function()
        H.write(root .. '/assets/picture.png', 'old')
        api.nvim_buf_set_lines(buf, 3, -1, false, { '![[picture]]' })
        local r = assert(start()); assert.equals('image-png', cache.read(r.path))
        assert.equals('![[picture]]', api.nvim_buf_get_lines(buf, 3, 4, false)[1])
    end)
    it('rejects attachment and cache symlink escapes', function()
        if vim.fn.has('win32') == 1 then return end
        local outside = H.workspace(); H.write(outside .. '/image.svg', 'outside')
        assert(vim.uv.fs_symlink(outside, root .. '/assets'))
        local r, err = start(); assert.is_nil(r); assert.matches('escapes', err)
        vim.uv.fs_unlink(root .. '/assets')
        vim.fn.mkdir(root .. '/assets', 'p')
        local job = assert(render.start(block(), { buf = buf })); H.wait(function() return job.result end)
        vim.uv.fs_unlink(job.path); assert(vim.uv.fs_symlink(outside .. '/image.svg', job.path))
        r, err = start(); assert.is_nil(r); assert.matches('cache', err)
        assert.equals('outside', cache.read(outside .. '/image.svg')); vim.fn.delete(outside, 'rf')
    end)
    it('rejects document and target edits made during rendering', function()
        setup({ create_attachments_dir = 'always', renderers = { fake = { match = { 'dot' }, formats = { 'png' }, steps = {
            H.tool('sleep-ms', '150'), H.tool('write', '{output}', 'image'),
        } } } })
        local done, err
        export.start(buf, '#one', {}, function(_, e) err, done = e, true end)
        api.nvim_buf_set_lines(buf, 1, 2, false, { 'edited' })
        H.wait(function() return done end); assert.matches('document changed', err)
        api.nvim_buf_set_lines(buf, 3, -1, false, { '![](assets/one.png)' })
        H.write(root .. '/assets/one.png', 'before')
        export.start(buf, '#one', {}, function(_, e) err, done = e, true end); done = false
        H.write(root .. '/assets/one.png', 'external edit')
        H.wait(function() return done end); assert.matches('target changed', err)
        assert.equals('external edit', cache.read(root .. '/assets/one.png'))
    end)
    it('leaves stale undecided when the current cache is absent', function()
        local r = assert(start()); H.write(r.path, 'old')
        local found = render.lookup(block()); vim.uv.fs_unlink(found.path)
        assert.is_nil(export.stale(block(), require('nvim_config.coderunner').resolve(root, false)))
    end)
    it('cleans temporary copies after move failure and preserves existing images', function()
        local link = vim.uv.fs_link
        vim.uv.fs_link = function() return nil, 'forced move failure' end
        local result, err = start()
        vim.uv.fs_link = link
        assert.is_nil(result); assert.matches('move failure', err)
        assert.same({}, vim.fn.readdir(root .. '/assets'))
        assert(start())
        H.write(root .. '/assets/note-one.svg', 'old')
        local rename = vim.uv.fs_rename
        vim.uv.fs_rename = function(from, to)
            if to == root .. '/assets/note-one.svg' then return nil, 'forced update failure' end
            return rename(from, to)
        end
        result, err = start(); vim.uv.fs_rename = rename
        assert.is_nil(result); assert.matches('update failure', err)
        assert.equals('old', cache.read(root .. '/assets/note-one.svg'))
        assert.same({ 'note-one.svg' }, vim.fn.readdir(root .. '/assets'))
    end)
    it('refuses new-file races instead of overwriting a concurrently created image', function()
        local link = vim.uv.fs_link
        vim.uv.fs_link = function(from, to)
            H.write(to, 'concurrent image')
            return link(from, to)
        end
        local result, err = start(); vim.uv.fs_link = link
        assert.is_nil(result); assert.matches('EEXIST', err)
        assert.equals('concurrent image', cache.read(root .. '/assets/note-one.svg'))
        assert.equals(3, api.nvim_buf_line_count(buf))
        result = assert(start()); assert.matches('one%-2.svg$', result.path)
    end)
    it('retains the export cache lease through planning and application', function()
        local apply = export.apply
        export.apply = function(buffer, plan, tick)
            local result = assert(render.gc(root, { dry_run = true }))
            assert.is_false(vim.tbl_contains(result.removed, plan.source))
            return apply(buffer, plan, tick)
        end
        local result, err = start(); export.apply = apply
        assert.is_truthy(result, err)
    end)
    it('refuses untrusted batch before invoking any renderer', function()
        H.write(root .. '/.coderunner.lua', 'return {}')
        api.nvim_buf_set_lines(buf, 3, -1, false, { '![](assets/one.png)' })
        local result = all(); assert.equals(1, #result.failed); assert.matches('Load', result.failed[1].error)
        assert.equals('none', render.lookup(block()).status)
    end)
end)
