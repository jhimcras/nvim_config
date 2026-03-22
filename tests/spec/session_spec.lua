local session = require('session')

local function make_sessions_dir()
    local dir = vim.fn.stdpath('data') .. '/sessions'
    vim.fn.mkdir(dir, 'p')
    return dir
end

describe('session.SessionList', function()
    local sessions_dir
    local test_files

    before_each(function()
        sessions_dir = make_sessions_dir()
        test_files = {}
    end)

    after_each(function()
        for _, f in ipairs(test_files) do
            vim.fn.delete(f)
        end
    end)

    local function touch(name)
        local path = sessions_dir .. '/' .. name
        local f = assert(io.open(path, 'w'))
        f:close()
        table.insert(test_files, path)
    end

    -- Collect only test-owned names from a SessionList result
    local function owned(list)
        local names = {}
        for _, n in ipairs(list) do
            if n:match('^__test__') then
                table.insert(names, n)
            end
        end
        table.sort(names)
        return names
    end

    it('excludes .qf.lua auxiliary files', function()
        touch('__test__session')
        touch('__test__session.qf.lua')

        assert.same({'__test__session'}, owned(session.SessionList('')))
    end)

    it('excludes .loc.*.lua auxiliary files', function()
        touch('__test__session')
        touch('__test__session.loc.99999.lua')

        assert.same({'__test__session'}, owned(session.SessionList('')))
    end)

    it('excludes plain .lua files', function()
        touch('__test__session')
        touch('__test__config.lua')

        assert.same({'__test__session'}, owned(session.SessionList('')))
    end)

    it('returns multiple session files when arglead is empty', function()
        touch('__test__alpha')
        touch('__test__beta')
        touch('__test__alpha.qf.lua')

        assert.same({'__test__alpha', '__test__beta'}, owned(session.SessionList('')))
    end)

    it('filters by prefix: only names starting with arglead are returned', function()
        touch('__test__foo')
        touch('__test__foobar')
        touch('__test__baz')

        assert.same({'__test__foo', '__test__foobar'}, owned(session.SessionList('__test__foo')))
    end)

    it('prefix that matches nothing returns empty', function()
        touch('__test__something')

        assert.same({}, owned(session.SessionList('__test__nothing_matches_xyz')))
    end)

    it('nil arglead behaves like empty string', function()
        touch('__test__x')

        local names = owned(session.SessionList(nil))
        assert.truthy(vim.tbl_contains(names, '__test__x'))
    end)
end)
