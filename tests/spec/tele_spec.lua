local tele = require('nvim_config.plugins.tele')

describe('tele', function()
    it('should have a setup function', function()
        assert.is_function(tele.setup)
    end)
    
    it('should run without error', function()
        -- Mock telescope
        local original_actions = package.loaded['telescope.actions']
        package.loaded['telescope.actions'] = { close = function() end }
        package.loaded['telescope'] = { setup = function() end }
        
        -- Mock util functions
        package.loaded['nvim_config.util'] = { nmap = function() end }
        
        assert.has_no.errors(function() tele.setup() end)
        package.loaded['telescope.actions'] = original_actions
    end)
end)
