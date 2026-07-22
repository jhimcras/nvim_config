local highlight = require('highlight')

describe('highlight', function()
    it('should have a setup function', function()
        assert.is_function(highlight.setup)
    end)

    it('should define global highlight groups without error', function()
        assert.has_no.errors(function() highlight.setup() end)

        local function defined(name)
            return next(vim.api.nvim_get_hl(0, { name = name })) ~= nil
        end

        assert.is_true(defined('QuickFixLine'))
        assert.is_true(defined('RenderMarkdownH1Bg'))
        assert.is_true(defined('TabLineSel'))
        assert.is_true(defined('AnsiBlack'))
        assert.is_true(defined('StatuslineGeneralActive_1_n'))
    end)
end)
