local keymap = require('keymap')

describe('keymap', function()
    it('should have a setup function', function()
        assert.is_function(keymap.setup)
    end)

    it('should register global mappings and commands without error', function()
        assert.has_no.errors(function() keymap.setup() end)

        -- representative mappings from each source file
        assert.is_not.equal('', vim.fn.maparg('<leader>gg', 'n'))
        assert.is_not.equal('', vim.fn.maparg('<leader>r', 'n'))
        assert.is_not.equal('', vim.fn.maparg('<leader>tv', 'n'))
        assert.is_not.equal('', vim.fn.maparg('<C-g>', 'n'))
        assert.is_not.equal('', vim.fn.maparg('<F12>', 'n'))
        assert.is_not.equal('', vim.fn.maparg('<Leader>ff', 'n'))
        assert.is_not.equal('', vim.fn.maparg('<c-right>', 'n'))
        assert.is_not.equal('', vim.fn.maparg('<c-h>', 'n'))
        assert.is_not.equal('', vim.fn.maparg('-', 'n'))

        assert.is_true(vim.fn.exists(':Grep') == 2)
        assert.is_true(vim.fn.exists(':FileInfo') == 2)
        assert.is_true(vim.fn.exists(':SaveSession') == 2)
        assert.is_true(vim.fn.exists(':GclogBack') == 2)
        assert.is_true(vim.fn.exists(':PrjRootConfig') == 2)
        assert.is_true(vim.fn.exists(':Config') == 2)
    end)
end)
