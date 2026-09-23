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

describe('launcher.Restore', function()
    it('marks a saved running process as terminated', function()
        local buf = launcher.Restore({ obj = 'build', cmd = 'make', status = 'running', content = { 'output' } })

        assert.are.equal('terminated', vim.b[buf].launcher_status)
        assert.are.same({ 'output' }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
        assert.is_nil(launcher.running_processes[buf])

        vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it('preserves a saved completed status', function()
        local buf = launcher.Restore({ obj = 'build', cmd = 'make', status = 'done' })

        assert.are.equal('done', vim.b[buf].launcher_status)

        vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it('restores when another buffer already has its expected name', function()
        local existing = vim.api.nvim_create_buf(false, true)
        local expected_buf = vim.fn.bufnr('$') + 1
        local expected_name = string.format('(%d) build', expected_buf)
        vim.api.nvim_buf_set_name(existing, expected_name)

        local restored = launcher.Restore({ obj = 'build', cmd = 'make', status = 'running' })

        assert.are.equal(expected_buf, restored)
        assert.are.equal(vim.fn.fnamemodify(expected_name, ':p'), vim.api.nvim_buf_get_name(existing))
        assert.are.equal(vim.fn.fnamemodify(expected_name .. ' [restored]', ':p'), vim.api.nvim_buf_get_name(restored))
        assert.are.equal('terminated', vim.b[restored].launcher_status)

        vim.api.nvim_buf_delete(restored, { force = true })
        vim.api.nvim_buf_delete(existing, { force = true })
    end)
end)

describe('launcher.CloseLauncherBuffer', function()
    local util = require('util')
    local original_async, original_confirm
    local buf, killed

    before_each(function()
        original_async = util.AsyncProcess
        original_confirm = vim.fn.confirm
        killed = false
        util.AsyncProcess = function()
            return 123, function() killed = true end, function() return 'running' end,
                { is_closing = function() return false end, kill = function() killed = true end }
        end
        buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_win_set_buf(0, buf)
        launcher.Launch('sleep', { '100' }, '.', nil, nil, nil, 'use', buf)
    end)

    after_each(function()
        util.AsyncProcess = original_async
        vim.fn.confirm = original_confirm
        if vim.api.nvim_buf_is_valid(buf) then
            launcher.UnregisterProcess(buf)
            vim.api.nvim_buf_delete(buf, { force = true })
        end
    end)

    it('stops the process and deletes the buffer on Stop', function()
        vim.fn.confirm = function(_, choices, default)
            assert.are.equal('&Stop\n&Cancel', choices)
            assert.are.equal(2, default)
            return 1
        end

        launcher.CloseLauncherBuffer()

        assert.is_false(vim.api.nvim_buf_is_valid(buf))
        assert.is_true(killed)
        assert.is_nil(launcher.running_processes[buf])
    end)

    it('leaves the running buffer untouched on Cancel', function()
        vim.fn.confirm = function() return 2 end

        launcher.CloseLauncherBuffer()

        assert.is_true(vim.api.nvim_buf_is_valid(buf))
        assert.is_false(killed)
        assert.is_not_nil(launcher.running_processes[buf])
    end)

    it('asks before :bwipeout! deletes a running buffer', function()
        local prompted = false
        vim.fn.confirm = function()
            prompted = true
            return 2
        end

        vim.cmd.LauncherBwipeout { bang = true }

        assert.is_true(prompted)
        assert.is_true(vim.api.nvim_buf_is_valid(buf))
        assert.is_false(killed)
    end)

    it('asks before deleting a hidden launcher buffer by number', function()
        local filler = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_win_set_buf(0, filler)
        local prompted = false
        vim.fn.confirm = function()
            prompted = true
            return 2
        end

        vim.cmd.LauncherBwipeout { args = { tostring(buf) } }

        assert.is_true(prompted)
        assert.is_true(vim.api.nvim_buf_is_valid(buf))
        assert.is_false(killed)
        vim.api.nvim_buf_delete(filler, { force = true })
    end)

    it('asks before a typed :bwipe command deletes a running buffer', function()
        local prompted = false
        vim.fn.confirm = function()
            prompted = true
            return 2
        end

        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(':bwipe<CR>', true, false, true), 'xt', false)

        assert.is_true(prompted)
        assert.is_true(vim.api.nvim_buf_is_valid(buf))
        assert.is_false(killed)
    end)

    it('keeps the buffer and process when its window closes, and can reopen it', function()
        local filler = vim.api.nvim_create_buf(false, true)
        local confirms = 0
        vim.fn.confirm = function() confirms = confirms + 1; return 2 end
        vim.bo[buf].modifiable = true
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'launcher output' })
        vim.bo[buf].modifiable = false
        vim.cmd.vsplit()
        vim.api.nvim_win_set_buf(0, filler)
        vim.cmd('wincmd p')
        local windows_before = #vim.api.nvim_list_wins()

        vim.cmd.quit()

        assert.are.equal(windows_before - 1, #vim.api.nvim_list_wins())
        assert.are.equal(0, confirms)
        assert.is_true(vim.api.nvim_buf_is_valid(buf))
        assert.is_false(killed)
        assert.is_not_nil(launcher.running_processes[buf])
        assert.are.equal(0, #vim.fn.win_findbuf(buf))
        vim.api.nvim_win_set_buf(0, buf)
        assert.are.same({ 'launcher output' }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
        vim.api.nvim_buf_delete(filler, { force = true })
    end)
end)

describe('launcher terminal window close', function()
    it('keeps the job and buffer when its window closes', function()
        if vim.fn.has('win32') == 1 then return end

        local original_confirm = vim.fn.confirm
        local confirms = 0
        vim.fn.confirm = function() confirms = confirms + 1; return 2 end
        local buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_win_set_buf(0, buf)
        launcher.LaunchOnTerm('sh', { '-c', 'sleep 10' }, '.', nil, nil, nil, buf)
        local job_id = launcher.running_processes[buf].job_id
        local filler = vim.api.nvim_create_buf(false, true)
        vim.cmd.vsplit()
        vim.api.nvim_win_set_buf(0, filler)
        vim.cmd('wincmd p')
        local windows_before = #vim.api.nvim_list_wins()

        vim.cmd.quit()

        vim.fn.confirm = original_confirm
        assert.are.equal(windows_before - 1, #vim.api.nvim_list_wins())
        assert.are.equal(0, confirms)
        assert.is_true(vim.api.nvim_buf_is_valid(buf))
        assert.are.equal(0, #vim.fn.win_findbuf(buf))
        assert.are.equal(-1, vim.fn.jobwait({ job_id }, 0)[1])
        vim.api.nvim_win_set_buf(0, buf)

        vim.fn.jobstop(job_id)
        assert.is_true(vim.wait(2000, function() return launcher.running_processes[buf] == nil end))
        assert.is_true(vim.api.nvim_buf_is_valid(buf))
        vim.api.nvim_buf_delete(buf, { force = true })
        vim.api.nvim_buf_delete(filler, { force = true })
        assert.is_nil(launcher.running_processes[buf])
    end)
end)

describe('launcher.WipeLauncherBuffers', function()
    it('asks before deleting a running buffer from the current prjroot', function()
        local root_a = vim.fn.tempname()
        local root_b = vim.fn.tempname()

        local matching_buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_var(matching_buf, 'prjroot_folder', root_a)

        local running_buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_var(running_buf, 'prjroot_folder', root_a)
        local terminated = false
        require('launcher').RegisterProcess(running_buf, {
            type = 'general',
            terminate = function() terminated = true end,
        })

        local other_prjroot_buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_var(other_prjroot_buf, 'prjroot_folder', root_b)

        -- The current buffer must not itself carry prjroot_folder = root_a, or
        -- WipeLauncherBuffers would wipe it out from under the test.
        local original_get_root = require('prjroot').GetCurrentProjectRoot
        local original_confirm = vim.fn.confirm
        require('prjroot').GetCurrentProjectRoot = function() return root_a end
        vim.fn.confirm = function(_, choices, default)
            assert.are.equal('&Stop\n&Cancel', choices)
            assert.are.equal(2, default)
            return 1
        end

        launcher.WipeLauncherBuffers()

        require('prjroot').GetCurrentProjectRoot = original_get_root
        vim.fn.confirm = original_confirm

        assert.is_false(vim.api.nvim_buf_is_valid(matching_buf))
        assert.is_false(vim.api.nvim_buf_is_valid(running_buf))
        assert.is_true(terminated)
        assert.is_true(vim.api.nvim_buf_is_valid(other_prjroot_buf))

        vim.api.nvim_buf_delete(other_prjroot_buf, { force = true })
    end)
end)

describe('launcher.Jump filename resolution', function()
    after_each(function()
        -- Jump may open a split (vsplit fallback / copen); keep tests isolated.
        vim.cmd('silent! only')
    end)

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

    it('never opens the resolved file into the window still showing the launcher buffer', function()
        local root = vim.fn.tempname()
        vim.fn.mkdir(root .. '/src', 'p')
        local target = root .. '/src/LauncherTestFixtureF.cpp'
        vim.fn.writefile({ 'content' }, target)

        -- A second window exists (e.g. the user's original source window);
        -- lc_parent_win nonetheless points back at the launcher's own window,
        -- as happens when the launch key is pressed again from inside the
        -- output buffer itself (BufMapping's keymap is global, not buffer-local).
        vim.cmd('vsplit')
        local other_win = vim.api.nvim_get_current_win()
        vim.cmd('wincmd p')
        local launcher_win = vim.api.nvim_get_current_win()

        local launcher_buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_win_set_buf(launcher_win, launcher_buf)
        vim.api.nvim_buf_set_lines(launcher_buf, 0, -1, false, { 'dummy output line' })
        vim.api.nvim_buf_set_var(launcher_buf, 'lc_parent_win', launcher_win)
        vim.api.nvim_buf_set_var(launcher_buf, 'prjroot_folder', root)
        vim.api.nvim_buf_set_var(launcher_buf, 'launcher_matches', {
            { lnum = 1, filename = 'src\\LauncherTestFixtureF.cpp', row = '1' },
        })
        vim.api.nvim_win_set_cursor(launcher_win, { 1, 0 })

        launcher.Jump()

        assert.are.equal(launcher_buf, vim.api.nvim_win_get_buf(launcher_win))
        assert.are.equal(vim.fn.fnamemodify(target, ':p'), vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(other_win)))

        vim.fn.delete(root, 'rf')
    end)
end)
