local env = require('env')

describe('env', function()
    it('should have correct OS flags', function()
        -- Mock vim.fn.has for environment checking
        local original_has = vim.fn.has
        vim.fn.has = function(feature)
            if feature == 'unix' then return 1 end
            if feature == 'win32' or feature == 'win64' then return 0 end
            return 0
        end
        
        assert.is_boolean(env.os.unix)
        assert.is_boolean(env.os.win)
        
        vim.fn.has = original_has
    end)
end)
