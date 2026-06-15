describe('rendermark.rm_compat', function()
    before_each(function()
        vim.cmd('packadd render-markdown.nvim')
        package.loaded['rendermark.rm_compat'] = nil
        require('rendermark.rm_compat').setup()
    end)

    it('keeps list bullets visible for task-list items', function()
        local state = require('render-markdown.state')

        assert.is_true(state.config.checkbox.bullet)
        assert.are.equal(' ', state.config.checkbox.checked.icon)
        assert.are.equal(' ', state.config.checkbox.unchecked.icon)
    end)

    it('keeps heading icons and signs visible', function()
        local state = require('render-markdown.state')

        assert.are.same({ '󰲡 ', '󰲣 ', '󰲥 ', '󰲧 ', '󰲩 ', '󰲫 ' },
            state.config.heading.icons)
        assert.are.same({ '󰫎 ' }, state.config.heading.signs)
    end)
end)
