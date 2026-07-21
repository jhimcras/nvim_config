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

    it('resolves a real / search: cursor clamps to column 0, n advances via the stored anchor', function()
        read_mode.setup()
        local win = vim.api.nvim_get_current_win()
        local buf = vim.api.nvim_get_current_buf()
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
            'start',
            'xxxx foo yyyy',
            'zzzz foo wwww',
        })

        read_mode.enter(win)
        vim.api.nvim_win_set_cursor(win, { 1, 0 })

        vim.cmd('normal /foo\r')
        vim.wait(200, function()
            local pos = vim.api.nvim_win_get_cursor(win)
            return pos[1] == 2 and pos[2] == 0
        end)

        local after_search = vim.api.nvim_win_get_cursor(win)
        assert.are.same({ 2, 0 }, after_search) -- clamped, not the true match column (5)

        vim.cmd('normal n')
        vim.wait(200, function()
            local pos = vim.api.nvim_win_get_cursor(win)
            return pos[1] == 3 and pos[2] == 0
        end)

        local after_next = vim.api.nvim_win_get_cursor(win)
        assert.are.same({ 3, 0 }, after_next) -- advanced via the stored anchor, not stuck on line 2
    end)

    it('never lets leftcol move, even when the match column is far past the window width', function()
        read_mode.setup()
        local win = vim.api.nvim_get_current_win()
        local buf = vim.api.nvim_get_current_buf()
        local width = vim.api.nvim_win_get_width(win)
        local long = string.rep('word ', width) .. 'target'
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { long, 'short' })
        vim.wo[win].wrap = false

        read_mode.enter(win)
        vim.api.nvim_win_set_cursor(win, { 1, 0 })

        vim.cmd('normal /target\r')
        vim.wait(200, function()
            return vim.api.nvim_win_get_cursor(win)[2] == 0
        end)

        local view = vim.fn.winsaveview()
        assert.are.equal(0, view.leftcol)
        assert.are.equal(0, view.col)

        vim.cmd('normal n') -- wraps back to the only match; must still not scroll
        vim.wait(200, function()
            return vim.fn.winsaveview().leftcol == 0
        end)

        view = vim.fn.winsaveview()
        assert.are.equal(0, view.leftcol)
        assert.are.equal(0, view.col)
    end)

    it('places an IncSearch highlight on the match and clears it on exit', function()
        read_mode.setup()
        local win = vim.api.nvim_get_current_win()
        local buf = vim.api.nvim_get_current_buf()
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'xxxx target yyyy' })

        read_mode.enter(win)
        vim.api.nvim_win_set_cursor(win, { 1, 0 })

        vim.cmd('normal /target\r')
        vim.wait(200, function()
            return vim.api.nvim_win_get_cursor(win)[2] == 0
        end)

        local ns = vim.api.nvim_create_namespace('read_mode_search')
        local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
        assert.are.equal(1, #marks)
        assert.are.equal('IncSearch', marks[1][4].hl_group)

        read_mode.exit(win)
        marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
        assert.are.equal(0, #marks)
    end)

    it('n includes a foreign hl_group extmark scheduled around the same time as the jump, on the wrapped rows', function()
        -- Regression test: a foreign decorator (e.g. render-markdown's checkbox
        -- scope_highlight) recomputes its extmarks via its own vim.schedule in
        -- reaction to the same cursor jump. If n's own wrap refresh runs
        -- synchronously (the bug), it snapshots the buffer's extmarks before
        -- that scheduled update has run and the highlight is dropped from the
        -- wrapped rows. Simulate that by enqueueing our own vim.schedule call
        -- right before the n keypress -- ordering must still put it ahead of
        -- read_mode's own (now-deferred) wrap refresh.
        local wrap = require('rendermark.wrap')
        pcall(vim.api.nvim_del_augroup_by_name, 'markdown_visual_wrap')
        wrap.setup({ left_pad = 0, right_pad = 0 })

        read_mode.setup()
        local win = vim.api.nvim_get_current_win()
        local buf = vim.api.nvim_get_current_buf()

        local width = vim.api.nvim_win_get_width(win)
        -- MARK sits well past the first visible row (in a continuation row)
        -- and clear of the search match's own IncSearch span, so its Comment
        -- highlight can be checked in isolation instead of being merged into
        -- a stacked hl with the match highlight.
        local filler = string.rep('word ', width)
        local long = filler .. 'MARK ' .. filler .. 'target'
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { long })
        vim.bo[buf].filetype = 'markdown'
        vim.api.nvim_exec_autocmds('FileType', { pattern = 'markdown' })

        local foreign_ns = vim.api.nvim_create_namespace('test_foreign_checkbox_deco')
        local mark_col = #filler
        local mark_end = mark_col + #'MARK'

        read_mode.enter(win)
        vim.api.nvim_win_set_cursor(win, { 1, 0 })

        vim.cmd('normal /target\r')
        vim.wait(200, function()
            return vim.api.nvim_win_get_cursor(win)[2] == 0
        end)

        vim.schedule(function()
            pcall(vim.api.nvim_buf_set_extmark, buf, foreign_ns, 0, mark_col, {
                end_col = mark_end,
                hl_group = 'Comment',
            })
        end)
        vim.cmd('normal n')

        local wrap_ns = vim.api.nvim_create_namespace('markdown_visual_wrap')
        local function has_comment_chunk()
            local marks = vim.api.nvim_buf_get_extmarks(buf, wrap_ns, { 0, 0 }, { 0, -1 }, { details = true })
            for _, m in ipairs(marks) do
                for _, row in ipairs(m[4].virt_lines or {}) do
                    for _, chunk in ipairs(row) do
                        if chunk[2] == 'Comment' then
                            return true
                        end
                    end
                end
            end
            return false
        end
        vim.wait(200, has_comment_chunk)

        assert.is_true(has_comment_chunk())
    end)

    it('falls through to a pre-existing global <Esc> mapping once READ mode is inactive again', function()
        -- Regression test: read_mode installs a buffer-local <Esc> map the
        -- first time a buffer ever enters READ mode, and never removes it
        -- (by design, see ensure_keymaps). If its inactive-fallback path fed
        -- <Esc> non-recursively instead of delegating to whatever <Esc>
        -- mapping existed before (e.g. a global :nohlsearch binding), that
        -- other mapping would silently stop firing on this buffer forever,
        -- even after read_mode.exit.
        local fired = false
        vim.keymap.set('n', '<esc>', function() fired = true end)

        read_mode.setup()
        local win = vim.api.nvim_get_current_win()
        read_mode.enter(win)
        read_mode.exit(win)

        vim.cmd('normal ' .. vim.api.nvim_replace_termcodes('<esc>', true, false, true))

        assert.is_true(fired)

        pcall(vim.keymap.del, 'n', '<esc>')
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
