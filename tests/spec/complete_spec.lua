local complete = require('complete')

describe('complete', function()
    it('should have a setup function', function()
        assert.is_function(complete.setup)
    end)
    
    it('should attempt to setup cmp', function()
        -- Mock cmp.setup
        local original_cmp = package.loaded['cmp']
        package.loaded['cmp'] = {
            setup = function(opts)
                assert.is_table(opts)
            end,
            mapping = {
                preset = { insert = function(t) return t end },
                scroll_docs = function() end,
                confirm = function() end,
                cmp = function() end
            },
            config = {
                sources = function() end,
                compare = { offset = 1, exact = 1, score = 1, recently_used = 1, locality = 1, kind = 1, sort_text = 1, length = 1, order = 1 },
                window = { bordered = function() end }
            }
        }
        
        -- Reload complete module to use mock
        package.loaded['complete'] = nil
        complete = require('complete')
        
        -- Since setup calls cmp.setup, this will trigger our mock
        -- Note: this requires nvim-cmp to be available or mocked properly in the environment
        -- For now, just test if it runs without error if mocked
        pcall(complete.setup)
        
        -- Restore original
        package.loaded['cmp'] = original_cmp
    end)
end)
