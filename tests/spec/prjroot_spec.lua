local prjroot = require('prjroot')

local function write_file(path, content)
    local f = assert(io.open(path, 'w'))
    f:write(content or '')
    f:close()
end

local function make_tmpdir()
    local p = vim.fn.tempname()
    vim.fn.mkdir(p, 'p')
    return p
end

describe('prjroot.GetProjectRoot', function()
    local tmpdir

    before_each(function()
        tmpdir = make_tmpdir()
    end)

    after_each(function()
        vim.fn.delete(tmpdir, 'rf')
    end)

    it('finds root from a nested file', function()
        vim.fn.mkdir(tmpdir .. '/subdir', 'p')
        vim.fn.mkdir(tmpdir .. '/.git', 'p')
        write_file(tmpdir .. '/subdir/file.lua')

        local root = prjroot.GetProjectRoot(tmpdir .. '/subdir/file.lua', { '.git' })
        assert.equals(tmpdir, root)
    end)

    it('finds root when file is at the root itself', function()
        vim.fn.mkdir(tmpdir .. '/.git', 'p')
        write_file(tmpdir .. '/file.lua')

        local root = prjroot.GetProjectRoot(tmpdir .. '/file.lua', { '.git' })
        assert.equals(tmpdir, root)
    end)

    it('finds root with custom marker .prjroot', function()
        vim.fn.mkdir(tmpdir .. '/a/b', 'p')
        write_file(tmpdir .. '/.prjroot')
        write_file(tmpdir .. '/a/b/code.lua')

        local root = prjroot.GetProjectRoot(tmpdir .. '/a/b/code.lua', { '.prjroot' })
        assert.equals(tmpdir, root)
    end)

    it('returns nil when no marker found in any parent', function()
        vim.fn.mkdir(tmpdir .. '/sub', 'p')
        write_file(tmpdir .. '/sub/file.lua')

        local root = prjroot.GetProjectRoot(tmpdir .. '/sub/file.lua', { '.nonexistent_marker_xyz' })
        assert.is_nil(root)
    end)

    it('returns nil for nil filepath', function()
        local root = prjroot.GetProjectRoot(nil, { '.git' })
        assert.is_nil(root)
    end)
end)

describe('prjroot cache', function()
    local tmpdir

    before_each(function()
        tmpdir = make_tmpdir()
        prjroot.ClearCache()
    end)

    after_each(function()
        vim.fn.delete(tmpdir, 'rf')
    end)

    it('keeps the cached root until the cache is cleared', function()
        vim.fn.mkdir(tmpdir .. '/sub/.git', 'p')
        write_file(tmpdir .. '/.prjroot')
        vim.fn.mkdir(tmpdir .. '/sub/inner', 'p')
        write_file(tmpdir .. '/sub/inner/file.lua')
        assert.equals(tmpdir .. '/sub', prjroot.GetProjectRoot(tmpdir .. '/sub/inner/file.lua', { '.git', '.prjroot' }))

        vim.fn.delete(tmpdir .. '/sub/.git', 'rf')
        assert.equals(tmpdir .. '/sub', prjroot.GetProjectRoot(tmpdir .. '/sub/inner/file.lua', { '.git', '.prjroot' }))

        prjroot.ClearCache()
        assert.equals(tmpdir, prjroot.GetProjectRoot(tmpdir .. '/sub/inner/file.lua', { '.git', '.prjroot' }))
    end)

    it('shares a cached root with sibling files in visited folders', function()
        vim.fn.mkdir(tmpdir .. '/a/b', 'p')
        write_file(tmpdir .. '/.prjroot')
        assert.equals(tmpdir, prjroot.GetProjectRoot(tmpdir .. '/a/b/x.lua', { '.prjroot' }))

        -- a new marker in 'a' is not seen until the cache is cleared
        write_file(tmpdir .. '/a/.prjroot')
        assert.equals(tmpdir, prjroot.GetProjectRoot(tmpdir .. '/a/y.lua', { '.prjroot' }))
        prjroot.ClearCache()
        assert.equals(tmpdir .. '/a', prjroot.GetProjectRoot(tmpdir .. '/a/y.lua', { '.prjroot' }))
    end)

    it('clears the root cache on BufWritePost', function()
        prjroot.setup()
        vim.fn.mkdir(tmpdir .. '/a', 'p')
        write_file(tmpdir .. '/.prjroot')
        assert.equals(tmpdir, prjroot.GetProjectRoot(tmpdir .. '/a/x.lua', { '.prjroot' }))

        vim.cmd('silent edit ' .. vim.fn.fnameescape(tmpdir .. '/a/.prjroot'))
        vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'return {}' })
        vim.cmd('silent write')
        assert.equals(tmpdir .. '/a', prjroot.GetProjectRoot(tmpdir .. '/a/x.lua', { '.prjroot' }))
        vim.cmd('bwipeout!')
    end)

    it('loads .prjroot once and reloads it when the file changes', function()
        _G.__prjroot_loads = 0
        write_file(tmpdir .. '/.prjroot', '_G.__prjroot_loads = _G.__prjroot_loads + 1; return { v = 1 }')
        local file = tmpdir .. '/file.lua'

        assert.equals(1, prjroot.GetPrjrootConfig(file, { '.prjroot' }).v)
        assert.equals(1, prjroot.GetPrjrootConfig(file, { '.prjroot' }).v)
        assert.equals(1, _G.__prjroot_loads)

        write_file(tmpdir .. '/.prjroot', '_G.__prjroot_loads = _G.__prjroot_loads + 1; return { v = 22 }')
        assert.equals(22, prjroot.GetPrjrootConfig(file, { '.prjroot' }).v)
        assert.equals(2, _G.__prjroot_loads)
    end)

    it('returns nil once .prjroot is deleted', function()
        vim.fn.mkdir(tmpdir .. '/.git', 'p')
        write_file(tmpdir .. '/.prjroot', 'return { v = 1 }')
        local file = tmpdir .. '/file.lua'
        assert.equals(1, prjroot.GetPrjrootConfig(file, { '.git' }).v)

        vim.fn.delete(tmpdir .. '/.prjroot')
        assert.is_nil(prjroot.GetPrjrootConfig(file, { '.git' }))
    end)
end)
