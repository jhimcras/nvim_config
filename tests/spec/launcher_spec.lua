local launcher = require('launcher')

describe('launcher', function()
    it('should have a setup function', function()
        assert.is_function(launcher.setup)
    end)
    
    it('should call api.nvim_create_autocmd on setup', function()
        local original_create_autocmd = vim.api.nvim_create_autocmd
        local created = false
        vim.api.nvim_create_autocmd = function(events, opts)
            if events[1] == 'BufRead' then
                created = true
            end
            return 1
        end
        
        launcher.setup()
        assert.is_true(created)
        
        vim.api.nvim_create_autocmd = original_create_autocmd
    end)

    it('should set launcher buffer to be non-modifiable in M.Launch', function()
        local mock_buf = vim.api.nvim_create_buf(false, true)
        local original_new_scratch = require('util').NewScratchBuffer
        require('util').NewScratchBuffer = function() return mock_buf end
        
        -- Mock AsyncProcess to avoid actual process creation
        local original_async = require('util').AsyncProcess
        require('util').AsyncProcess = function() return 123, function() end, function() return "running" end, {} end
        
        launcher.Launch('ls', {}, '.', nil, nil, nil, 'use', nil, nil, 'test')
        
        local modifiable = vim.api.nvim_get_option_value('modifiable', { buf = mock_buf })
        assert.is_false(modifiable)
        
        require('util').NewScratchBuffer = original_new_scratch
        require('util').AsyncProcess = original_async
    end)
end)

describe('launcher.Jump filename resolution', function()
    local function make_launcher_buf(vars)
        local win = vim.api.nvim_get_current_win()
        local buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_win_set_buf(win, buf)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'dummy output line' })
        vim.api.nvim_buf_set_var(buf, 'lc_parent_win', win)
        for k, v in pairs(vars) do
            vim.api.nvim_buf_set_var(buf, k, v)
        end
        vim.api.nvim_win_set_cursor(win, { 1, 0 })
        return buf
    end

    it('resolves a backslash relative filename via match.base_dir', function()
        local root = vim.fn.tempname()
        vim.fn.mkdir(root .. '/src/base/log', 'p')
        local target = root .. '/src/base/log/LauncherTestFixtureA.cpp'
        vim.fn.writefile({ 'content' }, target)

        make_launcher_buf({
            prjroot_folder = root,
            launcher_matches = {
                {
                    lnum = 1,
                    filename = '..\\..\\src\\base\\log\\LauncherTestFixtureA.cpp',
                    row = '495',
                    base_dir = root .. '/build/vs12',
                },
            },
        })

        launcher.Jump()

        assert.are.equal(vim.fn.fnamemodify(target, ':p'), vim.api.nvim_buf_get_name(0))
        vim.fn.delete(root, 'rf')
    end)

    it('falls back to prjroot-relative resolution when base_dir is absent', function()
        local root = vim.fn.tempname()
        vim.fn.mkdir(root .. '/src', 'p')
        local target = root .. '/src/LauncherTestFixtureB.cpp'
        vim.fn.writefile({ 'content' }, target)

        make_launcher_buf({
            prjroot_folder = root,
            launcher_matches = {
                { lnum = 1, filename = 'src\\LauncherTestFixtureB.cpp', row = '10' },
            },
        })

        launcher.Jump()

        assert.are.equal(vim.fn.fnamemodify(target, ':p'), vim.api.nvim_buf_get_name(0))
        vim.fn.delete(root, 'rf')
    end)

    it('resolves via on-disk search when exactly one candidate is found', function()
        local original_executable = vim.fn.executable
        local original_systemlist = vim.fn.systemlist
        vim.fn.executable = function(name)
            if name == 'rg' then return 1 end
            return original_executable(name)
        end
        vim.fn.systemlist = function() return { '/tmp/launcher-test-found/LauncherTestFixtureC.cpp' } end

        make_launcher_buf({
            prjroot_folder = '/tmp/launcher-test-does-not-exist-root',
            launcher_matches = {
                { lnum = 1, filename = '..\\..\\wrong\\path\\LauncherTestFixtureC.cpp', row = '1' },
            },
        })

        launcher.Jump()

        assert.are.equal(
            vim.fn.fnamemodify('/tmp/launcher-test-found/LauncherTestFixtureC.cpp', ':p'),
            vim.api.nvim_buf_get_name(0)
        )

        vim.fn.executable = original_executable
        vim.fn.systemlist = original_systemlist
    end)

    it('opens a quickfix list when multiple candidates are found', function()
        local original_executable = vim.fn.executable
        local original_systemlist = vim.fn.systemlist
        vim.fn.executable = function(name)
            if name == 'rg' then return 1 end
            return original_executable(name)
        end
        vim.fn.systemlist = function()
            return {
                '/tmp/launcher-test-found/a/LauncherTestFixtureD.cpp',
                '/tmp/launcher-test-found/b/LauncherTestFixtureD.cpp',
            }
        end

        make_launcher_buf({
            prjroot_folder = '/tmp/launcher-test-does-not-exist-root',
            launcher_matches = {
                { lnum = 1, filename = '..\\..\\wrong\\path\\LauncherTestFixtureD.cpp', row = '1' },
            },
        })

        launcher.Jump()

        local qf = vim.fn.getqflist()
        local qf_title = vim.fn.getqflist({ title = 1 }).title
        assert.are.equal(2, #qf)
        assert.is_not_nil(qf_title:find('LauncherTestFixtureD.cpp', 1, true))
        -- copen focused the quickfix window; no :edit of a resolved file happened.
        assert.are.equal('quickfix', vim.bo.buftype)
        vim.cmd('cclose')

        vim.fn.executable = original_executable
        vim.fn.systemlist = original_systemlist
    end)

    it('notifies and does not open a buffer when no candidates are found', function()
        local original_executable = vim.fn.executable
        local original_systemlist = vim.fn.systemlist
        vim.fn.executable = function(name)
            if name == 'rg' then return 1 end
            return original_executable(name)
        end
        vim.fn.systemlist = function() return {} end

        local original_notify = vim.notify
        local notified_msg, notified_level
        vim.notify = function(msg, level) notified_msg, notified_level = msg, level end

        local buf = make_launcher_buf({
            prjroot_folder = '/tmp/launcher-test-does-not-exist-root',
            launcher_matches = {
                { lnum = 1, filename = '..\\..\\wrong\\path\\LauncherTestFixtureE.cpp', row = '1' },
            },
        })

        launcher.Jump()

        assert.is_not_nil(notified_msg)
        assert.is_not_nil(notified_msg:find('LauncherTestFixtureE.cpp', 1, true))
        assert.are.equal(vim.log.levels.WARN, notified_level)
        assert.are.equal(buf, vim.api.nvim_get_current_buf())

        vim.fn.executable = original_executable
        vim.fn.systemlist = original_systemlist
        vim.notify = original_notify
    end)
end)
