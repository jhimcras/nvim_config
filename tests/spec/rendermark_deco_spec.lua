local deco = require('rendermark.deco')
local wrap_text = require('rendermark.wrap.text')

local function width_of(chunks)
    local w = 0
    for _, c in ipairs(chunks) do
        w = w + vim.fn.strdisplaywidth(c[1])
    end
    return w
end

describe('deco.code_width', function()
    it('floors at min_width for short code', function()
        assert.equals(50, deco.code_width({ 3, 10 }, 0))
    end)

    it('grows to the widest line plus padding on both sides', function()
        assert.equals(62, deco.code_width({ 20, 60 }, 0))
    end)

    it('never clamps to a window width', function()
        assert.equals(202, deco.code_width({ 200 }, 0))
    end)

    it('makes room for a long language label', function()
        assert.equals(62, deco.code_width({ 10 }, 60))
    end)
end)

describe('deco.code_bar', function()
    it('spans exactly the block width when blank', function()
        assert.equals(20, width_of(deco.code_bar(20, nil)))
    end)

    it('spans exactly the block width with a label', function()
        assert.equals(20, width_of(deco.code_bar(20, 'lua')))
    end)

    it('right-aligns the label one pad in from the right edge', function()
        local chunks = deco.code_bar(20, 'lua')
        assert.equals('lua', chunks[2][1])
        assert.equals('RendermarkCodeInfo', chunks[2][2])
        assert.equals(' ', chunks[3][1]) -- trailing pad
        assert.equals(16, #chunks[1][1]) -- 20 - pad(1) - #'lua'
    end)
end)

describe('deco.rule_chunks', function()
    it('fills the requested width', function()
        assert.equals(30, width_of(deco.rule_chunks(30)))
    end)

    it('never produces a negative-width rule', function()
        assert.equals(0, width_of(deco.rule_chunks(-5)))
    end)
end)

describe('deco.metrics', function()
    local saved
    before_each(function()
        saved = vim.g.rendermark_heading_indent
        vim.g.rendermark_heading_indent = nil
    end)
    after_each(function()
        vim.g.rendermark_heading_indent = saved
        deco.setup({}) -- drop any checkbox override, back to the module defaults
    end)

    it('reports the rendered checkbox prefix as glyph plus space', function()
        deco.setup({ checkbox = { unchecked = 'x', checked = 'v' } })
        assert.equals(2, deco.metrics().checkbox)
    end)

    it('counts the inline pad of a wider glyph into the checkbox prefix', function()
        -- A glyph string wider than one character is drawn as conceal + inline pad,
        -- so the rendered prefix grows with it (a double-width nerd glyph needs the
        -- extra column to keep the item text off it).
        deco.setup({ checkbox = { unchecked = 'x ', checked = 'v ' } })
        assert.equals(3, deco.metrics().checkbox)
    end)

    it('reports no heading indent while the global is off', function()
        assert.equals(0, deco.metrics().heading)
    end)

    it('turns the heading indent on via the global', function()
        vim.g.rendermark_heading_indent = true
        assert.equals(2, deco.metrics().heading)
    end)

    it('takes an explicit column count from the global', function()
        vim.g.rendermark_heading_indent = 4
        assert.equals(4, deco.metrics().heading)
    end)
end)

describe('deco.prefix_chunks', function()
    it('returns nil for a line that is not a quote', function()
        assert.is_nil(deco.prefix_chunks('- plain item', 2))
    end)

    it('repeats the bar so a wrapped quote stays connected', function()
        local chunks = deco.prefix_chunks('> quoted text', 2)
        assert.equals('▎', chunks[1][1])
        assert.equals('RendermarkQuote', chunks[1][2])
        assert.equals(2, width_of(chunks))
    end)

    it('repeats one bar per nesting level without widening the prefix', function()
        local text = '>> nested'
        local indent = wrap_text.compute_indent(text)
        local chunks = deco.prefix_chunks(text, indent)
        assert.equals(2, #vim.tbl_filter(function(c) return c[1] == '▎' end, chunks))
        assert.equals(indent, width_of(chunks))
    end)

    it('pads out to the requested indent', function()
        assert.equals(6, width_of(deco.prefix_chunks('> quoted', 6)))
    end)
end)

describe('deco rendering', function()
    local wrap = require('rendermark.wrap')
    local ns = vim.api.nvim_create_namespace('rendermark_deco')

    -- Decorations are drawn by wrap.refresh, which calls deco.render_range for
    -- every visible segment before it wraps the same rows.
    local function render(lines, cursor_lnum)
        pcall(vim.api.nvim_del_augroup_by_name, 'markdown_visual_wrap')
        pcall(vim.api.nvim_del_user_command, 'MarkdownWrapToggle')
        vim.cmd('enew')
        wrap.setup({ left_pad = 0, right_pad = 0 })
        vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
        vim.bo.filetype = 'markdown'
        vim.api.nvim_exec_autocmds('FileType', { pattern = 'markdown' })
        vim.api.nvim_win_set_cursor(0, { cursor_lnum or #lines, 0 })
        wrap.refresh(0)
    end

    local function marks_on(lnum)
        return vim.api.nvim_buf_get_extmarks(0, ns, { lnum, 0 }, { lnum, -1 },
            { details = true })
    end

    -- Total background width drawn on a code row: the inline pads plus the
    -- highlighted stretch of real text. Must equal the block width on every row.
    local function code_row_width(lnum)
        local line = vim.api.nvim_buf_get_lines(0, lnum, lnum + 1, false)[1] or ''
        local w = 0
        for _, m in ipairs(marks_on(lnum)) do
            local d, col = m[4], m[3]
            if d.virt_text and d.virt_text_pos == 'inline' then
                w = w + width_of(d.virt_text)
            elseif d.hl_group == 'RendermarkCode' and d.end_col then
                w = w + vim.fn.strdisplaywidth(line:sub(col + 1, d.end_col))
            end
        end
        return w
    end

    local function find(lnum, pred)
        for _, m in ipairs(marks_on(lnum)) do
            if pred(m[4], m[3]) then
                return m[4], m[3]
            end
        end
        return nil
    end

    before_each(function()
        vim.g.rendermark_heading_indent = nil
    end)

    it('conceals every "#" of a heading regardless of level', function()
        render({ '# One', '### Three', 'tail' })
        local d1, col1 = find(0, function(d) return d.conceal == '' end)
        assert.is_truthy(d1)
        assert.equals(0, col1)
        assert.equals(2, d1.end_col) -- '# '
        local d3 = find(1, function(d) return d.conceal == '' end)
        assert.is_truthy(d3)
        assert.equals(4, d3.end_col) -- '### '
    end)

    it('adds no indent for a heading while the global is off', function()
        render({ '## Two', 'tail' })
        assert.is_nil(find(0, function(d) return d.virt_text_pos == 'inline' end))
    end)

    it('indents a heading by level when the global is on', function()
        vim.g.rendermark_heading_indent = true
        render({ '## Two', 'tail' })
        local d = find(0, function(x) return x.virt_text_pos == 'inline' end)
        assert.is_truthy(d)
        assert.equals('  ', d.virt_text[1][1]) -- (level - 1) * 2 columns
    end)

    it('draws a thematic break as a full-width rule', function()
        render({ 'prose', '---', 'tail' })
        local d = find(1, function(x) return x.virt_text_pos == 'overlay' end)
        assert.is_truthy(d)
        assert.is_truthy(d.virt_text[1][1]:find('─'))
        assert.equals('RendermarkRule', d.virt_text[1][2])
        local win_width = vim.api.nvim_win_get_width(0)
            - vim.fn.getwininfo(vim.api.nvim_get_current_win())[1].textoff
        assert.equals(win_width, vim.fn.strdisplaywidth(d.virt_text[1][1]))
    end)

    it('collapses "- [ ] " to a glyph plus the surviving space', function()
        render({ '- [ ] todo', '- [x] done', 'tail' })
        -- the list marker goes entirely...
        local marker = find(0, function(d, col) return col == 0 and d.conceal == '' end)
        assert.is_truthy(marker)
        assert.equals(2, marker.end_col)
        -- ...and the glyph replaces '[ ]', leaving the source space at 5..6
        local box = find(0, function(d, col) return col == 2 end)
        assert.is_truthy(box)
        assert.equals(5, box.end_col)
        assert.equals(1, vim.fn.strchars(box.conceal)) -- conceal takes ONE character
        local checked = find(1, function(d, col) return col == 2 end)
        assert.are_not.equals(box.conceal, checked.conceal)
    end)

    it('draws the rest of the checkbox glyph inline, not into the conceal', function()
        -- The conceal holds one character, so a glyph configured with a trailing
        -- space keeps that space as an inline pad after the box.
        render({ '- [ ] todo', 'tail' })
        local pad = find(0, function(d, col) return col == 5 and d.virt_text end)
        assert.is_truthy(pad)
        assert.equals('inline', pad.virt_text_pos)
        assert.equals(' ', pad.virt_text[1][1])
    end)

    it('replaces the marker character of a deeply indented nested item', function()
        -- The grammar folds the extra indent into the marker node ('  - ') when a
        -- nested list is indented past its parent's continuation column; the
        -- conceal has to land on the '-', not on the space in front of it.
        render({ '- [ ] task', '    - sub of task', 'tail' })
        local d, col = find(1, function(x) return x.conceal ~= nil end)
        assert.is_truthy(d)
        assert.equals(4, col)
        assert.equals(5, d.end_col)
        assert.equals('○', d.conceal)
    end)

    it('keeps the indent of a deeply indented nested task item', function()
        render({ '- [ ] task', '    - [x] sub', 'tail' })
        local marker = find(1, function(d, col) return d.conceal == '' and col == 4 end)
        assert.is_truthy(marker)
        assert.equals(6, marker.end_col) -- '- ', with the four-space indent intact
    end)

    it('replaces only the bullet character, keeping the item column', function()
        render({ '- item', 'tail' })
        local d = find(0, function(x, col) return col == 0 end)
        assert.is_truthy(d)
        assert.equals(1, d.end_col) -- just the '-', not its trailing space
        assert.equals('●', d.conceal)
    end)

    it('leaves an ordered list marker alone', function()
        render({ '1. item', 'tail' })
        assert.is_nil(find(0, function(d) return d.conceal ~= nil end))
    end)

    it('bars every row of a multi-line quote, not just the first', function()
        render({ '> one', '> two', 'tail' })
        for _, lnum in ipairs({ 0, 1 }) do
            local d = find(lnum, function(x, col) return col == 0 end)
            assert.is_truthy(d)
            assert.equals('▎', d.conceal)
            assert.equals(1, d.end_col)
        end
    end)

    it('draws a code block at min_width with bars and a right-aligned language', function()
        render({ '```lua', 'local x = 1', '```', 'tail' })
        local top = find(1, function(d) return d.virt_lines and d.virt_lines_above end)
        assert.is_truthy(top)
        assert.equals(50, width_of(top.virt_lines[1]))
        assert.equals('lua', top.virt_lines[1][2][1])
        assert.equals('RendermarkCodeInfo', top.virt_lines[1][2][2])

        local bottom = find(1, function(d) return d.virt_lines and not d.virt_lines_above end)
        assert.is_truthy(bottom)
        assert.equals(50, width_of(bottom.virt_lines[1]))
        assert.equals(1, #bottom.virt_lines[1]) -- blank bar, no label

        assert.is_truthy(find(1, function(d) return d.hl_group == 'RendermarkCode' end))
        -- Left pad and right fill are both inline: an 'eol' fill would sit one
        -- unhighlighted column past the text and break the rectangle.
        local inlines = vim.tbl_filter(function(m)
            return m[4].virt_text_pos == 'inline'
        end, marks_on(1))
        assert.equals(2, #inlines)
        assert.equals(50, code_row_width(1))
    end)

    it('trades the bar for the raw fence row the cursor is on', function()
        -- The fence row is drawn again under the cursor, raw text and all, so it can
        -- be edited. A virt_line on top of it would add a row: the bar goes and the
        -- row is painted as an ordinary block row instead, keeping both the height
        -- and the rectangle.
        render({ '```lua', 'local x = 1', '```', 'tail' }, 1)
        assert.is_nil(find(1, function(d) return d.virt_lines and d.virt_lines_above end))
        assert.equals(50, code_row_width(0))
        -- The other bar is untouched.
        assert.is_truthy(find(1, function(d) return d.virt_lines and not d.virt_lines_above end))

        render({ '```lua', 'local x = 1', '```', 'tail' }, 3)
        assert.is_truthy(find(1, function(d) return d.virt_lines and d.virt_lines_above end))
        assert.is_nil(find(1, function(d) return d.virt_lines and not d.virt_lines_above end))
        assert.equals(50, code_row_width(2))
    end)

    it('repaints the fence row inside CursorMoved, not on the deferred refresh', function()
        -- The deferred refresh runs a frame after the redraw, which is the flicker:
        -- crossing a fence has to land in the same event as the cursor move.
        render({ '```lua', 'local x = 1', '```', 'tail' })
        vim.api.nvim_win_set_cursor(0, { 1, 0 })
        vim.api.nvim_exec_autocmds('CursorMoved', {})
        assert.is_nil(find(1, function(d) return d.virt_lines and d.virt_lines_above end))
        assert.equals(50, code_row_width(0))

        vim.api.nvim_win_set_cursor(0, { 2, 0 })
        vim.api.nvim_exec_autocmds('CursorMoved', {})
        assert.is_truthy(find(1, function(d) return d.virt_lines and d.virt_lines_above end))
        assert.equals(0, code_row_width(0))
    end)

    it('shows the raw fence row in insert mode too', function()
        render({ '```lua', 'local x = 1', '```', 'tail' }, 1)
        vim.api.nvim_exec_autocmds('CursorMovedI', {})
        -- Nothing covers the source: only the block background and its padding.
        assert.is_nil(find(0, function(d) return d.virt_text_pos == 'overlay' end))
        assert.is_nil(find(0, function(d) return d.conceal_lines end))
        assert.equals(50, code_row_width(0))
    end)

    it('starts the bars of an indented block on the content column', function()
        render({ '- item', '  ```lua', '  local x = 1', '  ```', 'tail' })
        local top = find(2, function(d) return d.virt_lines and d.virt_lines_above end)
        assert.is_truthy(top)
        assert.equals('  ', top.virt_lines[1][1][1])
        assert.is_nil(top.virt_lines[1][1][2]) -- unhighlighted: outside the block
        assert.equals(2 + 50, width_of(top.virt_lines[1]))
        local bottom = find(2, function(d) return d.virt_lines and not d.virt_lines_above end)
        assert.is_truthy(bottom)
        assert.equals(2 + 50, width_of(bottom.virt_lines[1]))
        assert.equals(50, code_row_width(2)) -- content lines up with the bars
    end)

    it('fills a blank row inside a block so the rectangle has no hole', function()
        render({ '```lua', 'local x = 1', '', 'local y = 2', '```', 'tail' })
        assert.equals(50, code_row_width(2))
    end)

    it('draws every content row at exactly the block width', function()
        local wide = string.rep('b', 70)
        render({ '```lua', 'a', wide, '', 'cc', '```', 'tail' })
        for lnum = 1, 4 do
            assert.equals(72, code_row_width(lnum))
        end
    end)

    it('widens a code block past the window rather than clamping', function()
        local long = 'local x = "' .. string.rep('y', 200) .. '"'
        render({ '```lua', long, '```', 'tail' })
        local top = find(1, function(d) return d.virt_lines and d.virt_lines_above end)
        assert.is_truthy(top)
        assert.equals(#long + 2, width_of(top.virt_lines[1]))
        assert.is_true(width_of(top.virt_lines[1]) > vim.api.nvim_win_get_width(0))
    end)

    it('leaves a plantuml block to the image renderer', function()
        render({ '```plantuml', '@startuml', '@enduml', '```', 'tail' })
        for lnum = 0, 3 do
            assert.equals(0, #marks_on(lnum))
        end
    end)

    it('dims a checked item and its whole sub-tree', function()
        render({ '- [x] done', '  more', '  - sub', 'tail' })
        -- the item's own text (past the checkbox), its lazy continuation and the
        -- nested list all carry the dim
        local d, col = find(0, function(x) return x.hl_group == 'Comment' end)
        assert.is_truthy(d)
        assert.equals(5, col) -- past the '[x]' the glyph replaces
        assert.equals(#'- [x] done', d.end_col)
        for _, lnum in ipairs({ 1, 2 }) do
            local m = find(lnum, function(x) return x.hl_group == 'Comment' end)
            assert.is_truthy(m)
            assert.equals(0, select(2, find(lnum,
                function(x) return x.hl_group == 'Comment' end)))
        end
    end)

    it('leaves an unchecked item undimmed', function()
        render({ '- [ ] todo', '  - sub', 'tail' })
        assert.is_nil(find(0, function(d) return d.hl_group == 'Comment' end))
        assert.is_nil(find(1, function(d) return d.hl_group == 'Comment' end))
    end)

    it('skips code block and table rows inside a checked item', function()
        render({
            '- [x] done',
            '  text',
            '',
            '  ```lua',
            '  local x = 1',
            '  ```',
            '',
            '  | a | b |',
            '  | - | - |',
            '  | 1 | 2 |',
            'tail',
        })
        assert.is_truthy(find(1, function(d) return d.hl_group == 'Comment' end))
        for _, lnum in ipairs({ 3, 4, 5, 7, 8, 9 }) do
            assert.is_nil(find(lnum, function(d) return d.hl_group == 'Comment' end))
        end
    end)

    it('renders a setext underline as a rule too, not just a standalone ---', function()
        -- 'prose' + '---' parses as a setext heading, so the dashes are a
        -- setext_h2_underline rather than a thematic_break; both must draw a rule.
        render({ 'prose', '---', 'tail', '', '---', '', 'end' })
        for _, lnum in ipairs({ 1, 4 }) do
            local d = find(lnum, function(x) return x.virt_text_pos == 'overlay' end)
            assert.is_truthy(d)
            assert.is_truthy(d.virt_text[1][1]:find('─'))
        end
    end)

    it('clears everything when wrap is disabled', function()
        render({ '# One', '- [ ] todo', 'tail' })
        assert.is_true(#marks_on(0) > 0)
        wrap.disable(0)
        assert.equals(0, #marks_on(0))
    end)
end)

describe('deco quote guard', function()
    local wrap = require('rendermark.wrap')
    local ns = vim.api.nvim_create_namespace('rendermark_deco')

    it('does not bar a ">" that is literal text inside an indented code block', function()
        pcall(vim.api.nvim_del_augroup_by_name, 'markdown_visual_wrap')
        pcall(vim.api.nvim_del_user_command, 'MarkdownWrapToggle')
        vim.cmd('enew')
        wrap.setup({ left_pad = 0, right_pad = 0 })
        vim.api.nvim_buf_set_lines(0, 0, -1, false, {
            'prose', '', '    > not a quote', '', 'tail' })
        vim.bo.filetype = 'markdown'
        vim.api.nvim_exec_autocmds('FileType', { pattern = 'markdown' })
        vim.api.nvim_win_set_cursor(0, { 5, 0 })
        wrap.refresh(0)
        assert.equals(0, #vim.api.nvim_buf_get_extmarks(0, ns, { 2, 0 }, { 2, -1 }, {}))
    end)
end)
