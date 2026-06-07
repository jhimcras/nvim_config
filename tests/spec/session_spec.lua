local session = require('session')
local original_stdpath = vim.fn.stdpath
local test_data_dir = vim.fn.tempname()
vim.fn.mkdir(test_data_dir, 'p')
vim.fn.stdpath = function(what)
    if what == 'data' then
        return test_data_dir
    end
    return original_stdpath(what)
end

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

describe('session.SaveSession', function()
    it('saves a session and updates tabline without error', function()
        local session_name = '__test__new_session'
        local sessions_dir = vim.fn.stdpath('data') .. '/sessions'
        vim.fn.mkdir(sessions_dir, 'p')
        local session_path = sessions_dir .. '/' .. session_name

        -- Mock vim.cmd and vim.notify to avoid side effects
        local original_cmd = vim.cmd
        local original_notify = vim.notify
        local original_go = vim.go
        vim.cmd = function() end
        vim.notify = function() end
        vim.go = { tabline = '' }

        -- Ensure tabline module is loaded and has TabLine function
        package.loaded['tabline'] = package.loaded['tabline'] or {
            TabLine = function() return 'mock_tabline' end
        }

        local status, err = pcall(session.SaveSession, session_name)
        
        -- Restore originals
        vim.cmd = original_cmd
        vim.notify = original_notify
        vim.go = original_go

        if not status then
            error('SaveSession failed: ' .. tostring(err))
        end
        
        assert.is_true(status)
    end)
end)

describe('session QuitPre exit guard', function()
    local original_confirm
    local original_get_running_processes
    local original_cmd
    local confirm_msg
    local confirm_choices
    local confirm_default
    local confirm_result

    local function cleanup_buffers()
        for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
            if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr) then
                pcall(function()
                    vim.bo[bufnr].modified = false
                end)
            end
        end
        for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
            if vim.api.nvim_buf_is_valid(bufnr) and bufnr ~= vim.api.nvim_get_current_buf() then
                pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
            end
        end
    end

    local function setup_exit_guard()
        pcall(vim.api.nvim_del_user_command, 'SaveSession')
        pcall(vim.api.nvim_del_user_command, 'RemoveSession')
        pcall(vim.api.nvim_del_user_command, 'CloseSession')
        pcall(vim.api.nvim_del_user_command, 'SessionQuitAll')
        session.setup()

        for _, au in ipairs(vim.api.nvim_get_autocmds({ event = 'QuitPre', group = 'ExitGuard' })) do
            if au.callback then
                return au.callback
            end
        end
        error('ExitGuard QuitPre callback not found')
    end

    local function make_modified_unnamed_buffer()
        local bufnr = vim.api.nvim_create_buf(true, false)
        vim.api.nvim_set_current_buf(bufnr)
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'draft' })
        vim.bo[bufnr].modified = true
        return bufnr
    end

    before_each(function()
        cleanup_buffers()
        confirm_msg = nil
        confirm_choices = nil
        confirm_default = nil
        confirm_result = 1
        original_confirm = vim.fn.confirm
        original_get_running_processes = session.get_running_processes
        original_cmd = vim.cmd
        vim.fn.confirm = function(msg, choices, default)
            confirm_msg = msg
            confirm_choices = choices
            confirm_default = default
            return confirm_result
        end
        session.get_running_processes = function()
            return {}
        end
        vim.cmd = function(cmd)
            if cmd ~= 'redraw' then
                original_cmd(cmd)
            end
        end
    end)

    after_each(function()
        vim.fn.confirm = original_confirm
        session.get_running_processes = original_get_running_processes
        vim.cmd = original_cmd
        cleanup_buffers()
    end)

    it('clears a modified unnamed buffer when Ignore is selected for :qa', function()
        local callback = setup_exit_guard()
        local bufnr = make_modified_unnamed_buffer()

        callback()

        assert.is_false(vim.bo[bufnr].modified)
        assert.truthy(confirm_msg:find('Global Unsaved buffers:\n  %[No Name%]', 1))
        assert.truthy(confirm_msg:find('Ignore and Continue?', 1, true))
        assert.same('&Ignore\n&Cancel', confirm_choices)
        assert.same(2, confirm_default)
    end)

    it('preserves a modified unnamed buffer after Cancel and guards the next quit attempt', function()
        local callback = setup_exit_guard()
        local bufnr = make_modified_unnamed_buffer()

        confirm_result = 2
        local ok = pcall(callback)

        assert.is_true(ok)
        assert.is_true(vim.bo[bufnr].modified)
        assert.same('&Ignore\n&Cancel', confirm_choices)

        confirm_result = 1
        callback()

        assert.is_false(vim.bo[bufnr].modified)
    end)

    it('SessionQuitAll returns cleanly on Cancel and preserves changes', function()
        setup_exit_guard()
        local bufnr = make_modified_unnamed_buffer()

        confirm_result = 2
        local ok = pcall(vim.cmd, 'SessionQuitAll')

        assert.is_true(ok)
        assert.is_true(vim.bo[bufnr].modified)
        assert.same('&Ignore\n&Cancel', confirm_choices)
    end)

    it('uses stop-oriented confirmation and terminates running processes', function()
        local terminated = false
        session.get_running_processes = function()
            return {
                {
                    obj = 'Build',
                    terminate = function(signal)
                        terminated = signal == 15
                    end,
                },
            }
        end
        local callback = setup_exit_guard()

        callback()

        assert.is_true(terminated)
        assert.truthy(confirm_msg:find('Other running processes:\n  Build', 1, true))
        assert.truthy(confirm_msg:find('Stop and Continue?', 1, true))
        assert.same('&Stop and Continue\n&Cancel', confirm_choices)
        assert.same(2, confirm_default)
    end)

    it('uses combined wording for running processes and unsaved buffers', function()
        session.get_running_processes = function()
            return {
                {
                    obj = 'Build',
                    terminate = function() end,
                },
            }
        end
        local callback = setup_exit_guard()
        local bufnr = make_modified_unnamed_buffer()

        callback()

        assert.is_false(vim.bo[bufnr].modified)
        assert.truthy(confirm_msg:find('Other running processes:\n  Build', 1, true))
        assert.truthy(confirm_msg:find('Global Unsaved buffers:\n  %[No Name%]', 1))
        assert.truthy(confirm_msg:find('Stop processes, ignore unsaved changes, and continue?', 1, true))
        assert.same('&Stop and Ignore\n&Cancel', confirm_choices)
        assert.same(2, confirm_default)
    end)
end)
