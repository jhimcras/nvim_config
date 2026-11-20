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

    it('keeps quotes in patterns, filename-only inverse matches and per-item fields', function()
        local user_data = { id = 7 }
        vim.fn.setloclist(origin, {}, 'r', { items = {
            { filename = paths[1], lnum = 1, text = "it's here", user_data = user_data },
            { filename = paths[2], lnum = 2, text = 'plain' },
            { filename = paths[1], lnum = 3, text = 'other' },
        } })
        vim.cmd("Lfilter /it's/")
        local items = vim.fn.getloclist(origin)
        assert.are.equal(1, #items)
        assert.are.same(user_data, items[1].user_data)
        assert.are.equal('owned location list', vim.fn.getloclist(origin, { title = 0 }).title)
        vim.fn.setloclist(origin, {}, 'r', { items = {
            { filename = paths[1], lnum = 1, text = 'one' },
            { filename = paths[2], lnum = 2, text = 'two' },
            { filename = paths[1], lnum = 3, text = 'three' },
        } })
        vim.cmd('Lfilter! /alpha/')
        items = vim.fn.getloclist(origin)
        assert.are.equal(1, #items)
        assert.are.equal('two', items[1].text)
    end)

    it('matches an empty-name pattern against items whose buffer was wiped', function()
        local gone = vim.fn.tempname() .. '_gone.txt'
        vim.fn.setloclist(origin, {}, 'r', { items = {
            { filename = gone, lnum = 1, text = 'orphan' },
            { filename = paths[1], lnum = 2, text = 'named' },
        } })
        vim.cmd('bwipe ' .. vim.fn.bufnr(gone))
        vim.cmd('Lfilter /^$/')
        local items = vim.fn.getloclist(origin)
        assert.are.equal(1, #items)
        assert.are.equal(1, items[1].lnum)
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

    local function by_text(items)
        local copy = vim.deepcopy(items)
        table.sort(copy, function(a, b) return a.text < b.text end)
        return copy
    end

    local function assert_sorted(items, order)
        for i = 2, #items do
            local a, b = items[i - 1], items[i]
            local an, bn = vim.fn.bufname(a.bufnr), vim.fn.bufname(b.bufnr)
            if order == 'desc' then a, b, an, bn = b, a, bn, an end
            assert.is_true(an < bn or (an == bn and a.lnum <= b.lnum),
                string.format('items %d and %d are out of %s order', i - 1, i, order))
        end
    end

    it('keeps every item field, the title, context and owner window when sorting', function()
        local list_win = vim.api.nvim_get_current_win()
        vim.fn.setloclist(origin, {}, 'r', {
            context = { source = 'spec' },
            items = {
                { filename = paths[2], lnum = 9, col = 1, end_lnum = 9, end_col = 5, text = 'b9', type = 'E',
                    module = 'beta-mod', user_data = { id = 1 } },
                { filename = paths[1], lnum = 4, col = 2, text = 'a4', type = 'W', valid = 0, nr = 7 },
                { filename = paths[2], lnum = 2, col = 3, vcol = 1, pattern = 'pat', text = 'b2' },
                { filename = paths[1], lnum = 1, col = 4, end_col = 8, text = 'a1', user_data = 'u' },
            },
        })
        local before = by_text(vim.fn.getloclist(origin))

        edit.sort_list()
        local items = vim.fn.getloclist(origin)
        assert_sorted(items, 'asc')
        assert.are.same(before, by_text(items))
        assert.are.equal('asc', vim.w.sort_order)
        assert.are.equal(list_win, vim.api.nvim_get_current_win())
        local info = vim.fn.getloclist(origin, { title = 1, context = 1 })
        assert.are.equal('owned location list', info.title)
        assert.are.same({ source = 'spec' }, info.context)

        edit.sort_list()
        items = vim.fn.getloclist(origin)
        assert_sorted(items, 'desc')
        assert.are.same(before, by_text(items))
        assert.are.equal('desc', vim.w.sort_order)
        assert.are.equal(3, #vim.fn.getqflist())
    end)

    it('sorts the quickfix window without touching the location list', function()
        vim.cmd('copen')
        edit.sort_list()
        local items = vim.fn.getqflist()
        assert_sorted(items, 'asc')
        assert.are.equal('independent quickfix', vim.fn.getqflist({ title = 1 }).title)
        assert.are.same({ 'keep first', 'keep second', 'drop third' },
            vim.tbl_map(function(item) return item.text end, vim.fn.getloclist(origin)))
        vim.cmd('cclose')
    end)

    it('re-sorts a list that changed after the previous sort', function()
        edit.sort_list()
        vim.fn.setloclist(origin, {}, 'a', { items = {
            { filename = paths[1], lnum = 9, text = 'late alpha' },
            { filename = paths[2], lnum = 1, text = 'late beta' },
        } })
        edit.sort_list()
        local items = vim.fn.getloclist(origin)
        assert.are.equal(5, #items)
        assert_sorted(items, 'desc')
    end)

    it('sorts large shuffled lists across many buffers in both directions', function()
        local names, items = {}, {}
        for f = 1, 30 do names[f] = vim.fn.tempname() .. '_many.txt' end
        local seed = 7
        for i = 1, 3000 do
            seed = (seed * 1103515245 + 12345) % 2147483648
            local f = seed % 30 + 1
            items[i] = { filename = names[f], lnum = seed % 997 + 1, col = i, text = 'item ' .. i }
        end
        vim.fn.setloclist(origin, {}, 'r', { items = items })
        local before = by_text(vim.fn.getloclist(origin))

        for _, order in ipairs({ 'asc', 'desc', 'asc' }) do
            edit.sort_list()
            local sorted = vim.fn.getloclist(origin)
            assert.are.equal(order, vim.w.sort_order)
            assert_sorted(sorted, order)
            assert.are.same(before, by_text(sorted))
        end
        for _, name in ipairs(names) do
            local buf = vim.fn.bufnr(name)
            if buf > 0 then vim.api.nvim_buf_delete(buf, { force = true }) end
        end
    end)
end)
