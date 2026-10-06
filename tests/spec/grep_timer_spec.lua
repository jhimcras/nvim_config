describe('grep timer lifecycle', function()
    local saved, new_timer, grep, onexit, starts, closes
    before_each(function()
        saved = {}
        for _, name in ipairs({ 'nvim_config.util.job', 'nvim_config.util.map', 'nvim_config.env', 'nvim_config.prjroot', 'nvim_config.launcher.registry' }) do
            saved[name] = package.loaded[name]
        end
        package.loaded['nvim_config.util.job'] = {
            AsyncProcess = function(_, _, _, opts)
                onexit = opts.onexit
                return 1, function() end, function() return 'running' end
            end,
        }
        package.loaded['nvim_config.util.map'] = { nnoremap = function() end }
        package.loaded['nvim_config.env'] = {}
        package.loaded['nvim_config.prjroot'] = { GetCurrentProjectRoot = function() return vim.fn.getcwd() end }
        package.loaded['nvim_config.launcher.registry'] = {
            list = function() return {} end,
            register = function() end,
            unregister = function() end,
        }
        starts, closes = 0, 0
        new_timer = vim.uv.new_timer
        vim.uv.new_timer = function()
            return {
                start = function() starts = starts + 1 end,
                stop = function() end,
                close = function() closes = closes + 1 end,
            }
        end
        grep = dofile('lua/nvim_config/grep.lua')
        grep.asyncGrep('needle', false, vim.api.nvim_get_current_win())
    end)
    after_each(function()
        onexit(0, 0)
        vim.cmd('lclose')
        vim.uv.new_timer = new_timer
        for _, name in ipairs({ 'nvim_config.util.job', 'nvim_config.util.map', 'nvim_config.env', 'nvim_config.prjroot', 'nvim_config.launcher.registry' }) do
            package.loaded[name] = saved[name]
        end
    end)
    it('starts once and stops on normal exit', function()
        assert.equals(1, starts)
        onexit(0, 0)
        assert.equals(1, closes)
        vim.cmd('lclose')
        assert.equals(1, closes)
    end)
    it('stops on signal exit', function()
        onexit(0, 9)
        assert.equals(1, closes)
    end)
    it('stops immediately on WinClosed before process exit', function()
        vim.cmd('lclose')
        assert.equals(1, closes)
        onexit(0, 0)
        assert.equals(1, closes)
    end)
end)
