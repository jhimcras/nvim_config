local checkbox = require('nvim_config.rendermark.checkbox')

describe('rendermark/checkbox.lua list edits', function()
    local buf, previous

    before_each(function()
        previous = vim.api.nvim_get_current_buf()
        buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_set_current_buf(buf)
        checkbox.setup()
    end)

    after_each(function()
        vim.api.nvim_set_current_buf(previous)
        vim.api.nvim_buf_delete(buf, { force = true })
        vim.api.nvim_del_augroup_by_name('rendermark_checkbox')
    end)

    local function toggle(lines, first, last)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
        vim.api.nvim_buf_set_mark(buf, '<', first or 1, 0, {})
        vim.api.nvim_buf_set_mark(buf, '>', last or #lines, 0, {})
        checkbox.toggle_visual()
        return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    end

    it('toggles checked and unchecked markers while preserving indentation and content', function()
        assert.are.same({ '  - [x] 한글', '* [ ] done', '+ [ ] upper' },
            toggle({ '  - [ ] 한글', '* [x] done', '+ [X] upper' }))
    end)

    it('adds an unchecked box to bullet and numbered items and leaves prose unchanged', function()
        assert.are.same({ '- [ ] plain', '12. [ ] numbered', '3) [ ] item', '# heading', 'prose' },
            toggle({ '- plain', '12. numbered', '3) item', '# heading', 'prose' }))
    end)

    it('edits only the visual range', function()
        assert.are.same({ '- first', '- [x] second', '- third' },
            toggle({ '- first', '- [ ] second', '- third' }, 2, 2))
    end)

    it('installs a normal-mode callback for Markdown but does not map plain text', function()
        vim.bo[buf].filetype = 'text'
        assert.are.equal('', vim.fn.maparg('<C-Space>', 'n'))
        vim.bo[buf].filetype = 'markdown'
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '- [ ] mapped' })
        vim.fn.maparg('<C-Space>', 'n', false, true).callback()
        assert.are.equal('- [x] mapped', vim.api.nvim_get_current_line())
    end)
end)
