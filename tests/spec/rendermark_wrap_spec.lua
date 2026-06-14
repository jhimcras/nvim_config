local wrap = require('rendermark.wrap')

describe('wrap.compute_indent', function()
    it('returns hanging indent for list/quote/paragraph lines', function()
        assert.are.equal(0, wrap.compute_indent('plain text'))
        assert.are.equal(2, wrap.compute_indent('- item'))
        assert.are.equal(2, wrap.compute_indent('* item'))
        assert.are.equal(2, wrap.compute_indent('+ item'))
        assert.are.equal(3, wrap.compute_indent('1. item'))
        assert.are.equal(4, wrap.compute_indent('12) item'))
        assert.are.equal(4, wrap.compute_indent('  - nested'))
        assert.are.equal(6, wrap.compute_indent('- [ ] task'))
        assert.are.equal(6, wrap.compute_indent('- [x] task'))
        assert.are.equal(2, wrap.compute_indent('> quote'))
        assert.are.equal(2, wrap.compute_indent('  paragraph'))
    end)
end)

describe('wrap.wrap_line', function()
    it('does not wrap a line that fits', function()
        local r = wrap.wrap_line('short line', 80, 80, 0)
        assert.is_nil(r.first_end_byte)
        assert.are.same({}, r.lines)
    end)

    it('word-wraps at spaces and reports the conceal byte', function()
        local r = wrap.wrap_line('aaaa bbbb cccc', 9, 9, 0)
        assert.are.equal(9, r.first_end_byte) -- conceal from the space after "bbbb"
        assert.are.same({ 'cccc' }, r.lines)
    end)

    it('applies a hanging indent to continuation rows', function()
        local r = wrap.wrap_line('- aaaa bbbb cccc', 11, 9, 2)
        assert.are.equal(11, r.first_end_byte)
        assert.are.same({ '  cccc' }, r.lines)
    end)

    it('hard-breaks text without spaces (CJK, double-width)', function()
        local r = wrap.wrap_line(string.rep('가', 10), 4, 4, 0) -- each '가' is 2 cols
        assert.is_truthy(r.first_end_byte)
        assert.are.equal(4, #r.lines) -- 2 chars/row -> 5 rows total -> 4 continuations
    end)

    it('reports raw byte spans for continuation rows', function()
        local text = 'aaaa bbbb cccc'
        local r = wrap.wrap_line(text, 9, 9, 0)
        assert.are.same({ { 10, 14 } }, r.spans)
        assert.are.equal('cccc', text:sub(r.spans[1][1] + 1, r.spans[1][2]))
    end)

    it('reports CJK byte spans matching the continuation rows', function()
        local text = string.rep('가', 10) -- 3 bytes per char, 2 chars per row
        local r = wrap.wrap_line(text, 4, 4, 0)
        assert.are.equal(#r.lines, #r.spans)
        for k, span in ipairs(r.spans) do
            assert.are.equal(r.lines[k], text:sub(span[1] + 1, span[2]))
        end
    end)

    it('excludes trimmed trailing spaces from the span', function()
        local text = 'xxxx yyyy  '
        local r = wrap.wrap_line(text, 4, 4, 0)
        assert.are.same({ 'yyyy' }, r.lines)
        assert.are.same({ { 5, 9 } }, r.spans)
    end)
end)

describe('wrap.split_cells', function()
    it('splits rows with and without outer pipes', function()
        assert.are.same({ 'a', 'b', 'c' }, wrap.split_cells('| a | b | c |'))
        assert.are.same({ 'a', 'b' }, wrap.split_cells('a | b'))
    end)

    it('keeps a genuinely empty cell and unescapes \\|', function()
        assert.are.same({ '', 'b' }, wrap.split_cells('|  | b |'))
        assert.are.same({ 'a|b', 'c' }, wrap.split_cells('| a\\|b | c |'))
    end)
end)

describe('wrap.split_cells_pos', function()
    it('returns per-char source byte positions', function()
        local cells = wrap.split_cells_pos('| a | b |')
        assert.are.equal('a', cells[1].text)
        assert.are.same({ { c = 'a', b = 2 } }, cells[1].chars)
        assert.are.equal('b', cells[2].text)
        assert.are.same({ { c = 'b', b = 6 } }, cells[2].chars)
    end)

    it('maps an escaped pipe to the pipe byte', function()
        local cells = wrap.split_cells_pos('| a\\|b | c |')
        assert.are.equal('a|b', cells[1].text)
        assert.are.same({
            { c = 'a', b = 2 }, { c = '|', b = 4 }, { c = 'b', b = 5 },
        }, cells[1].chars)
    end)

    it('tracks multibyte cell content positions', function()
        local cells = wrap.split_cells_pos('| 가 | b |')
        assert.are.same({ { c = '가', b = 2 } }, cells[1].chars)
        assert.are.same({ { c = 'b', b = 8 } }, cells[2].chars)
    end)
end)

describe('wrap.parse_aligns', function()
    it('reads alignment markers from the delimiter row', function()
        assert.are.same({ 'left', 'right', 'center' },
            wrap.parse_aligns('| :--- | ---: | :--: |'))
        assert.are.same({ 'left', 'left' }, wrap.parse_aligns('| --- | --- |'))
    end)
end)

describe('wrap.wrap_cell', function()
    it('wraps at spaces within the cell width', function()
        assert.are.same({ 'aaaa', 'bbbb', 'cccc' }, wrap.wrap_cell('aaaa bbbb cccc', 4))
    end)

    it('hard-breaks CJK by display width', function()
        local r = wrap.wrap_cell(string.rep('가', 6), 4) -- 2 cols each -> 2 per row
        assert.are.equal(3, #r)
    end)

    it('returns a single empty row for empty text', function()
        assert.are.same({ '' }, wrap.wrap_cell('', 10))
    end)
end)

describe('wrap.flatten_runs', function()
    it('splits overlapping intervals into stacked runs', function()
        local runs = wrap.flatten_runs({
            { s = 0, e = 10, hl = 'A', priority = 100, seq = 1 },
            { s = 4, e = 6, hl = 'B', priority = 100, seq = 2 },
        }, 10)
        assert.are.same({
            { s = 0, e = 4, hl = { 'A' } },
            { s = 4, e = 6, hl = { 'A', 'B' } },
            { s = 6, e = 10, hl = { 'A' } },
        }, runs)
    end)

    it('orders the hl stack by priority before capture order', function()
        local runs = wrap.flatten_runs({
            { s = 0, e = 2, hl = 'High', priority = 110, seq = 1 },
            { s = 0, e = 2, hl = 'Low', priority = 100, seq = 2 },
        }, 2)
        assert.are.same({ { s = 0, e = 2, hl = { 'Low', 'High' } } }, runs)
    end)

    it('keeps conceal and its anchor on every slice of the interval', function()
        local runs = wrap.flatten_runs({
            { s = 2, e = 4, conceal = '', priority = 100, seq = 1 },
            { s = 3, e = 6, hl = 'A', priority = 100, seq = 2 },
        }, 8)
        assert.are.same({
            { s = 2, e = 3, conceal = '', conceal_anchor = 2 },
            { s = 3, e = 4, hl = { 'A' }, conceal = '', conceal_anchor = 2 },
            { s = 4, e = 6, hl = { 'A' } },
        }, runs)
    end)

    it('lets a higher-priority conceal win', function()
        local runs = wrap.flatten_runs({
            { s = 0, e = 2, conceal = 'x', priority = 100, seq = 1 },
            { s = 0, e = 2, conceal = '', priority = 110, seq = 2 },
        }, 2)
        assert.are.equal('', runs[1].conceal)
    end)
end)

describe('wrap.compute_table_layout', function()
    it('keeps natural widths and distributes leftover when there is room', function()
        local rows = { { 'ab', string.rep('x', 50) } } -- col1 natural 2, col2 natural 50
        local w = wrap.compute_table_layout(rows, 80, 30, 5)
        assert.are.equal(2, w[1])          -- short column stays at its content width
        assert.is_true(w[2] > 30)          -- capped column grew past the 30 cap with leftover
        assert.is_true(w[1] + w[2] + 7 <= 80) -- fits the budget (overhead 3N+1 = 7)
    end)

    it('shrinks columns proportionally when over budget', function()
        local rows = { { string.rep('a', 40), string.rep('b', 40) } }
        local w = wrap.compute_table_layout(rows, 30, 30, 5)
        assert.is_true(w[1] >= 5 and w[2] >= 5) -- respects the min floor
        assert.is_true(w[1] + w[2] + 7 <= 30)
    end)
end)

describe('wrap behavior', function()
    before_each(function()
        pcall(vim.api.nvim_del_augroup_by_name, 'markdown_visual_wrap')
        pcall(vim.api.nvim_del_user_command, 'MarkdownWrapToggle')
        vim.cmd('enew')
        vim.bo.filetype = ''
        vim.g.markdown_visual_wrap_enabled = nil
    end)

    it('has a setup function', function()
        assert.is_function(wrap.setup)
    end)

    it('turns off native wrap on markdown buffers', function()
        wrap.setup()
        vim.bo.filetype = 'markdown'
        vim.api.nvim_exec_autocmds('FileType', { pattern = 'markdown' })
        assert.is_false(vim.wo.wrap)
    end)

    it('starts the treesitter highlighter on markdown buffers', function()
        wrap.setup()
        vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'some **bold** text' })
        vim.bo.filetype = 'markdown'
        vim.api.nvim_exec_autocmds('FileType', { pattern = 'markdown' })
        local buf = vim.api.nvim_get_current_buf()
        assert.is_truthy(vim.treesitter.highlighter.active[buf])
    end)

    it('keeps line numbers visible in the custom statuscolumn', function()
        wrap.setup({ left_pad = 2 })
        vim.bo.filetype = 'markdown'
        vim.api.nvim_exec_autocmds('FileType', { pattern = 'markdown' })
        -- The reading margin must not blank out the number column.
        assert.is_truthy(vim.wo.statuscolumn:find('v:lnum'))
        assert.is_truthy(vim.wo.statuscolumn:find('v:relnum'))
    end)

    it('restores statuscolumn when the window switches to a non-markdown buffer', function()
        wrap.setup({ left_pad = 2 })
        vim.wo.statuscolumn = '' -- window-local; normalize any leak from a prior test
        local original = vim.wo.statuscolumn
        vim.bo.filetype = 'markdown'
        vim.api.nvim_exec_autocmds('FileType', { pattern = 'markdown' })
        assert.are_not.equal(original, vim.wo.statuscolumn) -- applied

        -- Same window, now showing a non-markdown buffer.
        vim.bo.filetype = ''
        vim.api.nvim_exec_autocmds('WinEnter', {})
        assert.are.equal(original, vim.wo.statuscolumn) -- restored, numbers return
    end)

    it('decorates non-cursor long lines and skips the cursor line', function()
        wrap.setup()
        local width = vim.api.nvim_win_get_width(0)
        local long = string.rep('word ', math.ceil(width / 5) + 20)
        vim.api.nvim_buf_set_lines(0, 0, -1, false, { long, long, 'short' })
        vim.bo.filetype = 'markdown'
        vim.api.nvim_exec_autocmds('FileType', { pattern = 'markdown' })
        vim.api.nvim_win_set_cursor(0, { 1, 0 })
        wrap.refresh(0)

        local ns = vim.api.nvim_create_namespace('markdown_visual_wrap')
        local on_cursor = vim.api.nvim_buf_get_extmarks(0, ns, { 0, 0 }, { 0, -1 }, {})
        local on_other = vim.api.nvim_buf_get_extmarks(0, ns, { 1, 0 }, { 1, -1 }, {})
        assert.are.equal(0, #on_cursor)
        assert.is_true(#on_other > 0)
    end)

    it('caps the wrap width at max_width when the window is wider', function()
        wrap.setup({ max_width = 30, left_pad = 0, right_pad = 0 })
        -- A 60-col line: fits the (wider) test window, but exceeds max_width = 30.
        local line = string.rep('word ', 12)
        vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'short', line })
        vim.bo.filetype = 'markdown'
        vim.api.nvim_exec_autocmds('FileType', { pattern = 'markdown' })
        vim.api.nvim_win_set_cursor(0, { 1, 0 }) -- cursor off the long line
        wrap.refresh(0)

        local ns = vim.api.nvim_create_namespace('markdown_visual_wrap')
        local on_long = vim.api.nvim_buf_get_extmarks(0, ns, { 1, 0 }, { 1, -1 }, {})
        assert.is_true(#on_long > 0) -- wrapped because of the 30-col cap
    end)

    it('drops all decorations while horizontally scrolled and restores them', function()
        wrap.setup({ left_pad = 0, right_pad = 0 })
        local width = vim.api.nvim_win_get_width(0)
        local long = string.rep('word ', math.ceil(width / 5) + 20)
        vim.api.nvim_buf_set_lines(0, 0, -1, false, { long, long })
        vim.bo.filetype = 'markdown'
        vim.api.nvim_exec_autocmds('FileType', { pattern = 'markdown' })
        vim.api.nvim_win_set_cursor(0, { 1, 0 }) -- cursor off line 2

        local ns = vim.api.nvim_create_namespace('markdown_visual_wrap')

        wrap.refresh(0)
        local at_rest = vim.api.nvim_buf_get_extmarks(0, ns, { 1, 0 }, { 1, -1 }, {})
        assert.is_true(#at_rest > 0) -- decorated at leftcol == 0

        vim.api.nvim_win_call(0, function() vim.fn.winrestview({ leftcol = 10 }) end)
        wrap.refresh(0)
        local scrolled = vim.api.nvim_buf_get_extmarks(0, ns, { 0, 0 }, { -1, -1 }, {})
        assert.are.equal(0, #scrolled) -- no decorations while scrolled

        vim.api.nvim_win_call(0, function() vim.fn.winrestview({ leftcol = 0 }) end)
        wrap.refresh(0)
        local restored = vim.api.nvim_buf_get_extmarks(0, ns, { 1, 0 }, { 1, -1 }, {})
        assert.is_true(#restored > 0) -- restored when leftcol returns to 0
    end)

    it('does not wrap lines inside fenced code blocks', function()
        wrap.setup({ left_pad = 0, right_pad = 0 })
        local width = vim.api.nvim_win_get_width(0)
        local long = string.rep('word ', math.ceil(width / 5) + 20)
        vim.api.nvim_buf_set_lines(0, 0, -1, false, { long, '```lua', long, '```' })
        vim.bo.filetype = 'markdown'
        vim.api.nvim_exec_autocmds('FileType', { pattern = 'markdown' })
        vim.api.nvim_win_set_cursor(0, { 4, 0 }) -- cursor off both long lines
        wrap.refresh(0)

        local ns = vim.api.nvim_create_namespace('markdown_visual_wrap')
        local prose = vim.api.nvim_buf_get_extmarks(0, ns, { 0, 0 }, { 0, -1 }, {})
        local in_code = vim.api.nvim_buf_get_extmarks(0, ns, { 2, 0 }, { 2, -1 }, {})
        assert.is_true(#prose > 0)    -- prose line wrapped
        assert.are.equal(0, #in_code) -- code line untouched
    end)

    it('styles and conceals inline markup in continuation rows', function()
        wrap.setup({ left_pad = 0, right_pad = 0 })
        local width = vim.api.nvim_win_get_width(0)
        local long = string.rep('x', width) .. ' **bold** end'
        vim.api.nvim_buf_set_lines(0, 0, -1, false, { long, 'short' })
        vim.bo.filetype = 'markdown'
        vim.api.nvim_exec_autocmds('FileType', { pattern = 'markdown' })
        vim.api.nvim_win_set_cursor(0, { 2, 0 }) -- cursor off the long line
        wrap.refresh(0)

        local ns = vim.api.nvim_create_namespace('markdown_visual_wrap')
        local marks = vim.api.nvim_buf_get_extmarks(0, ns, { 0, 0 }, { 0, -1 },
            { details = true })
        local joined, bold_hl = {}, nil
        for _, m in ipairs(marks) do
            for _, row in ipairs(m[4].virt_lines or {}) do
                for _, chunk in ipairs(row) do
                    joined[#joined + 1] = chunk[1]
                    if chunk[1] == 'bold' then bold_hl = chunk[2] end
                end
            end
        end
        local text = table.concat(joined)
        assert.is_truthy(text:find('bold', 1, true)) -- content kept
        assert.is_falsy(text:find('*', 1, true))     -- ** markers concealed
        assert.is_truthy(vim.inspect(bold_hl):find('markup%.strong'))
    end)

    it('renders a table as a grid and leaves the cursor row raw', function()
        wrap.setup({ left_pad = 0, right_pad = 0 })
        vim.api.nvim_buf_set_lines(0, 0, -1, false, {
            'prose',
            '| Name | Description |',
            '| :--- | :---------- |',
            '| a | a fairly long description that wraps inside the cell here |',
            '| b | short |',
        })
        vim.bo.filetype = 'markdown'
        vim.api.nvim_exec_autocmds('FileType', { pattern = 'markdown' })
        vim.api.nvim_win_set_cursor(0, { 1, 0 }) -- cursor off the table
        wrap.refresh(0)

        local ns = vim.api.nvim_create_namespace('markdown_visual_wrap')
        -- every table row carries decorations (conceal/overlay/virt_lines)
        for _, lnum in ipairs({ 1, 2, 3, 4 }) do
            local marks = vim.api.nvim_buf_get_extmarks(0, ns, { lnum, 0 }, { lnum, -1 }, {})
            assert.is_true(#marks > 0)
        end

        -- park the cursor on a data row: that row is left raw (no conceal extmark)
        vim.api.nvim_win_set_cursor(0, { 4, 0 })
        wrap.refresh(0)
        local on_cursor = vim.api.nvim_buf_get_extmarks(0, ns, { 3, 0 }, { 3, -1 },
            { details = true })
        local has_conceal = false
        for _, m in ipairs(on_cursor) do
            if m[4] and m[4].conceal ~= nil then has_conceal = true end
        end
        assert.is_false(has_conceal)
    end)

    it('styles table cells, conceals markers, and keeps the grid aligned', function()
        wrap.setup({ left_pad = 0, right_pad = 0 })
        vim.api.nvim_buf_set_lines(0, 0, -1, false, {
            'prose',
            '| **Head** | Other |',
            '| :------- | :---- |',
            '| `code` cell | plain |',
        })
        vim.bo.filetype = 'markdown'
        vim.api.nvim_exec_autocmds('FileType', { pattern = 'markdown' })
        vim.api.nvim_win_set_cursor(0, { 1, 0 }) -- cursor off the table
        wrap.refresh(0)

        local ns = vim.api.nvim_create_namespace('markdown_visual_wrap')
        local marks = vim.api.nvim_buf_get_extmarks(0, ns, { 0, 0 }, { -1, -1 },
            { details = true })
        local rows, hls = {}, {}
        local function take(chunks)
            local t = {}
            for _, ch in ipairs(chunks) do
                t[#t + 1] = ch[1]
                hls[#hls + 1] = vim.inspect(ch[2])
            end
            rows[#rows + 1] = table.concat(t)
        end
        for _, m in ipairs(marks) do
            if m[4].virt_text and m[4].virt_text_pos == 'overlay' then
                take(m[4].virt_text)
            end
            for _, row in ipairs(m[4].virt_lines or {}) do
                take(row)
            end
        end

        assert.is_true(#rows >= 5) -- top border, header, sep, data row, bottom
        local grid_w = vim.fn.strdisplaywidth(rows[1])
        for _, r in ipairs(rows) do
            assert.are.equal(grid_w, vim.fn.strdisplaywidth(r)) -- aligned grid
            assert.is_falsy(r:find('*', 1, true)) -- ** concealed
            assert.is_falsy(r:find('`', 1, true)) -- backticks concealed
        end
        local blob = table.concat(hls)
        assert.is_truthy(blob:find('markup%.strong'))
        assert.is_truthy(blob:find('markup%.raw'))
    end)

    it('MarkdownWrapToggle flips the global flag', function()
        wrap.setup()
        assert.is_true(vim.g.markdown_visual_wrap_enabled)
        vim.cmd('MarkdownWrapToggle')
        assert.is_false(vim.g.markdown_visual_wrap_enabled)
        vim.cmd('MarkdownWrapToggle')
        assert.is_true(vim.g.markdown_visual_wrap_enabled)
    end)
end)
