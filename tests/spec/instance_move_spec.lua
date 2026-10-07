local move = require 'nvim_config.instance.move'
local api = vim.api

describe('instance_move', function()
    local old_new, old_input
    local select_target
    local file

    before_each(function()
        vim.cmd('tabonly!')
        vim.cmd('only!')
        old_new = require'nvim_config.instance'.new
        old_input = vim.ui.input
        file = vim.fn.tempname() .. '.txt'
        vim.fn.writefile({ 'original' }, file)
        vim.cmd.edit(file)
    end)

    after_each(function()
        require'nvim_config.instance'.new = old_new
        vim.ui.input = old_input
        vim.cmd('tabonly!')
        vim.cmd('only!')
        vim.cmd('enew!')
        vim.fn.delete(file)
    end)

    it('keeps the source buffer if launching the destination fails', function()
        local buf = api.nvim_get_current_buf()
        select_target = function(cb) cb({ new = true }) end
        require'nvim_config.instance'.new = function() return false end
        move.move('buffer', select_target)
        assert.is_true(api.nvim_buf_is_valid(buf))
    end)

    it('saves before launching and removes the source buffer after success', function()
        local buf = api.nvim_get_current_buf()
        api.nvim_buf_set_lines(buf, 0, -1, false, { 'changed' })
        select_target = function(cb) cb({ new = true }) end
        vim.ui.input = function(opts, cb)
            assert.are.equal('Move 1 modified buffer (1 Save, 2 Ignore, 3 Cancel): ', opts.prompt)
            cb('1')
        end
        require'nvim_config.instance'.new = function(args)
            assert.are.same({ file }, args)
            assert.are.same({ 'changed' }, vim.fn.readfile(file))
            return true
        end
        move.move('buffer', select_target)
        assert.is_false(api.nvim_buf_is_valid(buf))
    end)

    it('leaves modified content alone when the user cancels', function()
        local buf = api.nvim_get_current_buf()
        api.nvim_buf_set_lines(buf, 0, -1, false, { 'changed' })
        select_target = function(cb) cb({ new = true }) end
        vim.ui.input = function(_, cb) cb('3') end
        require'nvim_config.instance'.new = function() error('must not launch') end
        move.move('buffer', select_target)
        assert.is_true(api.nvim_buf_is_valid(buf))
        assert.are.same({ 'original' }, vim.fn.readfile(file))
    end)

    it('treats an empty answer as cancel', function()
        local buf = api.nvim_get_current_buf()
        api.nvim_buf_set_lines(buf, 0, -1, false, { 'changed' })
        select_target = function(cb) cb({ new = true }) end
        vim.ui.input = function(_, cb) cb('') end
        require'nvim_config.instance'.new = function() error('must not launch') end
        move.move('buffer', select_target)
        assert.is_true(api.nvim_buf_is_valid(buf))
    end)

    it('moves without saving when the user chooses Ignore', function()
        local buf = api.nvim_get_current_buf()
        api.nvim_buf_set_lines(buf, 0, -1, false, { 'changed' })
        select_target = function(cb) cb({ new = true }) end
        vim.ui.input = function(_, cb) cb('2') end
        require'nvim_config.instance'.new = function() return true end
        move.move('buffer', select_target)
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
        select_target = function(cb) cb({ new = true }) end
        require'nvim_config.instance'.new = function(args)
            assert.are.same({ file }, args)
            return true
        end
        move.move('tab', select_target)
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
        select_target = function(cb) cb({ new = true }) end
        vim.ui.input = function(_, cb) cb('1') end
        require'nvim_config.instance'.new = function(args)
            assert.is_true(saved)
            assert.are.same({ url }, args)
            return true
        end
        move.move('buffer', select_target)
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
        select_target = function(cb) cb({ new = true }) end
        vim.ui.input = function(_, cb) cb('1') end
        require'nvim_config.instance'.new = function() error('must not launch') end
        move.move('buffer', select_target)
        assert.is_true(api.nvim_buf_is_valid(buf))
        package.loaded.oil = oil
        vim.fn.delete(dir, 'd')
    end)
    it('keeps modified content without prompting when target selection is cancelled', function()
        local buf = api.nvim_get_current_buf()
        api.nvim_buf_set_lines(buf, 0, -1, false, { 'changed' })
        vim.ui.input = function() error('must not confirm changes after picker cancellation') end
        require'nvim_config.instance'.new = function() error('must not launch after picker cancellation') end
        move.move('buffer', function(cb) cb(nil) end)
        assert.is_true(api.nvim_buf_is_valid(buf))
        assert.is_true(vim.bo[buf].modified)
        assert.are.same({ 'changed' }, api.nvim_buf_get_lines(buf, 0, -1, false))
        assert.are.same({ 'original' }, vim.fn.readfile(file))
    end)

    it('uses the relocated RPC receiver and deletes the source after remote success', function()
        local old_connect, old_request, old_close = vim.fn.sockconnect, vim.rpcrequest, vim.fn.chanclose
        local buf = api.nvim_get_current_buf()
        local closed = false
        vim.fn.sockconnect = function(kind, address, opts)
            assert.are.equal('pipe', kind)
            assert.are.equal('/tmp/destination', address)
            assert.is_true(opts.rpc)
            return 17
        end
        vim.rpcrequest = function(chan, method, code, args)
            assert.are.equal(17, chan)
            assert.are.equal('nvim_exec_lua', method)
            assert.are.equal('return require("nvim_config.instance.move").receive(...)', code)
            assert.are.same({ { file }, 'buffer' }, args)
            return true
        end
        vim.fn.chanclose = function(chan) assert.are.equal(17, chan); closed = true end
        local ok, err = pcall(move.move, 'buffer', function(cb) cb({ address = '/tmp/destination' }) end)
        vim.fn.sockconnect, vim.rpcrequest, vim.fn.chanclose = old_connect, old_request, old_close
        assert.is_true(ok, err)
        assert.is_true(closed)
        assert.is_false(api.nvim_buf_is_valid(buf))
    end)

end)
