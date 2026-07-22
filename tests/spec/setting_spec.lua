local setting = require('setting')

describe('setting', function()
    it('should have a setup function', function()
        assert.is_function(setting.setup)
    end)

    it('should apply global vim options without error', function()
        assert.has_no.errors(function() setting.setup() end)

        assert.is_equal(' ', vim.g.mapleader)
        assert.is_true(vim.o.ignorecase)
        assert.is_equal(1, vim.o.scrolloff)
        assert.is_true(vim.o.cursorline)
        assert.is_equal(2, vim.o.showtabline)
        assert.is_equal(4, vim.o.shiftwidth)
    end)
end)
