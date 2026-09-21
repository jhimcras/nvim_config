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
end)
