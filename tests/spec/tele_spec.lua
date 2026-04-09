local tele = require('tele')

describe('tele', function()
    it('should have a setup function', function()
        assert.is_function(tele.setup)
    end)
    
    it('should run without error', function()
        -- Mock telescope
        package.loaded['telescope'] = { setup = function() end }
        
        -- Mock util functions
        package.loaded['util'] = { nmap = function() end }
        
        assert.has_no.errors(function() tele.setup() end)
    end)
end)
