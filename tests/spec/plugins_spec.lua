local plugins = require('plugins')

describe('plugins', function()
    it('should have a setup function', function()
        assert.is_function(plugins.setup)
    end)
    
    it('should run without error', function()
        -- Mock pckr and other dependencies
        package.loaded['pckr'] = { add = function() end }
        package.loaded['prjroot'] = { setup = function() end }
        package.loaded['launcher'] = { setup = function() end }
        package.loaded['grep'] = { setup = function() end }
        package.loaded['session'] = { setup = function() end }
        package.loaded['status'] = { setup = function() end }
        package.loaded['file_info'] = { setup = function() end }
        package.loaded['smart_colorcolumn'] = { setup = function() end }
        package.loaded['smart_cursorline'] = { setup = function() end }
        package.loaded['lsp_setting'] = { setup = function() end }
        
        -- Mock vim.api functions to avoid errors during setup execution
        local original_create_autocmd = vim.api.nvim_create_autocmd
        vim.api.nvim_create_autocmd = function() return 1 end
        
        -- The setup calls FullscreenSettings which references vim.g.neovide
        vim.g.neovide = false
        
        assert.has_no.errors(function() plugins.setup() end)
        
        vim.api.nvim_create_autocmd = original_create_autocmd
    end)
end)
