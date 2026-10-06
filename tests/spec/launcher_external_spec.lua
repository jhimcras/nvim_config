local launcher = require('launcher')
local pr = require('prjroot')
local util = require('util')
local env = require('env')

describe('external launcher spawn', function()
    local original_root, original_config, original_executable, original_notify, original_win
    local notifications

    before_each(function()
        original_root = pr.GetCurrentProjectRoot
        original_config = pr.GetPrjrootConfig
        original_executable = vim.fn.executable
        original_notify = vim.notify
        original_win = env.os.win
        env.os.win = false
        pr.GetCurrentProjectRoot = function() return vim.fn.getcwd() end
        pr.GetPrjrootConfig = function()
            return { launchers = { external_test = { cmd = 'echo', mode = 'external' } } }
        end
        notifications = {}
        vim.notify = function(msg) table.insert(notifications, msg) end
    end)

    after_each(function()
        for _, p in ipairs(launcher.GetRunningProcesses()) do
            if p.obj == 'external_test' then
                vim.api.nvim_buf_delete(p.buf, { force = true })
            end
        end
        pr.GetCurrentProjectRoot = original_root
        pr.GetPrjrootConfig = original_config
        vim.fn.executable = original_executable
        vim.notify = original_notify
        env.os.win = original_win
    end)

    it('reports ENOENT and removes the guard buffer when spawn fails', function()
        -- Claim a terminal exists, then let the real spawn fail with a missing cwd.
        vim.fn.executable = function() return 1 end
        pr.GetPrjrootConfig = function()
            return { launchers = { external_test = {
                cmd = 'echo', mode = 'external', cwd = '/nonexistent-launcher-test-cwd'
            } } }
        end
        local original_exists = util.IsExist
        util.IsExist = function() return true end
        local ok, err = pcall(launcher.LaunchObject, 'external_test')
        util.IsExist = original_exists
        assert.is_true(ok, err)
        for _, p in ipairs(launcher.GetRunningProcesses()) do
            assert.is_not.equal('external_test', p.obj)
        end
        for _, buf in ipairs(vim.api.nvim_list_bufs()) do
            assert.is_not.equal('[External Process: external_test]', vim.api.nvim_buf_get_name(buf))
        end
        assert.truthy(notifications[1]:find('ENOENT', 1, true))
    end)

    it('registers a numeric PID and displays it in ProcessList', function()
        -- Use sh as the selected terminal so this runs without a desktop session.
        vim.fn.executable = function() return 1 end
        local original_async = util.AsyncProcess
        util.AsyncProcess = function(_, _, cwd, opts)
            return original_async('sh', { '-c', 'sleep 30' }, cwd, opts)
        end
        local ok, err = pcall(launcher.LaunchObject, 'external_test')
        util.AsyncProcess = original_async
        assert.is_true(ok, err)
        local proc
        for _, p in ipairs(launcher.GetRunningProcesses()) do
            if p.obj == 'external_test' then proc = p end
        end
        assert.is_number(proc.pid)
        local list = require('process_list')
        list.Show()
        local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
        assert.truthy(table.concat(lines, '\n'):find(tostring(proc.pid), 1, true))
        vim.api.nvim_buf_delete(0, { force = true })
    end)
end)
