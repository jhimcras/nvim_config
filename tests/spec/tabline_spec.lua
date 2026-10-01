local tabline = require('tabline')
tabline.setup()

local function visible_tabs(line)
    local n = 0
    for _ in line:gmatch('%%%d+T') do n = n + 1 end
    return n
end

describe('tabline', function()
    before_each(function()
        vim.o.columns = 100
        vim.cmd('tabonly')
        for i = 1, 12 do
            vim.cmd('tabnew tabline_spec_' .. i)
        end
    end)

    after_each(function()
        vim.cmd('tabonly')
    end)

    it('fills the line when the last tab is selected', function()
        vim.cmd('tablast')
        local line = tabline.TabLine()
        -- each tab is ~35 cells with its project root, so at least two fit in 100 columns
        assert.is_true(visible_tabs(line) >= 2)
    end)

    it('does not collapse to the last tab after leaving and re-entering it', function()
        vim.cmd('tablast')
        tabline.TabLine()
        vim.cmd('tabfirst')
        tabline.TabLine()
        vim.cmd('tablast')
        assert.is_true(visible_tabs(tabline.TabLine()) >= 2)
    end)

    it('re-expands after the window widens', function()
        vim.cmd('tablast')
        tabline.TabLine()
        vim.o.columns = 300
        assert.is_true(visible_tabs(tabline.TabLine()) > 4)
    end)

    -- The tab part (everything before the right-aligned session name) must fit
    -- the line, or the width math disagrees with the rendered tab gaps.
    local function tabs_width(line)
        local tabs = line:match('^(.-)%%#MoreMsg#%%=')
        return vim.api.nvim_eval_statusline(tabs, { use_tabline = true, maxwidth = 1000 }).width
    end

    it('separates each visible tab with a gap', function()
        vim.cmd('tabfirst')
        local line = tabline.TabLine()
        local _, rights = line:gsub('%%#TabLineEdge%d+# ', '')
        assert.are.equal(visible_tabs(line), rights)
        assert.is_truthy(line:find('%%#TabLine1# 1 .-%%#TabLineEdge1# '))
    end)

    it('fits the line with overflow indicators on either side', function()
        vim.cmd('tabfirst')
        assert.is_true(tabs_width(tabline.TabLine()) <= vim.o.columns)
        vim.cmd('tablast')
        assert.is_true(tabs_width(tabline.TabLine()) <= vim.o.columns)
        -- current tab scrolled out on the left
        vim.cmd('tabnext 2')
        tabline.TabLine()
        tabline.tab_scroll(6)
        assert.is_true(tabs_width(vim.go.tabline) <= vim.o.columns)
        -- current tab scrolled out on the right
        vim.cmd('tablast')
        tabline.TabLine()
        tabline.tab_scroll(-12)
        assert.is_true(tabs_width(vim.go.tabline) <= vim.o.columns)
    end)

    it('links the first tab highlights at setup, before any TabEnter', function()
        vim.cmd('tabonly')
        vim.api.nvim_set_hl(0, 'TabLine1', {})
        vim.api.nvim_set_hl(0, 'TabLineEdge1', {})
        tabline.setup()
        assert.are.equal('TabLineTabSel', vim.api.nvim_get_hl(0, { name = 'TabLine1' }).link)
        assert.are.equal('TabLineTabSelEdge', vim.api.nvim_get_hl(0, { name = 'TabLineEdge1' }).link)
    end)

    it('repaints on VimResized without an explicit TabLine call', function()
        vim.cmd('tablast')
        tabline.TabLine()
        vim.o.columns = 300
        vim.api.nvim_exec_autocmds('VimResized', {})
        assert.is_true(visible_tabs(vim.o.tabline) > 4)
    end)
end)
