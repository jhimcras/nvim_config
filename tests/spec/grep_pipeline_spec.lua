local grep = require('nvim_config.grep')
local job = require('nvim_config.util.job')
local prjroot = require('nvim_config.prjroot')
local registry = require('nvim_config.launcher.registry')

describe('grep staged process callbacks', function()
    local original_async, original_root, callbacks, origin, locwin, terminated
    local path, arguments, project

    local function drain()
        local done = false
        vim.schedule(function() done = true end)
        assert.is_true(vim.wait(1000, function() return done end))
    end

    before_each(function()
        origin = vim.api.nvim_get_current_win()
        path = vim.fn.tempname() .. '.txt'
        original_async, original_root = job.AsyncProcess, prjroot.GetCurrentProjectRoot
        job.AsyncProcess = function(_, args, _, opts)
            callbacks, arguments = opts, args
            return 123, function(signal) terminated = signal end, function() return 'running' end
        end
        project = vim.fn.getcwd() .. '/different project'
        prjroot.GetCurrentProjectRoot = function() return project end
        terminated = nil
        grep.asyncGrep('needle', false, origin)
        locwin = vim.api.nvim_get_current_win()
    end)

    after_each(function()
        callbacks.onexit(0, 0)
        job.AsyncProcess, prjroot.GetCurrentProjectRoot = original_async, original_root
        vim.cmd('lclose')
        local buf = vim.fn.bufnr(path)
        if buf > 0 then vim.api.nvim_buf_delete(buf, { force = true }) end
        vim.fn.setloclist(origin, {}, 'f')
    end)

    it('joins partial chunks and appends parsed results before successful completion', function()
        assert.equals(project, arguments[#arguments])
        callbacks.onread(nil, path .. ':1:2:first')
        callbacks.onread(nil, ' match\n' .. path .. ':2:3:second match\n')
        drain()
        local items = vim.fn.getloclist(origin)
        assert.equals(2, #items)
        assert.same({ 'first match', 'second match' }, { items[1].text, items[2].text })
        assert.same({ 2, 3 }, { items[1].col, items[2].col })
        callbacks.onexit(0, 0)
        assert.equals('done', vim.w[locwin].grep_status)
        assert.same({}, registry.list())
    end)

    it('drops queued reads after cancellation and preserves killed status', function()
        callbacks.onread(nil, path .. ':1:2:queued match\n')
        local feedkeys = vim.api.nvim_feedkeys
        vim.api.nvim_feedkeys = function() end
        local mapping = vim.fn.maparg('<C-c>', 'n', false, true)
        mapping.callback()
        vim.api.nvim_feedkeys = feedkeys
        drain()
        assert.equals('sigkill', terminated)
        assert.same({}, vim.fn.getloclist(origin))
        callbacks.onexit(0, 9)
        assert.equals('killed', vim.w[locwin].grep_status)
        assert.same({}, registry.list())
    end)
end)
