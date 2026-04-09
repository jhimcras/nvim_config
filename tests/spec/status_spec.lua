local status = require('status')

describe('status', function()
    it('should have a setup function', function()
        assert.is_function(status.setup)
    end)
    
    it('should setup tabline and statusline', function()
        -- Mock vim.o and vim.go
        local original_o = vim.o
        local original_go = vim.go
        local original_testing = vim.g.is_testing
        
        vim.o = {}
        vim.go = {}
        vim.g.is_testing = nil -- Temporarily allow setup to run
        
        -- Mock set_highlight to avoid errors
        package.loaded['util'] = { set_highlight = function() end }
        
        status.setup()
        
        assert.is_equal(2, vim.o.laststatus)
        assert.is_equal(2, vim.o.showtabline)
        
        vim.o = original_o
        vim.go = original_go
        vim.g.is_testing = original_testing
    end)
end)
