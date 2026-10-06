local process_list = require('nvim_config.process_list')
local launcher = require('nvim_config.launcher')

describe('process_list.lua selection and window ownership', function()
    local original_list, original_notify, buf, job_buf, origin

    before_each(function()
        original_list, original_notify = launcher.GetRunningProcesses, vim.notify
        vim.notify = function() end
        job_buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_win_set_buf(0, job_buf)
        origin = vim.api.nvim_get_current_win()
        launcher.GetRunningProcesses = function()
            return { { type = 'general', obj = 'build', pid = 42, buf = job_buf, key = job_buf } }
        end
        process_list.Show()
        buf = vim.api.nvim_get_current_buf()
    end)

    after_each(function()
        process_list.StopRefresh()
        launcher.GetRunningProcesses, vim.notify = original_list, original_notify
        if vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_delete(buf, { force = true }) end
        if vim.api.nvim_buf_is_valid(job_buf) then vim.api.nvim_buf_delete(job_buf, { force = true }) end
    end)

    it('renders process metadata in a read-only buffer and reuses its visible window', function()
        local win = vim.api.nvim_get_current_win()
        local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        assert.are.equal(3, #lines)
        assert.truthy(lines[3]:find('build', 1, true))
        assert.truthy(lines[3]:find('42', 1, true))
        assert.is_false(vim.bo[buf].modifiable)
        vim.api.nvim_set_current_win(origin)
        process_list.Show()
        assert.are.equal(win, vim.api.nvim_get_current_win())
        assert.are.equal(2, #vim.api.nvim_tabpage_list_wins(0))
    end)

    it('ignores header selection and sends SIGTERM to the selected row only', function()
        local signals = {}
        launcher.GetRunningProcesses = function()
            return { { type = 'general', obj = 'build',
                terminate = function(signal) signals[#signals + 1] = signal end } }
        end
        process_list.Update()
        vim.api.nvim_win_set_cursor(0, { 1, 0 })
        process_list.TerminateSelected()
        assert.are.same({}, signals)
        vim.api.nvim_win_set_cursor(0, { 3, 0 })
        process_list.TerminateSelected()
        assert.are.same({ 15 }, signals)
    end)

    it('jumps to an existing job window instead of opening another split', function()
        vim.api.nvim_win_set_cursor(0, { 3, 0 })
        process_list.JumpToProcess()
        assert.are.equal(origin, vim.api.nvim_get_current_win())
        assert.are.equal(job_buf, vim.api.nvim_get_current_buf())
        assert.are.equal(2, #vim.api.nvim_tabpage_list_wins(0))
    end)

    it('opens a hidden job buffer in a new split', function()
        local hidden = vim.api.nvim_create_buf(false, true)
        launcher.GetRunningProcesses = function() return { { type = 'general', key = hidden } } end
        process_list.Update()
        vim.api.nvim_win_set_cursor(0, { 3, 0 })
        process_list.JumpToProcess()
        assert.are.equal(hidden, vim.api.nvim_get_current_buf())
        assert.are.equal(3, #vim.api.nvim_tabpage_list_wins(0))
        vim.api.nvim_buf_delete(hidden, { force = true })
    end)
end)
