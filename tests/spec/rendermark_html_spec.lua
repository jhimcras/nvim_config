local html = require('rendermark.html')
local ns = vim.api.nvim_create_namespace('rendermark_html')

local function marks(row)
    return vim.api.nvim_buf_get_extmarks(0, ns, { row, 0 }, { row, -1 }, { details = true })
end

local function has(row, pred)
    for _, item in ipairs(marks(row)) do
        if pred(item[4]) then return item[4] end
    end
end

local function render(lines, cursor)
    vim.cmd('enew!')
    vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
    vim.bo.filetype = 'markdown'
    vim.api.nvim_win_set_cursor(0, { cursor or #lines, 0 })
    html.refresh(0, (cursor or #lines) - 1)
end

describe('rendermark HTML', function()
    it('collapses details under its summary and toggles it', function()
        html.setup()
        render({ '<details>', '<summary>Notes</summary>', 'body', '</details>', 'after' })
        local title = has(0, function(d) return d.virt_text_pos == 'overlay' end)
        assert.equals('▶ Notes', vim.trim(title.virt_text[1][1]))
        assert.is_truthy(has(2, function(d) return d.conceal_lines == '' end))
        vim.api.nvim_win_set_cursor(0, { 1, 0 })
        assert.is_true(html.toggle())
        assert.is_nil(has(2, function(d) return d.conceal_lines == '' end))
        local summary_tags = 0
        for _, item in ipairs(marks(1)) do
            if item[4].conceal == '' then summary_tags = summary_tags + 1 end
        end
        assert.equals(2, summary_tags)
        assert.is_truthy(has(3, function(d) return d.conceal == '' end))
        assert.equals('▼', vim.trim(has(0, function(d) return d.virt_text_pos == 'overlay' end).virt_text[1][1]))
    end)

    it('keeps an opened block expanded after inserting lines above it', function()
        render({ '<details>', '<summary>Notes</summary>', 'body', '</details>' })
        vim.api.nvim_win_set_cursor(0, { 1, 0 })
        html.toggle()
        vim.api.nvim_buf_set_lines(0, 0, 0, false, { 'intro' })
        html.refresh(0, 0)
        assert.is_nil(has(3, function(d) return d.conceal_lines == '' end))
        assert.equals('▼', vim.trim(has(1, function(d) return d.virt_text_pos == 'overlay' end).virt_text[1][1]))
    end)

    it('honors the open attribute and a later manual collapse', function()
        render({ '<details open>', 'body', '</details>' })
        assert.is_nil(has(1, function(d) return d.conceal_lines == '' end))
        vim.api.nvim_win_set_cursor(0, { 1, 0 })
        html.toggle()
        vim.api.nvim_buf_set_lines(0, 0, 0, false, { 'intro' })
        html.refresh(0, 0)
        assert.is_truthy(has(2, function(d) return d.conceal_lines == '' end))
    end)

    it('conceals style tags and highlights their contents', function()
        render({ '<mark>gold</mark> <u>under</u> <s>old</s> <del>gone</del>' })
        for _, group in ipairs({ 'RendermarkHtmlMark', 'RendermarkHtmlUnderline',
            'RendermarkHtmlStrike' }) do
            assert.is_truthy(has(0, function(d) return d.hl_group == group end))
        end
        local concealed = 0
        for _, item in ipairs(marks(0)) do
            if item[4].conceal == '' then concealed = concealed + 1 end
        end
        assert.equals(8, concealed)
    end)

    it('turns br into a display row and leaves code fences literal', function()
        render({ 'before<br>after', '```html', '<mark>literal</mark>', '```' })
        local br = has(0, function(d) return d.virt_lines ~= nil end)
        assert.equals('after', br.virt_lines[1][1][1])
        assert.is_nil(has(2, function(d) return d.conceal == '' end))
    end)

    it('keeps styling on the display row after br', function()
        render({ '<mark>before<br>after</mark>', 'tail' })
        local br = has(0, function(d) return d.virt_lines ~= nil end)
        assert.equals('after', br.virt_lines[1][1][1])
        assert.equals('RendermarkHtmlMark', br.virt_lines[1][1][2])
    end)

    it('leaves fenced HTML inside details literal', function()
        render({ '<details open>', '<summary>Notes</summary>', '```html',
            '<mark>literal</mark>', '```', '</details>' })
        assert.is_nil(has(3, function(d) return d.conceal == '' end))
    end)

    it('leaves inline code tags literal', function()
        render({ '`<mark>literal</mark>` <mark>real</mark>' })
        local concealed = 0
        for _, item in ipairs(marks(0)) do
            if item[4].conceal == '' then concealed = concealed + 1 end
        end
        assert.equals(2, concealed)
    end)

    it('renders HTML inside table cells without folding or breaking the grid', function()
        local wrap = require('rendermark.wrap')
        wrap.setup({ left_pad = 0, right_pad = 0 })
        render({ '| Kind | Value |', '| --- | --- |',
            '| <details><summary>Title</summary> body</details> | <mark>hot</mark><br><u>under</u> <s>old</s> <del>gone</del> |',
            'tail' }, 4)
        wrap.refresh(0)

        local wrap_ns = vim.api.nvim_create_namespace('markdown_visual_wrap')
        local marks = vim.api.nvim_buf_get_extmarks(0, wrap_ns, { 2, 0 }, { 2, -1 },
            { details = true })
        local rows, groups = {}, {}
        local function take(chunks)
            local text = {}
            for _, chunk in ipairs(chunks) do
                text[#text + 1] = chunk[1]
                local hl = chunk[2]
                if type(hl) == 'table' then
                    for _, group in ipairs(hl) do groups[group] = true end
                elseif hl then
                    groups[hl] = true
                end
            end
            rows[#rows + 1] = table.concat(text)
        end
        for _, item in ipairs(marks) do
            local detail = item[4]
            if detail.virt_text and detail.virt_text_pos == 'overlay' then take(detail.virt_text) end
        end
        for _, item in ipairs(marks) do
            local detail = item[4]
            for _, row in ipairs(detail.virt_lines or {}) do take(row) end
        end
        assert.is_true(#rows >= 3)
        assert.is_truthy(rows[1]:find('Title body', 1, true))
        assert.is_truthy(rows[1]:find('hot', 1, true))
        assert.is_falsy(rows[1]:find('under', 1, true))
        assert.is_truthy(rows[2]:find('under', 1, true))
        for _, row in ipairs(rows) do
            assert.is_falsy(row:find('<details>', 1, true))
            assert.is_falsy(row:find('<summary>', 1, true))
            assert.is_falsy(row:find('<br>', 1, true))
            assert.equals(vim.fn.strdisplaywidth(rows[1]), vim.fn.strdisplaywidth(row))
        end
        assert.is_true(groups.RendermarkHtmlMark)
        assert.is_true(groups.RendermarkHtmlUnderline)
        assert.is_true(groups.RendermarkHtmlStrike)
        assert.is_nil(has(2, function(d) return d.conceal_lines == '' end))
    end)

    it('skips concealed rows when moving down and up', function()
        render({ '<details>', '<summary>Notes</summary>', 'body', '</details>', 'after' }, 1)
        local win = vim.api.nvim_get_current_win()
        vim.api.nvim_win_set_cursor(win, { 2, 0 })
        assert.is_true(html.skip_hidden(win, 1))
        assert.equals(5, vim.fn.line('.'))
        vim.api.nvim_win_set_cursor(win, { 4, 0 })
        assert.is_true(html.skip_hidden(win, 5))
        assert.equals(1, vim.fn.line('.'))
    end)
end)
