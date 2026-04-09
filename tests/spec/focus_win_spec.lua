local focus_win = require('focus_win')

describe('focus_win', function()
    it('should have a setup function', function()
        assert.is_function(focus_win.setup)
    end)
    
    it('should set autocmds on setup', function()
        local original_create_autocmd = vim.api.nvim_create_autocmd
        local created_autocmds = {}
        vim.api.nvim_create_autocmd = function(events, opts)
            table.insert(created_autocmds, {events = events, opts = opts})
            return 1
        end
        
        -- Mock util module dependency
        package.loaded['util'] = { set_highlight = function() end }
        
        focus_win.setup({active = '#000000', inactive = '#FFFFFF'})
        
        assert.is_true(#created_autocmds >= 1)
        
        vim.api.nvim_create_autocmd = original_create_autocmd
    end)
end)
