local read = require('rendermark.read')

describe('rendermark.read', function()
    before_each(function()
        pcall(vim.api.nvim_del_augroup_by_name, 'rendermark_read')
        vim.cmd('enew')
        vim.bo.filetype = ''
        vim.bo.modifiable = true
        vim.b.read_mode = false
        vim.b.markdown_read_mode = false
    end)

    it('enters READ mode when leaving a markdown window', function()
        read.setup()
        local buf = vim.api.nvim_get_current_buf()
        vim.bo[buf].filetype = 'markdown'

        vim.api.nvim_exec_autocmds('WinLeave', { buffer = buf })

        assert.is_true(vim.b[buf].read_mode)
        assert.is_true(vim.b[buf].markdown_read_mode)
        assert.is_false(vim.bo[buf].modifiable)
    end)

    it('does not enter READ mode when leaving a non-markdown window', function()
        read.setup()
        local buf = vim.api.nvim_get_current_buf()
        vim.bo[buf].filetype = 'lua'

        vim.api.nvim_exec_autocmds('WinLeave', { buffer = buf })

        assert.is_false(vim.b[buf].read_mode)
        assert.is_false(vim.b[buf].markdown_read_mode)
        assert.is_true(vim.bo[buf].modifiable)
    end)
end)
