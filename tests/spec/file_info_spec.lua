local file_info = require('nvim_config.file_info')

describe('file_info', function()
    it('should have a setup function', function()
        assert.is_function(file_info.setup)
    end)
end)
