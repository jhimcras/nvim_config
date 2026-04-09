local smart_cursorline = require('smart_cursorline')

describe('smart_cursorline', function()
    it('should have a setup function', function()
        assert.is_function(smart_cursorline.setup)
    end)
    
    it('should set autocmds on setup', function()
        local original_create_autocmd = vim.api.nvim_create_autocmd
        local created_autocmds = {}
        vim.api.nvim_create_autocmd = function(events, opts)
            table.insert(created_autocmds, {events = events, opts = opts})
            return 1
        end
        
        smart_cursorline.setup()
        
        assert.is_true(#created_autocmds >= 4)
        
        vim.api.nvim_create_autocmd = original_create_autocmd
    end)
end)
