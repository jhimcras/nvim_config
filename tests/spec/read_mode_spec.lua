local read_mode

describe('read_mode', function()
    before_each(function()
        pcall(vim.api.nvim_del_augroup_by_name, 'read_mode')
        package.loaded['read_mode'] = nil
        read_mode = require('read_mode')
        vim.cmd('enew')
        vim.bo.filetype = ''
        vim.bo.modifiable = true
        vim.wo.cursorline = true
    end)

    it('defaults to inactive for a window that never entered READ mode', function()
        read_mode.setup()
        assert.is_false(read_mode.is_active(vim.api.nvim_get_current_win()))
    end)

    it('toggles READ mode on and off', function()
        read_mode.setup()
        local win = vim.api.nvim_get_current_win()
        local buf = vim.api.nvim_get_current_buf()

        read_mode.toggle(win)
        assert.is_true(read_mode.is_active(win))
        assert.is_false(vim.bo[buf].modifiable)
        assert.is_false(vim.wo[win].cursorline)

        read_mode.toggle(win)
        assert.is_false(read_mode.is_active(win))
        assert.is_true(vim.bo[buf].modifiable)
        assert.is_true(vim.wo[win].cursorline)
    end)

    it('works on a non-markdown buffer', function()
        read_mode.setup()
        local win = vim.api.nvim_get_current_win()
        local buf = vim.api.nvim_get_current_buf()
        vim.bo[buf].filetype = 'lua'

        read_mode.enter(win)

        assert.is_true(read_mode.is_active(win))
        assert.is_false(vim.bo[buf].modifiable)
    end)

    it('tracks state independently per window for the same buffer', function()
        read_mode.setup()
        local win_a = vim.api.nvim_get_current_win()
        vim.cmd('vsplit')
        local win_b = vim.api.nvim_get_current_win()
        assert.are.equal(vim.api.nvim_win_get_buf(win_a), vim.api.nvim_win_get_buf(win_b))

        read_mode.enter(win_a)

        assert.is_true(read_mode.is_active(win_a))
        assert.is_false(read_mode.is_active(win_b))

        vim.api.nvim_win_close(win_b, true)
    end)

    it('cleans up state when the window closes', function()
        read_mode.setup()
        vim.cmd('vsplit')
        local win = vim.api.nvim_get_current_win()
        read_mode.enter(win)
        assert.is_true(read_mode.is_active(win))

        vim.api.nvim_win_close(win, true)

        assert.is_false(read_mode.is_active(win))
    end)

    it('does not auto-enter on opening a markdown buffer', function()
        read_mode.setup()
        local buf = vim.api.nvim_get_current_buf()
        local win = vim.api.nvim_get_current_win()
        vim.bo[buf].filetype = 'markdown'

        vim.api.nvim_exec_autocmds('FileType', { buffer = buf })
        vim.api.nvim_exec_autocmds('BufEnter', { buffer = buf })

        assert.is_false(read_mode.is_active(win))
        assert.is_true(vim.bo[buf].modifiable)
    end)

    it('persists across an in-window buffer switch', function()
        read_mode.setup()
        local win = vim.api.nvim_get_current_win()
        read_mode.enter(win)
        assert.is_true(read_mode.is_active(win))

        vim.cmd('enew')
        local new_buf = vim.api.nvim_get_current_buf()
        vim.api.nvim_exec_autocmds('BufWinEnter', { buffer = new_buf })

        assert.is_true(read_mode.is_active(win))
        assert.is_false(vim.bo[new_buf].modifiable)
    end)
end)
