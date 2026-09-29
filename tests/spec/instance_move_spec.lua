local move = require 'instance_move'
local api = vim.api

describe('instance_move', function()
    local old_picker, old_new, old_select
    local file

    before_each(function()
        vim.cmd('tabonly!')
        vim.cmd('only!')
        old_picker = package.loaded['plugins.tele']
        old_new = require'instance'.new
        old_select = vim.ui.select
        file = vim.fn.tempname() .. '.txt'
        vim.fn.writefile({ 'original' }, file)
        vim.cmd.edit(file)
    end)

    after_each(function()
        package.loaded['plugins.tele'] = old_picker
        require'instance'.new = old_new
        vim.ui.select = old_select
        vim.cmd('tabonly!')
        vim.cmd('only!')
        vim.cmd('enew!')
        vim.fn.delete(file)
    end)

    it('keeps the source buffer if launching the destination fails', function()
        local buf = api.nvim_get_current_buf()
        package.loaded['plugins.tele'] = { InstanceTargets = function(cb) cb({ new = true }) end }
        require'instance'.new = function() return false end
        move.move('buffer')
        assert.is_true(api.nvim_buf_is_valid(buf))
    end)

    it('saves before launching and removes the source buffer after success', function()
        local buf = api.nvim_get_current_buf()
        api.nvim_buf_set_lines(buf, 0, -1, false, { 'changed' })
        package.loaded['plugins.tele'] = { InstanceTargets = function(cb) cb({ new = true }) end }
        vim.ui.select = function(_, _, cb) cb('Save') end
        require'instance'.new = function(args)
            assert.are.same({ file }, args)
            assert.are.same({ 'changed' }, vim.fn.readfile(file))
            return true
        end
        move.move('buffer')
        assert.is_false(api.nvim_buf_is_valid(buf))
    end)

    it('leaves modified content alone when the user cancels', function()
        local buf = api.nvim_get_current_buf()
        api.nvim_buf_set_lines(buf, 0, -1, false, { 'changed' })
        package.loaded['plugins.tele'] = { InstanceTargets = function(cb) cb({ new = true }) end }
        vim.ui.select = function(_, _, cb) cb('Cancel') end
        require'instance'.new = function() error('must not launch') end
        move.move('buffer')
        assert.is_true(api.nvim_buf_is_valid(buf))
        assert.are.same({ 'original' }, vim.fn.readfile(file))
    end)

    it('opens transferred tab files in one tab with two windows', function()
        local second = vim.fn.tempname() .. '.txt'
        vim.fn.writefile({ 'second' }, second)
        local previous_tabs = vim.fn.tabpagenr('$')
        assert.is_true(move.receive({ file, second }, 'tab'))
        assert.are.equal(previous_tabs + 1, vim.fn.tabpagenr('$'))
        assert.are.equal(2, #api.nvim_tabpage_list_wins(0))
        vim.fn.delete(second)
    end)

    it('moves the only tab and leaves an empty tab in the source', function()
        local buf = api.nvim_get_current_buf()
        package.loaded['plugins.tele'] = { InstanceTargets = function(cb) cb({ new = true }) end }
        require'instance'.new = function(args)
            assert.are.same({ file }, args)
            return true
        end
        move.move('tab')
        assert.are.equal(1, vim.fn.tabpagenr('$'))
        assert.is_false(api.nvim_buf_is_valid(buf))
    end)
end)
