-- The CursorMoved path re-renders only the rows the cursor left and entered.
-- Every check compares it with a full refresh of an identical buffer and window.
local wrap = require('nvim_config.rendermark.wrap')

local long = 'Lorem ipsum dolor sit amet, **consectetur** adipiscing elit, sed do eiusmod '
    .. 'tempor incididunt ut labore et dolore magna aliqua, quis `nostrud` exercitation.'
local doc = {
    '# Title',
    '',
    long,
    '',
    '- ' .. long,
    '- [ ] ' .. long,
    '- [x] checked item',
    '  - nested ' .. long,
    '',
    '> ' .. long,
    '',
    '```lua',
    'local x = 1',
    '```',
    '',
    '| name | description |',
    '| --- | --- |',
    '| alpha | ' .. long .. ' |',
    '| beta | short |',
    '',
    'before<br>after <mark>marked</mark> text',
    '',
    long,
    'short line',
    long,
}

local names = { 'markdown_visual_wrap', 'rendermark_deco', 'rendermark_html' }

-- Marks anchored on the visible rows (plus the row above topline), without ids.
local function snapshot(buf, first, last)
    local out = {}
    for _, name in ipairs(names) do
        local ns = vim.api.nvim_create_namespace(name)
        for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, { first, 0 }, { last - 1, -1 },
            { details = true })) do
            local d = m[4]
            d.ns_id = nil
            out[#out + 1] = name .. ' ' .. m[2] .. ':' .. m[3] .. ' '
                .. vim.inspect(d, { newline = '', indent = '' })
        end
    end
    table.sort(out)
    return out
end

local function drain()
    local done = false
    vim.schedule(function() vim.schedule(function() vim.schedule(function() done = true end) end) end)
    vim.wait(1000, function() return done end)
end

local function open(lines)
    vim.cmd('enew')
    local buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].filetype = 'markdown'
    vim.api.nvim_exec_autocmds('FileType', { pattern = 'markdown' })
    return buf, vim.api.nvim_get_current_win()
end

describe('wrap cursor refresh', function()
    local a_buf, a_win, b_buf, b_win, a_tab

    before_each(function()
        pcall(vim.api.nvim_del_augroup_by_name, 'markdown_visual_wrap')
        pcall(vim.api.nvim_del_user_command, 'MarkdownWrapToggle')
        vim.cmd('silent! tabonly | silent! only')
        vim.o.showtabline = 2
        vim.o.scrolloff = 0
        vim.g.markdown_visual_wrap_enabled = nil
        wrap.setup()
        a_buf, a_win = open(doc)
        a_tab = vim.api.nvim_get_current_tabpage()
        vim.cmd('tabnew')
        b_buf, b_win = open(doc)
        vim.api.nvim_set_current_tabpage(a_tab)
        drain()
        wrap.refresh(a_win)
    end)

    -- Mirror A's view into B, full-refresh B, and compare A's visible marks.
    local function assert_matches_full()
        local view = vim.api.nvim_win_call(a_win, vim.fn.winsaveview)
        vim.api.nvim_win_call(b_win, function() vim.fn.winrestview(view) end)
        wrap.refresh(b_win)
        local info = vim.fn.getwininfo(a_win)[1]
        local first, last = math.max(info.topline - 2, 0), info.botline
        assert.are.same(snapshot(b_buf, first, last), snapshot(a_buf, first, last))
    end

    local function move(row, col)
        vim.api.nvim_win_set_cursor(a_win, { row, col or 0 })
        vim.api.nvim_exec_autocmds('CursorMoved', {})
        drain()
    end

    local function count_marks(fn)
        local original = vim.api.nvim_buf_set_extmark
        local n = 0
        vim.api.nvim_buf_set_extmark = function(...)
            n = n + 1
            return original(...)
        end
        local ok, err = pcall(fn)
        vim.api.nvim_buf_set_extmark = original
        assert(ok, err)
        return n
    end

    it('matches a full refresh after each j/k step', function()
        for row = 2, #doc do
            move(row)
            assert_matches_full()
        end
        for row = #doc - 1, 1, -1 do
            move(row)
            assert_matches_full()
        end
    end)

    it('matches a full refresh after a run of steps without one in between', function()
        for _, row in ipairs({ 3, 5, 6, 8, 17, 18, 19, 21, 18, 3, 23, 24, 25, 1 }) do
            move(row)
        end
        assert_matches_full()
    end)

    it('re-renders nothing when the cursor stays on its row', function()
        move(3)
        local n = count_marks(function()
            for col = 1, 20 do move(3, col) end
        end)
        assert.are.equal(0, n)
        assert_matches_full()
    end)

    it('picks up a foreign extmark placed on another row', function()
        move(3)
        local foreign = vim.api.nvim_create_namespace('test_cursor_foreign')
        vim.api.nvim_buf_set_extmark(a_buf, foreign, 9, 100, { end_col = 110, hl_group = 'Comment' })
        vim.api.nvim_buf_set_extmark(b_buf, foreign, 9, 100, { end_col = 110, hl_group = 'Comment' })
        move(3, 5)
        assert_matches_full()
    end)

    it('falls back to a full refresh when the width changes without an event', function()
        move(3)
        local ei = vim.o.eventignore
        vim.o.eventignore = 'all'
        for _, win in ipairs({ a_win, b_win }) do
            vim.api.nvim_set_current_win(win)
            vim.cmd('vsplit')
        end
        vim.api.nvim_set_current_win(a_win)
        vim.o.eventignore = ei
        assert.are.equal(vim.api.nvim_win_get_width(b_win), vim.api.nvim_win_get_width(a_win))
        move(5)
        assert_matches_full()
    end)

    it('falls back to a full refresh when another window rendered the buffer', function()
        move(3)
        local float = vim.api.nvim_open_win(a_buf, false,
            { relative = 'editor', row = 1, col = 1, width = 50, height = 8 })
        drain()
        wrap.refresh(float)
        move(5)
        assert_matches_full()
        vim.api.nvim_win_close(float, true)
    end)

    it('resyncs images only when a row height changed', function()
        local image = require('nvim_config.rendermark.image')
        local old_img, old_sync = vim.ui.img, image.schedule_image_sync
        local syncs = 0
        vim.ui.img = { set = function() end, del = function() end }
        vim.g.neopp_images_enabled = true
        image.schedule_image_sync = function() syncs = syncs + 1 end
        local ok, err = pcall(function()
            wrap.refresh(a_win)
            syncs = 0
            local counts = {}
            for _, row in ipairs({ 2, 3, 3, 2, 1 }) do
                move(row, row == 3 and #counts or 0)
                counts[#counts + 1] = syncs
            end
            -- Short rows keep their height; the long row 3 unwraps and wraps again.
            assert.are.same({ 0, 1, 1, 2, 2 }, counts)
        end)
        vim.ui.img, image.schedule_image_sync = old_img, old_sync
        vim.g.neopp_images_enabled = nil
        assert(ok, err)
    end)

    it('defers typing on the cursor row, then renders it', function()
        move(3)
        drain()
        local n = count_marks(function()
            for i = 1, 3 do
                vim.api.nvim_buf_set_text(a_buf, 2, 0, 2, 0, { 'x' })
                vim.api.nvim_win_set_cursor(a_win, { 3, i })
                vim.api.nvim_exec_autocmds('CursorMovedI', {})
                vim.api.nvim_exec_autocmds('TextChangedI', {})
                drain()
            end
        end)
        assert.are.equal(0, n)
        vim.api.nvim_buf_set_text(b_buf, 2, 0, 2, 0, { 'xxx' })
        vim.wait(300, function() return false end)
        drain()
        assert_matches_full()
    end)

    it('renders a line break typed in insert mode right away', function()
        move(3)
        drain()
        vim.api.nvim_buf_set_lines(a_buf, 3, 3, false, { '' })
        vim.api.nvim_buf_set_lines(b_buf, 3, 3, false, { '' })
        vim.api.nvim_win_set_cursor(a_win, { 4, 0 })
        vim.api.nvim_exec_autocmds('CursorMovedI', {})
        vim.api.nvim_exec_autocmds('TextChangedI', {})
        drain()
        assert_matches_full()
    end)
end)
