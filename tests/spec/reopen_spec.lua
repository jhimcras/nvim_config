local reopen

-- Capture defers reconciliation to vim.schedule, so tests must let the event
-- loop turn before inspecting the stack.
local function flush()
    vim.wait(50, function() return false end)
end

local function fresh_file(name)
    local path = vim.fn.tempname() .. '_' .. name
    vim.fn.writefile({ 'alpha', 'bravo', 'charlie', 'delta', 'echo' }, path)
    return path
end

describe('reopen', function()
    before_each(function()
        pcall(vim.api.nvim_del_augroup_by_name, 'reopen')
        package.loaded['reopen'] = nil
        reopen = require('reopen')
        vim.cmd('silent! tabonly!')
        vim.cmd('silent! only!')
        vim.cmd('enew!')
        reopen.setup()
        flush()
        reopen.clear()
    end)

    after_each(function()
        vim.cmd('silent! tabonly!')
        vim.cmd('silent! only!')
        flush()
    end)

    it('restores a vertical split to its original side and buffer', function()
        local path = fresh_file('vsplit.txt')
        vim.cmd('vsplit ' .. vim.fn.fnameescape(path))
        local restored_name = vim.api.nvim_buf_get_name(0)
        assert.are.equal(2, #vim.api.nvim_tabpage_list_wins(0))
        local left = vim.api.nvim_tabpage_list_wins(0)[1]
        local was_leftmost = vim.api.nvim_get_current_win() == left

        vim.cmd('close')
        flush()
        assert.are.equal(1, #vim.api.nvim_tabpage_list_wins(0))
        assert.are.equal(1, reopen.depth())

        assert.is_true(reopen.restore())
        assert.are.equal(2, #vim.api.nvim_tabpage_list_wins(0))
        assert.are.equal(restored_name, vim.api.nvim_buf_get_name(0))

        local now_leftmost = vim.api.nvim_get_current_win() == vim.api.nvim_tabpage_list_wins(0)[1]
        assert.are.equal(was_leftmost, now_leftmost)
    end)

    it('restores a horizontal split above/below as it was', function()
        local path = fresh_file('split.txt')
        vim.cmd('split ' .. vim.fn.fnameescape(path))
        local layout_before = vim.fn.winlayout()
        assert.are.equal('col', layout_before[1])

        vim.cmd('close')
        flush()
        assert.is_true(reopen.restore())

        local layout_after = vim.fn.winlayout()
        assert.are.equal('col', layout_after[1])
        assert.are.equal(2, #layout_after[2])
    end)

    it('restores the cursor position of the closed window', function()
        local path = fresh_file('cursor.txt')
        vim.cmd('vsplit ' .. vim.fn.fnameescape(path))
        vim.api.nvim_win_set_cursor(0, { 4, 2 })

        vim.cmd('close')
        flush()
        assert.is_true(reopen.restore())

        local cur = vim.api.nvim_win_get_cursor(0)
        assert.are.equal(4, cur[1])
        assert.are.equal(2, cur[2])
    end)

    it('restores the width of a resized window', function()
        local path = fresh_file('size.txt')
        vim.cmd('vsplit ' .. vim.fn.fnameescape(path))
        vim.api.nvim_win_set_width(0, 30)
        local width = vim.api.nvim_win_get_width(0)

        vim.cmd('close')
        flush()
        assert.is_true(reopen.restore())

        assert.is_true(math.abs(vim.api.nvim_win_get_width(0) - width) <= 2)
    end)

    it('collapses a multi-window tab close into a single tab entry', function()
        vim.cmd('tabnew ' .. vim.fn.fnameescape(fresh_file('tab_a.txt')))
        vim.cmd('vsplit ' .. vim.fn.fnameescape(fresh_file('tab_b.txt')))
        vim.cmd('split ' .. vim.fn.fnameescape(fresh_file('tab_c.txt')))
        assert.are.equal(3, #vim.api.nvim_tabpage_list_wins(0))
        local tabs_before = #vim.api.nvim_list_tabpages()

        vim.cmd('tabclose')
        flush()

        assert.are.equal(1, reopen.depth())
        assert.are.equal('tab', reopen.peek().kind)

        assert.is_true(reopen.restore())
        assert.are.equal(tabs_before, #vim.api.nvim_list_tabpages())
        assert.are.equal(3, #vim.api.nvim_tabpage_list_wins(0))
    end)

    it('omits quickfix and location lists when restoring a closed tab', function()
        local path = fresh_file('tab_lists.txt')
        vim.cmd('tabnew ' .. vim.fn.fnameescape(path))
        vim.fn.setloclist(vim.api.nvim_get_current_win(), { { filename = path, lnum = 1, text = 'loc' } })
        vim.cmd('lopen')
        vim.fn.setqflist({ { filename = path, lnum = 1, text = 'qf' } })
        vim.cmd('copen')
        assert.are.equal(3, #vim.api.nvim_tabpage_list_wins(0))

        vim.cmd('tabclose')
        flush()
        assert.are.equal('tab', reopen.peek().kind)
        assert.is_true(reopen.restore())

        -- Only the file window comes back; the two list windows are dropped.
        local wins = vim.api.nvim_tabpage_list_wins(0)
        assert.are.equal(1, #wins)
        for _, win in ipairs(wins) do
            assert.are_not.equal('quickfix', vim.bo[vim.api.nvim_win_get_buf(win)].buftype)
        end
        assert.are.equal(path, vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(wins[1])))
    end)

    it('records nothing for a tab holding only list windows', function()
        local path = fresh_file('only_lists.txt')
        vim.fn.setqflist({ { filename = path, lnum = 1, text = 'qf' } })
        vim.cmd('tabnew')
        vim.cmd('copen')
        vim.cmd('only')
        assert.are.equal('quickfix', vim.bo.buftype)
        flush()
        reopen.clear()

        vim.cmd('tabclose')
        flush()

        assert.are.equal(0, reopen.depth())
    end)

    it('still restores a lone quickfix window closed on its own', function()
        local path = fresh_file('lone_qf.txt')
        vim.cmd('edit ' .. vim.fn.fnameescape(path))
        vim.fn.setqflist({ { filename = path, lnum = 1, text = 'qf' } })
        vim.cmd('copen')

        vim.cmd('cclose')
        flush()
        assert.is_true(reopen.restore())

        assert.are.equal('quickfix', vim.bo[vim.api.nvim_win_get_buf(0)].buftype)
    end)

    it('ignores terminal windows', function()
        vim.cmd('vsplit')
        vim.cmd('terminal')
        flush()
        reopen.clear()

        vim.cmd('close!')
        flush()

        assert.are.equal(0, reopen.depth())
    end)

    it('restores a quickfix window with its list intact', function()
        local path = fresh_file('qf.txt')
        vim.fn.setqflist({ { filename = path, lnum = 2, text = 'hit one' } })
        vim.cmd('copen')
        assert.are.equal('quickfix', vim.bo.buftype)

        vim.cmd('cclose')
        flush()
        assert.is_true(reopen.restore())

        assert.are.equal('quickfix', vim.bo[vim.api.nvim_win_get_buf(0)].buftype)
        assert.are.equal(1, vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(0)))
    end)

    it('restores a location list still bound to its origin window', function()
        local path = fresh_file('loc.txt')
        vim.cmd('edit ' .. vim.fn.fnameescape(path))
        local origin = vim.api.nvim_get_current_win()
        vim.fn.setloclist(origin, { { filename = path, lnum = 3, text = 'loc hit' } })
        vim.cmd('lopen')

        vim.cmd('lclose')
        flush()
        assert.is_true(reopen.restore())

        local info = vim.fn.getloclist(vim.api.nvim_get_current_win(), { filewinid = 0, size = 0 })
        assert.are.equal(origin, info.filewinid)
        assert.are.equal(1, info.size)
    end)

    it('caps the stack at ten entries', function()
        for i = 1, 14 do
            vim.cmd('vsplit ' .. vim.fn.fnameescape(fresh_file('cap' .. i .. '.txt')))
            vim.cmd('close')
            flush()
        end
        assert.are.equal(10, reopen.depth())
    end)

    it('reports an empty stack without erroring', function()
        assert.are.equal(0, reopen.depth())
        assert.is_false(reopen.restore())
    end)

    it('skips capture while a session is loading', function()
        local path = fresh_file('sessionload.txt')
        vim.cmd('vsplit ' .. vim.fn.fnameescape(path))
        vim.g.SessionLoad = 1
        vim.cmd('close')
        vim.g.SessionLoad = nil
        flush()

        assert.are.equal(0, reopen.depth())
    end)

    it('discards a runaway burst of programmatic closes', function()
        local path = fresh_file('keep.txt')
        vim.cmd('vsplit ' .. vim.fn.fnameescape(path))
        vim.cmd('close')
        flush()
        assert.are.equal(1, reopen.depth())

        -- Twelve windows across two tabs torn down at once: not a user action.
        vim.cmd('tabnew')
        for _ = 1, 5 do vim.cmd('vsplit') end
        vim.cmd('tabnew')
        for _ = 1, 5 do vim.cmd('vsplit') end
        vim.cmd('silent! tabonly!')
        vim.cmd('silent! only!')
        flush()

        -- The pre-existing entry survives; the burst itself is dropped.
        assert.are.equal(1, reopen.depth())
        assert.are.equal('win', reopen.peek().kind)
    end)
end)
