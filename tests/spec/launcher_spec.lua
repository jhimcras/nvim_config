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

    it('should set launcher buffer to be non-modifiable in M.Launch', function()
        local mock_buf = vim.api.nvim_create_buf(false, true)
        local original_new_scratch = require('util').NewScratchBuffer
        require('util').NewScratchBuffer = function() return mock_buf end
        
        -- Mock AsyncProcess to avoid actual process creation
        local original_async = require('util').AsyncProcess
        require('util').AsyncProcess = function() return 123, function() end, function() return "running" end, {} end
        
        launcher.Launch('ls', {}, '.', nil, nil, nil, 'use', nil, nil, 'test')
        
        local modifiable = vim.api.nvim_buf_get_option(mock_buf, 'modifiable')
        assert.is_false(modifiable)
        
        require('util').NewScratchBuffer = original_new_scratch
        require('util').AsyncProcess = original_async
    end)
end)
