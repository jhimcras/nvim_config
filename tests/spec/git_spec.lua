local function write_file(path, content)
    local f = assert(io.open(path, 'w'))
    f:write(content)
    f:close()
end

local function make_tmpdir()
    local p = vim.fn.tempname()
    vim.fn.mkdir(p, 'p')
    return p
end

-- git module caches by dir; use a fresh tmpdir per test to avoid TTL collisions.
local function fresh_git()
    package.loaded['git'] = nil
    return require('git')
end

describe('git.git_branch_commit', function()
    local tmpdir

    before_each(function()
        tmpdir = make_tmpdir()
    end)

    after_each(function()
        vim.fn.delete(tmpdir, 'rf')
    end)

    it('symbolic ref: returns branch and commit', function()
        local git = fresh_git()
        vim.fn.mkdir(tmpdir .. '/.git/refs/heads', 'p')
        write_file(tmpdir .. '/.git/HEAD', 'ref: refs/heads/main\n')
        write_file(tmpdir .. '/.git/refs/heads/main', 'abc1234abcdef\n')

        local branch, commit = git.git_branch_commit(tmpdir)
        assert.equals('main', branch)
        assert.equals('abc1234abcdef', commit)
    end)

    it('detached HEAD: returns nil branch and commit hash', function()
        local git = fresh_git()
        vim.fn.mkdir(tmpdir .. '/.git', 'p')
        write_file(tmpdir .. '/.git/HEAD', 'abc1234abcdef\n')

        local branch, commit = git.git_branch_commit(tmpdir)
        assert.is_nil(branch)
        assert.equals('abc1234abcdef', commit)
    end)

    it('packed-refs fallback: returns branch and commit', function()
        local git = fresh_git()
        vim.fn.mkdir(tmpdir .. '/.git/refs/heads', 'p')
        write_file(tmpdir .. '/.git/HEAD', 'ref: refs/heads/feature\n')
        -- no loose ref file; commit lives in packed-refs
        write_file(tmpdir .. '/.git/packed-refs', '# pack-refs with: peeled fully-peeled sorted\ndeadbeef12345678 refs/heads/feature\n')

        local branch, commit = git.git_branch_commit(tmpdir)
        assert.equals('feature', branch)
        assert.equals('deadbeef12345678', commit)
    end)

    it('no .git directory: returns nil, nil', function()
        local git = fresh_git()
        -- tmpdir exists but has no .git
        local branch, commit = git.git_branch_commit(tmpdir)
        assert.is_nil(branch)
        assert.is_nil(commit)
    end)

    it('worktree .git file: reads from real gitdir', function()
        local git = fresh_git()
        -- real gitdir sits next to the worktree dir
        local real_gitdir = tmpdir .. '/.git_real'
        vim.fn.mkdir(real_gitdir .. '/refs/heads', 'p')
        write_file(real_gitdir .. '/HEAD', 'ref: refs/heads/worktree-branch\n')
        write_file(real_gitdir .. '/refs/heads/worktree-branch', 'cafebabe0000\n')
        -- .git is a file pointing to the real gitdir
        write_file(tmpdir .. '/.git', 'gitdir: .git_real\n')

        local branch, commit = git.git_branch_commit(tmpdir)
        assert.equals('worktree-branch', branch)
        assert.equals('cafebabe0000', commit)
    end)
end)

describe('git.get_fugitive_info', function()
    local git = fresh_git()
    it('parses fugitive blob name: index', function()
        local git = fresh_git()
        local name = 'fugitive:///repo/.git//0/file.lua'
        local old_buf_name = vim.api.nvim_buf_get_name
        vim.api.nvim_buf_get_name = function() return name end

        local info = git.get_fugitive_info(0)
        assert.equals('blob', info.type)
        assert.equals('INDEX', info.obj)
        assert.equals('file.lua', info.file)

        vim.api.nvim_buf_get_name = old_buf_name
    end)

    it('parses fugitive blob name: commit hash', function()
        local git = fresh_git()
        local name = 'fugitive:///repo/.git//deadbeef12345678/file.lua'
        local old_buf_name = vim.api.nvim_buf_get_name
        vim.api.nvim_buf_get_name = function() return name end

        local info = git.get_fugitive_info(0)
        assert.equals('blob', info.type)
        assert.equals('deadbee', info.obj)
        assert.equals('file.lua', info.file)

        vim.api.nvim_buf_get_name = old_buf_name
    end)

    it('returns summary info if fugitive_status exists', function()
        local git = fresh_git()
        vim.b.fugitive_status = {
            rev_parse = { cwd = '/repo' },
            props = {
                ["branch.head"] = 'main',
                ["branch.upstream"] = 'origin/main',
                ["branch.ab"] = '+1 -0'
            }
        }

        local info = git.get_fugitive_info(0)
        assert.equals('summary', info.type)
        assert.equals('/repo', info.cwd)
        assert.equals('main', info.head)
        assert.equals('origin/main', info.upstream)
        assert.equals('+1 -0', info.ab)

        vim.b.fugitive_status = nil
    end)

    it('parses fugitive diff name', function()
        -- Mock buffer name for a diff: fugitive:///path/to/repo/.git//1:2/file.lua
        local name = 'fugitive:///repo/.git//1:2/file.lua'
        vim.api.nvim_buf_set_name(0, name)
        local info = git.get_fugitive_info(0)
        assert.equals('diff', info.type)
        assert.equals('file.lua', info.file)
    end)
end)
