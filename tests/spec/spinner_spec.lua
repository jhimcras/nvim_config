describe('status spinner', function()
    local spinner, callback, starts, closes, redraws
    local new_timer, redraw
    before_each(function()
        new_timer, redraw = vim.uv.new_timer, vim.api.nvim__redraw
        starts, closes, redraws = 0, 0, {}
        vim.uv.new_timer = function()
            return {
                start = function(_, delay, interval, cb)
                    assert.equals(120, interval)
                    starts = starts + 1
                    callback = cb
                end,
                stop = function() end,
                close = function() closes = closes + 1 end,
            }
        end
        vim.api.nvim__redraw = function(opts) redraws[#redraws + 1] = opts.win end
        package.loaded['nvim_config.spinner'] = nil
        spinner = require('nvim_config.spinner')
    end)
    after_each(function()
        vim.uv.new_timer, vim.api.nvim__redraw = new_timer, redraw
        package.loaded['nvim_config.spinner'] = nil
        vim.cmd('only!')
    end)
    local function tick()
        callback()
        vim.wait(10)
    end
    it('shares one timer and redraws each visible target once', function()
        local win = vim.api.nvim_get_current_win()
        local buf = vim.api.nvim_get_current_buf()
        vim.cmd('vsplit')
        local other = vim.api.nvim_get_current_win()
        local a = spinner.start({ buf = buf })
        local b = spinner.start({ win = win })
        tick()
        assert.equals(1, starts)
        assert.same({ other, win }, redraws)
        spinner.stop(a)
        assert.equals(0, closes)
        spinner.stop(b)
        assert.equals(1, closes)
        redraws = {}
        tick()
        assert.same({}, redraws)
    end)
    it('skips hidden buffers and windows in another tab, then resumes', function()
        local buf = vim.api.nvim_get_current_buf()
        local win = vim.api.nvim_get_current_win()
        local a = spinner.start({ buf = buf })
        local b = spinner.start({ win = win })
        vim.cmd('tabnew')
        tick()
        assert.same({}, redraws)
        vim.cmd('tabclose!')
        tick()
        assert.same({win}, redraws)
        spinner.stop(a)
        spinner.stop(b)
    end)
    it('removes invalid targets and closes the last timer', function()
        local buf = vim.api.nvim_create_buf(false, true)
        spinner.start({ buf = buf })
        vim.api.nvim_buf_delete(buf, { force = true })
        tick()
        assert.same({}, redraws)
        assert.equals(1, closes)
    end)
end)
