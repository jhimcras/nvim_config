local launcher = require('launcher')
local util = require('util')

describe('launcher output batching', function()
    local original_async, callbacks, buf
    before_each(function()
        original_async = util.AsyncProcess
        util.AsyncProcess = function(_, _, _, opts)
            callbacks = opts
            return 1, function() end, function() end, {}
        end
        buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_win_set_buf(0, buf)
    end)
    after_each(function()
        util.AsyncProcess = original_async
        launcher.UnregisterProcess(buf)
        if vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_delete(buf, { force = true }) end
    end)
    local function launch()
        launcher.Launch('mock', {}, '.', nil, nil, nil, 'use', buf, nil, nil, {
            { pattern = '(file%.cpp):(%d+)', extract = {'filename', 'row'} },
        })
    end
    it('joins chunks and flushes pending output before exit', function()
        launch()
        callbacks.onread(nil, '\27[3')
        callbacks.onread(nil, '1mfile.cpp:42\27[0m\n')
        callbacks.onexit(0, 0)
        assert.are.same({'file.cpp:42', '---- End [code 0] [signal 0]'}, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
        assert.are.same({{lnum = 1, filename = 'file.cpp', row = '42'}}, vim.b[buf].launcher_matches)
        assert.is_false(vim.bo[buf].modifiable)
    end)
    it('makes matches available during execution without copying the buffer variable', function()
        launch()
        callbacks.onread(nil, 'file.cpp:42\n')
        assert.is_true(vim.wait(1000, function() return #launcher.GetMatches(buf) == 1 end))
        assert.are.same({}, vim.b[buf].launcher_matches)
        launcher.NextMatch()
        assert.are.equal(1, vim.api.nvim_win_get_cursor(0)[1])
    end)
    it('ignores pending callbacks from a replaced launch', function()
        launch()
        local old = callbacks
        old.onread(nil, 'old output\n')
        launch()
        callbacks.onread(nil, 'new output\n')
        old.onexit(0, 0)
        callbacks.onexit(0, 0)
        vim.wait(60, function() return false end)
        assert.are.same({'new output', '---- End [code 0] [signal 0]'}, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    end)
    it('ignores a flush after buffer deletion', function()
        launch()
        callbacks.onread(nil, 'output\n')
        vim.api.nvim_buf_delete(buf, {force = true})
        vim.wait(60, function() return false end)
    end)
end)

describe('ANSI span parsing', function()
    it('preserves byte offsets and unrecognized escape sequences', function()
        local cleaned, highlights = require('ansi_parser').parse_ansi('가\27[31mred\27[0m!\27[X')
        assert.are.equal('가red!\27[X', cleaned)
        assert.are.same({{0, 3, 'Normal'}, {3, 6, 'AnsiRed'}, {6, 10, 'Normal'}}, highlights)
    end)
end)
