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
end)
