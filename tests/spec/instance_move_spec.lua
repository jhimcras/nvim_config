local move = require 'nvim_config.instance_move'
local api = vim.api

describe('instance_move', function()
    local old_picker, old_new, old_input
    local file

    before_each(function()
        vim.cmd('tabonly!')
        vim.cmd('only!')
        old_picker = package.loaded['nvim_config.plugins.tele']
        old_new = require'nvim_config.instance'.new
        old_input = vim.ui.input
        file = vim.fn.tempname() .. '.txt'
        vim.fn.writefile({ 'original' }, file)
        vim.cmd.edit(file)
    end)

    after_each(function()
        package.loaded['nvim_config.plugins.tele'] = old_picker
        require'nvim_config.instance'.new = old_new
        vim.ui.input = old_input
        vim.cmd('tabonly!')
        vim.cmd('only!')
        vim.cmd('enew!')
        vim.fn.delete(file)
    end)

    it('keeps the source buffer if launching the destination fails', function()
        local buf = api.nvim_get_current_buf()
        package.loaded['nvim_config.plugins.tele'] = { InstanceTargets = function(cb) cb({ new = true }) end }
        require'nvim_config.instance'.new = function() return false end
        move.move('buffer')
        assert.is_true(api.nvim_buf_is_valid(buf))
    end)

    it('saves before launching and removes the source buffer after success', function()
        local buf = api.nvim_get_current_buf()
        api.nvim_buf_set_lines(buf, 0, -1, false, { 'changed' })
        package.loaded['nvim_config.plugins.tele'] = { InstanceTargets = function(cb) cb({ new = true }) end }
        vim.ui.input = function(opts, cb)
            assert.are.equal('Move 1 modified buffer (1 Save, 2 Ignore, 3 Cancel): ', opts.prompt)
            cb('1')
        end
        require'nvim_config.instance'.new = function(args)
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
        package.loaded['nvim_config.plugins.tele'] = { InstanceTargets = function(cb) cb({ new = true }) end }
        vim.ui.input = function(_, cb) cb('3') end
        require'nvim_config.instance'.new = function() error('must not launch') end
        move.move('buffer')
        assert.is_true(api.nvim_buf_is_valid(buf))
        assert.are.same({ 'original' }, vim.fn.readfile(file))
    end)

    it('treats an empty answer as cancel', function()
        local buf = api.nvim_get_current_buf()
        api.nvim_buf_set_lines(buf, 0, -1, false, { 'changed' })
        package.loaded['nvim_config.plugins.tele'] = { InstanceTargets = function(cb) cb({ new = true }) end }
        vim.ui.input = function(_, cb) cb('') end
        require'nvim_config.instance'.new = function() error('must not launch') end
        move.move('buffer')
        assert.is_true(api.nvim_buf_is_valid(buf))
    end)

    it('moves without saving when the user chooses Ignore', function()
        local buf = api.nvim_get_current_buf()
        api.nvim_buf_set_lines(buf, 0, -1, false, { 'changed' })
        package.loaded['nvim_config.plugins.tele'] = { InstanceTargets = function(cb) cb({ new = true }) end }
        vim.ui.input = function(_, cb) cb('2') end
        require'nvim_config.instance'.new = function() return true end
        move.move('buffer')
        assert.is_false(api.nvim_buf_is_valid(buf))
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
        package.loaded['nvim_config.plugins.tele'] = { InstanceTargets = function(cb) cb({ new = true }) end }
        require'nvim_config.instance'.new = function(args)
            assert.are.same({ file }, args)
            return true
        end
        move.move('tab')
        assert.are.equal(1, vim.fn.tabpagenr('$'))
        assert.is_false(api.nvim_buf_is_valid(buf))
    end)

    it('moves a modified local Oil buffer after saving', function()
        local oil = package.loaded.oil
        local dir = vim.fn.tempname()
        vim.fn.mkdir(dir, 'p')
        local url = 'oil://' .. dir .. '/'
        vim.cmd.enew()
        local buf = api.nvim_get_current_buf()
        api.nvim_buf_set_name(buf, url)
        vim.bo[buf].filetype = 'oil'
        vim.bo[buf].buftype = 'acwrite'
        api.nvim_buf_set_lines(buf, 0, -1, false, { 'changed' })
        local saved = false
        package.loaded.oil = {
            get_current_dir = function(got) assert.are.equal(buf, got); return dir end,
            save = function(_, cb) saved = true; cb(nil) end,
        }
        package.loaded['nvim_config.plugins.tele'] = { InstanceTargets = function(cb) cb({ new = true }) end }
        vim.ui.input = function(_, cb) cb('1') end
        require'nvim_config.instance'.new = function(args)
            assert.is_true(saved)
            assert.are.same({ url }, args)
            return true
        end
        move.move('buffer')
        assert.is_false(api.nvim_buf_is_valid(buf))
        package.loaded.oil = oil
        vim.fn.delete(dir, 'd')
    end)

    it('keeps a modified Oil buffer when saving fails', function()
        local oil = package.loaded.oil
        local dir = vim.fn.tempname()
        vim.fn.mkdir(dir, 'p')
        vim.cmd.enew()
        local buf = api.nvim_get_current_buf()
        api.nvim_buf_set_name(buf, 'oil://' .. dir .. '/')
        vim.bo[buf].filetype = 'oil'
        vim.bo[buf].buftype = 'acwrite'
        api.nvim_buf_set_lines(buf, 0, -1, false, { 'changed' })
        package.loaded.oil = {
            get_current_dir = function() return dir end,
            save = function(_, cb) cb('Canceled') end,
        }
        package.loaded['nvim_config.plugins.tele'] = { InstanceTargets = function(cb) cb({ new = true }) end }
        vim.ui.input = function(_, cb) cb('1') end
        require'nvim_config.instance'.new = function() error('must not launch') end
        move.move('buffer')
        assert.is_true(api.nvim_buf_is_valid(buf))
        package.loaded.oil = oil
        vim.fn.delete(dir, 'd')
    end)
end)
