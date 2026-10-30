local export = require('nvim_config.coderunner.export')
local blocks = require('nvim_config.coderunner.blocks')
local function fake(files)
    files = vim.tbl_extend('force', { ['/w'] = true, ['/w/assets'] = true }, files or {})
    return { stat = function(p) if files[p] ~= nil then return { type = files[p] == true and 'directory' or 'file' } end end,
        realpath = function(p) return files[p] ~= nil and p or nil end,
        read = function(p) return type(files[p]) == 'string' and files[p] or nil end,
        list = function(p)
            local out = {}
            for path in pairs(files) do
                if vim.fs.dirname(path) == p then out[#out + 1] = vim.fs.basename(path) end
            end
            return out
        end }
end
local function parsed(text, path)
    return assert(blocks.parse(text .. '\n', { root = '/w', path = path or '/w/note.md' }))[1]
end
local function plan(text, opts)
    local b = parsed(text)
    opts = vim.tbl_extend('force', { fs = fake(), bytes = 'image', format = 'png',
        lines = vim.split(text, '\n', { plain = true }) }, opts or {})
    return export.plan(b, opts)
end
describe('coderunner export planning', function()
    it('creates deterministic names and markdown links without writing files', function()
        local p = assert(plan('```dot {#diagram}\nx\n```'))
        assert.equals('new', p.action); assert.equals('/w/assets/note-diagram.png', p.target)
        assert.same({ '', '![](assets/note-diagram.png)' }, p.edits[1].lines)
    end)
    it('reuses identical bytes beyond gaps before choosing a free suffix', function()
        local io = fake({ ['/w/assets/note-dot-1.png'] = 'different', ['/w/assets/note-dot-1-3.png'] = 'image' })
        local p = assert(plan('```dot\nx\n```', { fs = io }))
        assert.equals('reuse', p.action); assert.equals('/w/assets/note-dot-1-3.png', p.target)
        p = assert(plan('```dot\nx\n```', { fs = io, bytes = 'new' }))
        assert.equals('/w/assets/note-dot-1-2.png', p.target)
    end)
    it('updates the first attached image and recovers missing targets', function()
        for _, link in ipairs({ '![](else.png) ![](assets/missing.png)', '![[assets/missing.png]]', '<img src="assets/missing.png">' }) do
            local p = assert(plan('```dot\nx\n```\n\n' .. link))
            assert.equals('update', p.action); assert.equals('/w/assets/missing.png', p.target); assert.same({}, p.edits)
        end
    end)
    it('distinguishes zero one and two blank lines', function()
        for n = 0, 2 do
            local p = assert(plan('```dot\nx\n```\n' .. string.rep('\n', n) .. '![](assets/old.png)'))
            assert.equals(n < 2 and 'update' or 'new', p.action)
        end
    end)
    it('rejects format mismatch duplicate IDs and output fences', function()
        local p, err = plan('```dot\nx\n```\n![](assets/x.svg)')
        assert.is_nil(p); assert.matches('format', err)
        p, err = plan('```dot {#x}\nx\n```\n```dot {#x}\nx\n```')
        assert.is_nil(p); assert.matches('duplicate', err)
        p, err = plan('```output\nx\n```'); assert.is_nil(p); assert.matches('fence', err)
    end)
    it('preserves quoted and list containers while verifying code identity', function()
        for _, text in ipairs({ '> ```dot\n> x\n> ```', '- ```dot\n  x\n  ```', '  ```dot\n  x\n  ```' }) do
            local p = assert(plan(text, { link_style = 'wiki' }))
            assert.matches('!%[%[assets/note%-dot%-1.png%]%]', p.edits[1].lines[2])
            assert.equals(p.block.close_prefix .. '!', p.edits[1].lines[2]:sub(1, #p.block.close_prefix + 1))
        end
    end)
    it('preserves an existing output fence and rejects an unclosed source', function()
        local p, err = plan('```dot\nx\n```\n```output\nresult\n```')
        -- Inserting immediately after the code preserves the output block and
        -- makes the new paragraph the code's adjacent image.
        assert.is_truthy(p, err)
        p, err = plan('```dot\nx')
        assert.is_nil(p); assert.matches('fence', err)
    end)
    it('resolves document relative and workspace relative folders', function()
        local b = parsed('```dot\nx\n```', '/w/notes/note.md')
        local io = fake({ ['/w/notes'] = true, ['/w/notes/assets'] = true })
        assert.equals('/w/notes/assets', export.folder(b, './assets', io))
        assert.equals('/w/assets', export.folder(b, 'assets', io))
        for _, invalid in ipairs({ '../out', 'assets/../out', '/tmp', 'C:/out', 'a\\b' }) do
            assert.is_nil(export.folder(b, invalid, io))
        end
    end)
    it('rejects missing folders and symlink escape', function()
        local io = fake(); local real = io.realpath
        io.realpath = function(p) if p == '/w/assets' then return '/outside' end; return real(p) end
        local p, err = plan('```dot\nx\n```', { fs = io })
        assert.is_nil(p); assert.matches('escapes', err)
        io = fake(); local stat = io.stat
        io.stat = function(p) if p ~= '/w/assets' then return stat(p) end end
        p, err = plan('```dot\nx\n```', { fs = io }); assert.is_nil(p); assert.matches('does not exist', err)
    end)
    it('normalizes real paths without accepting sibling directory escapes', function()
        local io = fake()
        local realpath = io.realpath
        local function native(path)
            if vim.fn.has('win32') == 1 then return (path:gsub('/', '\\')) end
            return path .. '/.'
        end
        io.realpath = function(path)
            local real = realpath(path)
            return real and native(real)
        end
        assert(plan('```dot\nx\n```', { fs = io }))
        io.realpath = function(path)
            if path == '/w/assets' then return native('/w-sibling/assets') end
            local real = realpath(path)
            return real and native(real)
        end
        local p, err = plan('```dot\nx\n```', { fs = io })
        assert.is_nil(p); assert.matches('escapes', err)
    end)
    it('limits basename wiki lookup to attachments and rejects ambiguity', function()
        local io = fake({ ['/w/assets/picture.png'] = 'old', ['/w/picture.png'] = 'elsewhere' })
        local p = assert(plan('```dot\nx\n```\n![[picture]]', { fs = io }))
        assert.equals('/w/assets/picture.png', p.target)
        io = fake({ ['/w/assets/picture.png'] = 'old', ['/w/assets/picture.svg'] = 'old' })
        local err; p, err = plan('```dot\nx\n```\n![[picture]]', { fs = io })
        assert.is_nil(p); assert.matches('ambiguous', err)
    end)
    it('links root relative attachments from nested documents', function()
        local text = '```dot {#one}\nx\n```\n'
        local b = parsed(text, '/w/notes/note.md')
        local p = assert(export.plan(b, { fs = fake({ ['/w/notes'] = true }), attachments = 'assets',
            format = 'png', bytes = 'image', lines = vim.split(text, '\n', { plain = true }) }))
        assert.equals('![](../assets/note-one.png)', p.edits[1].lines[2])
    end)
    it('encodes spaces in attachment paths without changing link interpretation', function()
        local io = fake({ ['/w/my assets'] = true })
        for _, style in ipairs({ 'markdown', 'wiki' }) do
            local p = assert(plan('```dot\nx\n```', { fs = io, attachments = './my assets', link_style = style }))
            assert.matches('my%%20assets/', p.edits[1].lines[2])
        end
    end)
    it('sanitizes names and percent encodes paths for both link styles', function()
        for _, style in ipairs({ 'markdown', 'wiki' }) do
            local p = assert(plan('```dot {#a/b:c}\nx\n```', { attachments = './assets', link_style = style }))
            assert.equals('/w/assets/note-a-b-c.png', p.target)
        end
    end)
end)
