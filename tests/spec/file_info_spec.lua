local file_info = require('file_info')

describe('file_info', function()
    it('should have a setup function', function()
        assert.is_function(file_info.setup)
    end)
    
    -- Testing the internal format_size function if possible, or just the public API.
    -- Since format_size is local, we cannot test it directly without modifications or mocking.
end)
