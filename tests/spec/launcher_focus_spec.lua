local launcher = require('launcher')
local pr = require('prjroot')
local util = require('util')

describe('launcher focus option', function()
    local original_root, original_config, original_async, original_confirm
    local config, parent_win

    before_each(function()
        original_root = pr.GetCurrentProjectRoot
        original_config = pr.GetPrjrootConfig
        original_async = util.AsyncProcess
        original_confirm = vim.fn.confirm
        parent_win = vim.api.nvim_get_current_win()
        vim.cmd('only')
        vim.cmd('enew')
        parent_win = vim.api.nvim_get_current_win()
        config = { launchers = { build = { cmd = 'echo', args = { 'ok' } } } }
        pr.GetCurrentProjectRoot = function() return '/tmp' end
        pr.GetPrjrootConfig = function() return config end
        util.AsyncProcess = function()
            return 123, function() end, function() return 'running' end,
                { is_closing = function() return false end, kill = function() end }
        end
    end)

    after_each(function()
        pr.GetCurrentProjectRoot = original_root
        pr.GetPrjrootConfig = original_config
        util.AsyncProcess = original_async
        vim.fn.confirm = original_confirm
        for _, buf in ipairs(vim.api.nvim_list_bufs()) do
            local ok, obj = pcall(vim.api.nvim_buf_get_var, buf, 'lc_object')
            if ok and obj == 'build' then
                launcher.UnregisterProcess(buf)
                vim.api.nvim_buf_delete(buf, { force = true })
            end
        end
        vim.cmd('only')
    end)

    it('focuses a new output buffer only when enabled', function()
        config.launchers.build.focus = false
        local buf = launcher.LaunchObject('build')
        assert.are.equal(parent_win, vim.api.nvim_get_current_win())
        assert.is_true(#vim.fn.win_findbuf(buf) > 0)

        config.launchers.build.focus = true
        vim.fn.confirm = function() return 1 end
        launcher.LaunchObject('build')
        assert.are.equal(buf, vim.api.nvim_get_current_buf())
    end)

    it('preserves the caller window when reusing visible output', function()
        config.launchers.build.focus = false
        local buf = launcher.LaunchObject('build')
        vim.fn.confirm = function() return 1 end
        launcher.LaunchObject('build')
        assert.are.equal(parent_win, vim.api.nvim_get_current_win())
        assert.is_true(#vim.fn.win_findbuf(buf) > 0)
    end)

    it('honors focus when replacement is cancelled', function()
        config.launchers.build.focus = false
        local buf = launcher.LaunchObject('build')
        vim.fn.confirm = function() return 2 end
        launcher.LaunchObject('build')
        assert.are.equal(parent_win, vim.api.nvim_get_current_win())

        config.launchers.build.focus = true
        launcher.LaunchObject('build')
        assert.are.equal(buf, vim.api.nvim_get_current_buf())
    end)

    it('preserves the caller window when showing hidden output again', function()
        config.launchers.build.focus = false
        local buf = launcher.LaunchObject('build')
        vim.api.nvim_win_close(vim.fn.win_findbuf(buf)[1], true)
        vim.fn.confirm = function() return 1 end

        launcher.LaunchObject('build')
        assert.are.equal(parent_win, vim.api.nvim_get_current_win())
        assert.is_true(#vim.fn.win_findbuf(buf) > 0)
    end)

    it('preserves the caller window in terminal mode', function()
        config.launchers.build.mode = 'terminal'
        config.launchers.build.cmd = 'sh'
        config.launchers.build.args = { '-c', 'sleep 10' }
        config.launchers.build.focus = false

        local buf = launcher.LaunchObject('build')
        assert.are.equal(parent_win, vim.api.nvim_get_current_win())
        assert.is_true(#vim.fn.win_findbuf(buf) > 0)
        vim.fn.jobstop(launcher.running_processes[buf].job_id)
    end)
end)
