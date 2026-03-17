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
