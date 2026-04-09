local lsp_setting = require('lsp_setting')

describe('lsp_setting', function()
    it('should have a setup function', function()
        assert.is_function(lsp_setting.setup)
    end)
    
    it('should have basic diagnostic symbols', function()
        assert.is_string(lsp_setting.SymError)
        assert.is_string(lsp_setting.SymWarn)
    end)
end)
