local status = require('status')

describe('status', function()
    it('colors only the window in READ mode without a tag', function()
        require('highlight').setup()
        local read_mode = require('read_mode')
        local read_win = vim.api.nvim_get_current_win()
        vim.cmd('vsplit')
        local other_win = vim.api.nvim_get_current_win()

        read_mode.enter(read_win)
        vim.api.nvim_set_current_win(read_win)
        vim.g.statusline_winid = read_win
        local read_line = status.statusline_entry()
        vim.api.nvim_set_current_win(other_win)
        vim.g.statusline_winid = other_win
        local other_line = status.statusline_entry()

        assert.is_nil(read_line:find('READ', 1, true))
        assert.is_truthy(read_line:find('StatuslineGeneralActive_1_read', 1, true))
        assert.is_nil(other_line:find('READ', 1, true))
        assert.is_nil(other_line:find('StatuslineGeneralActive_1_read', 1, true))

        read_mode.exit(read_win)
        vim.g.statusline_winid = nil
        vim.api.nvim_win_close(read_win, true)
    end)

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
        
        -- Mock util functions to avoid errors
        package.loaded['util'] = {
            set_highlight = function() end,
            nnoremap = function() end,
        }
        
        status.setup()

        assert.is_equal(2, vim.o.laststatus)

        vim.o = original_o
        vim.go = original_go
        vim.g.is_testing = original_testing
    end)
end)
