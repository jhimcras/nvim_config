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
