local setting = require('nvim_config.setting')

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

    it('evaluates fold text through the setting module without a global helper', function()
        setting.setup()
        local foldmethod = vim.wo.foldmethod
        vim.wo.foldmethod = 'manual'
        vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'fold heading', 'fold body' })
        vim.cmd('1,2fold')
        assert.is_equal('fold heading  ', vim.fn.foldtextresult(1):sub(1, 14))
        assert.is_nil(_G.FoldText)
        vim.cmd('normal! zE')
        vim.wo.foldmethod = foldmethod
    end)
end)
