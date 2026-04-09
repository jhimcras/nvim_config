local md = require('md')

describe('md', function()
    it('should have a setup function', function()
        assert.is_function(md.setup)
    end)
end)
