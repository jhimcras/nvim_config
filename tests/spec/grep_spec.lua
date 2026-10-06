local tag = require('nvim_config.qflist.tag')
local filter = require('nvim_config.qflist.filter')
local edit = require('nvim_config.qflist.edit')

-- Helper: open a floating scratch window
local function new_win()
    local buf = vim.api.nvim_create_buf(false, true)
    local win = vim.api.nvim_open_win(buf, false, {
        relative = 'editor', row = 0, col = 0, width = 80, height = 5,
    })
    return win, buf
end

describe('tag.update_loclist_sl', function()
    local wins, bufs = {}, {}
    local global_sl_before

    before_each(function()
        global_sl_before = vim.o.statusline
    end)

    after_each(function()
        for _, w in ipairs(wins) do
            if vim.api.nvim_win_is_valid(w) then
                pcall(vim.api.nvim_win_close, w, true)
            end
        end
        for _, b in ipairs(bufs) do
            if vim.api.nvim_buf_is_valid(b) then
                pcall(vim.api.nvim_buf_delete, b, { force = true })
            end
        end
        wins, bufs = {}, {}
    end)

    local function make_win()
        local w, b = new_win()
        table.insert(wins, w)
        table.insert(bufs, b)
        return w
    end

    -- Regression: a window-local statusline on qf/loclist buffers overwrote the
    -- global one. Clearing it with only {win=id} (no scope='local') is safe.
    it('clearing window-local statusline to empty does not corrupt the global', function()
        local win = make_win()
        vim.api.nvim_set_option_value('statusline', '', { win = win })
        assert.equals(global_sl_before, vim.o.statusline,
            'nvim_set_option_value(statusline, "", {win=id}) must not overwrite vim.o.statusline')
    end)

    it('does not corrupt the global statusline', function()
        local win = make_win()
        vim.w[win].grep_title = 'Search: foo │ /project'
        tag.update_loclist_sl(win)
        assert.equals(global_sl_before, vim.o.statusline,
            'update_loclist_sl must not overwrite vim.o.statusline')
    end)

    it('does not set a window-local statusline (leaves it for global to handle)', function()
        local win = make_win()
        vim.w[win].grep_title = 'Search: foo │ /project'
        -- Clear any pre-existing local statusline so the test starts clean.
        vim.api.nvim_win_call(win, function() vim.wo.statusline = '' end)
        tag.update_loclist_sl(win)
        local local_sl = vim.wo[win].statusline
        -- An empty local value reads back as the global one.
        local expected = vim.o.statusline
        assert.equals(expected, local_sl,
            'window-local statusline must match global statusline when empty')
    end)

    -- One window's title must not leak into the shared global.
    it('calling for two windows does not corrupt the global with one specific title', function()
        local win1 = make_win()
        local win2 = make_win()
        vim.w[win1].grep_title = 'Search: alpha │ /proj'
        vim.w[win2].grep_title = 'Search: beta │ /proj'
        tag.update_loclist_sl(win1)
        tag.update_loclist_sl(win2)
        -- Global must still be the original expression, not a literal title string.
        assert.equals(global_sl_before, vim.o.statusline,
            'global statusline must not be overwritten by either title')
    end)
end)

describe('qflist filtering and editing', function()
    local origin, paths

    before_each(function()
        origin = vim.api.nvim_get_current_win()
        paths = { vim.fn.tempname() .. '_alpha.txt', vim.fn.tempname() .. '_beta.txt' }
        local items = {
            { filename = paths[1], lnum = 1, col = 2, text = 'keep first' },
            { filename = paths[2], lnum = 2, col = 3, text = 'keep second' },
            { filename = paths[2], lnum = 3, col = 4, text = 'drop third' },
        }
        vim.fn.setloclist(origin, {}, ' ', { title = 'owned location list', items = items })
        vim.fn.setqflist({}, ' ', { title = 'independent quickfix', items = items })
        vim.cmd('lopen')
    end)

    after_each(function()
        vim.cmd('lclose')
        vim.api.nvim_set_current_win(origin)
        for _, path in ipairs(paths) do
            local buf = vim.fn.bufnr(path)
            if buf > 0 then vim.api.nvim_buf_delete(buf, { force = true }) end
        end
        vim.fn.setloclist(origin, {}, 'f')
        vim.fn.setqflist({}, 'f')
    end)

    it('filters by text from the list window without changing quickfix or item coordinates', function()
        vim.cmd('Lfilter /keep/')
        local items = vim.fn.getloclist(origin)
        assert.are.equal(2, #items)
        assert.are.equal(2, items[2].lnum)
        assert.are.equal(3, items[2].col)
        assert.are.equal(3, #vim.fn.getqflist())
        assert.are.same({ 'keep' }, filter.get_filter_chain(0))
    end)

    it('supports filename matches and chained inverse filters', function()
        vim.cmd('Lfilter /beta/')
        vim.cmd('Lfilter! /drop/')
        assert.are.equal('keep second', vim.fn.getloclist(origin)[1].text)
        assert.are.equal(1, #vim.fn.getloclist(origin))
        assert.are.same({ 'beta', '!drop' }, filter.get_filter_chain(0))
    end)

    it('filters quickfix without changing the window-owned location list', function()
        vim.cmd('Cfilter! /drop/')
        assert.are.equal(2, #vim.fn.getqflist())
        assert.are.equal(3, #vim.fn.getloclist(origin))
    end)

    it('sorts by filename then line number and reverses direction on the next call', function()
        edit.sort_list()
        local items = vim.fn.getloclist(origin)
        assert.are.same({ 1, 2, 3 }, { items[1].lnum, items[2].lnum, items[3].lnum })
        edit.sort_list()
        items = vim.fn.getloclist(origin)
        assert.are.same({ 3, 2, 1 }, { items[1].lnum, items[2].lnum, items[3].lnum })
    end)
end)
