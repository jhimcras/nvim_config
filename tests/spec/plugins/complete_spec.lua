describe('complete', function()
    it('should have a setup function', function()
        local original_cmp = package.loaded['cmp']
        package.loaded['cmp'] = {
            setup = function() end,
            mapping = setmetatable({
                preset = { insert = function(t) return t end },
                scroll_docs = function() end,
                confirm = function() end,
            }, {
                __call = function(_, callback)
                    return callback
                end,
            }),
            config = {
                sources = function() end,
                compare = { offset = 1, exact = 1, score = 1, recently_used = 1, locality = 1, kind = 1, sort_text = 1, length = 1, order = 1 },
                window = { bordered = function() end }
            }
        }
        package.loaded['nvim_config.plugins.complete'] = nil
        local complete = require('nvim_config.plugins.complete')
        assert.is_function(complete.setup)
        package.loaded['nvim_config.plugins.complete'] = nil
        package.loaded['cmp'] = original_cmp
    end)
    
    it('should attempt to setup cmp', function()
        -- Mock cmp.setup
        local original_cmp = package.loaded['cmp']
        local captured_opts
        local bordered_calls = 0
        package.loaded['cmp'] = {
            setup = function(opts)
                captured_opts = opts
                assert.is_table(opts)
            end,
            mapping = setmetatable({
                preset = { insert = function(t) return t end },
                scroll_docs = function() end,
                confirm = function() end,
            }, {
                __call = function(_, callback)
                    return callback
                end,
            }),
            config = {
                sources = function() end,
                compare = { offset = 1, exact = 1, score = 1, recently_used = 1, locality = 1, kind = 1, sort_text = 1, length = 1, order = 1 },
                window = {
                    bordered = function()
                        bordered_calls = bordered_calls + 1
                        return { bordered = true, call = bordered_calls }
                    end
                }
            }
        }
        
        -- Reload to pick up the mock
        package.loaded['nvim_config.plugins.complete'] = nil
        local complete = require('nvim_config.plugins.complete')
        
        assert.has_no.errors(function() complete.setup() end)

        assert.is_table(captured_opts.window)
        assert.are.same({ bordered = true, call = 1 }, captured_opts.window.completion)
        assert.are.same({ bordered = true, call = 2 }, captured_opts.window.documentation)
        
        -- Restore original
        package.loaded['cmp'] = original_cmp
    end)
end)
