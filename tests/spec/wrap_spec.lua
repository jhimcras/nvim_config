local wrap = require('wrap')

describe('wrap', function()
    before_each(function()
        pcall(vim.api.nvim_del_augroup_by_name, 'markdown_visual_wrap')
        pcall(vim.api.nvim_del_user_command, 'MarkdownWrapToggle')
        vim.cmd('enew')
        vim.bo.filetype = ''
        vim.wo.wrap = false
        vim.wo.linebreak = false
        vim.wo.breakindent = false
        vim.wo.breakindentopt = ''
        vim.o.showbreak = '↪'
        vim.bo.formatlistpat = '^\\s*old-list\\s\\+'
        vim.w.markdown_visual_wrap_breakindentopt = nil
        vim.b.markdown_visual_wrap_formatlistpat = nil
    end)

    it('has a setup function', function()
        assert.is_function(wrap.setup)
    end)

    it('applies markdown visual wrap options', function()
        wrap.setup({ min_text_width = 10 })

        vim.bo.filetype = 'markdown'
        vim.api.nvim_exec_autocmds('FileType', { pattern = 'markdown' })

        assert.is_true(vim.wo.wrap)
        assert.is_true(vim.wo.linebreak)
        assert.is_true(vim.wo.breakindent)
        assert.are.equal('', vim.wo.breakindentopt)
        assert.are.equal('  ', vim.wo.showbreak)
        assert.are.equal(" \t", vim.o.breakat)
        assert.are.equal([[^\s*\%(\d\+[.)]\|[-*+]\)\s\+]], vim.bo.formatlistpat)
        assert.is_true(vim.g.neopp_markdown_table_wrap)
    end)

    it('keeps continuation_indent deprecated and uses only explicit extra_shift', function()
        wrap.setup({ continuation_indent = 3, min_text_width = 10 })
        wrap.apply(0)

        assert.are.equal('', vim.wo.breakindentopt)
        assert.are.equal('  ', vim.wo.showbreak)

        wrap.setup({ extra_shift = 1, min_text_width = 10 })
        wrap.apply(0)

        assert.are.equal('shift:1', vim.wo.breakindentopt)
    end)

    it('reapplies markdown wrap options when entering a markdown window', function()
        wrap.setup()

        vim.bo.filetype = 'markdown'
        vim.wo.wrap = false
        vim.api.nvim_exec_autocmds('WinEnter', {})

        assert.is_true(vim.wo.wrap)
        assert.is_true(vim.wo.linebreak)
        assert.is_true(vim.wo.breakindent)
        assert.are.equal('', vim.wo.breakindentopt)
        assert.are.equal('  ', vim.wo.showbreak)
    end)

    it('matches markdown list prefixes with formatlistpat', function()
        wrap.setup()
        wrap.apply(0)

        local cases = {
            { '- item', '- ' },
            { '* item', '* ' },
            { '+ item', '+ ' },
            { '  - nested item', '  - ' },
            { '- [ ] task', '- ' },
            { '- [x] task', '- ' },
            { '- [X] task', '- ' },
            { '- [-] task', '- ' },
            { '1. numbered', '1. ' },
            { '12) numbered', '12) ' },
        }

        for _, case in ipairs(cases) do
            assert.are.equal(0, vim.fn.match(case[1], vim.bo.formatlistpat), case[1])
            assert.are.equal(case[2], vim.fn.matchstr(case[1], vim.bo.formatlistpat), case[1])
        end

        assert.are.equal(-1, vim.fn.match('not a list', vim.bo.formatlistpat))
    end)

    it('toggles visual wrap in the current window', function()
        wrap.setup()
        vim.wo.breakindentopt = 'shift:2,min:8'
        vim.o.showbreak = '↪'
        vim.bo.formatlistpat = '^\\s*old-list\\s\\+'
        wrap.apply(0)
        assert.is_true(vim.wo.wrap)

        wrap.toggle()
        assert.is_false(vim.wo.wrap)
        assert.is_false(vim.wo.linebreak)
        assert.is_false(vim.wo.breakindent)
        assert.are.equal('shift:2,min:8', vim.wo.breakindentopt)
        assert.are.equal('↪', vim.wo.showbreak)
        assert.are.equal('^\\s*old-list\\s\\+', vim.bo.formatlistpat)
    end)
end)
