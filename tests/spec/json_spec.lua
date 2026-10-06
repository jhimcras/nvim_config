local json = require('nvim_config.json')

describe('json.lua jq range edits', function()
    local buf, previous, original_systemlist, original_notify, original_v, call, notifications

    before_each(function()
        previous = vim.api.nvim_get_current_buf()
        buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_set_current_buf(buf)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'before', '{"a":1}', 'after' })
        original_systemlist, original_notify = vim.fn.systemlist, vim.notify
        original_v = vim.v
        -- v:shell_error is read-only; override its Lua view for the jq adapter.
        vim.v = setmetatable({ shell_error = 0 }, { __index = original_v })
        notifications = {}
        vim.notify = function(message, level) notifications[#notifications + 1] = { message, level } end
        vim.fn.systemlist = function(args, input)
            call = { args = args, input = input }
            return { '{', '  "a": 1', '}' }
        end
    end)

    after_each(function()
        vim.fn.systemlist, vim.notify = original_systemlist, original_notify
        vim.v = original_v
        vim.api.nvim_set_current_buf(previous)
        vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it('pretty-prints only the requested inclusive line range', function()
        json.pretty(2, 2)
        assert.are.same({ args = { 'jq', '.' }, input = '{"a":1}' }, call)
        assert.are.same({ 'before', '{', '  "a": 1', '}', 'after' },
            vim.api.nvim_buf_get_lines(buf, 0, -1, false))
        assert.are.same({}, notifications)
    end)

    it('passes multiline JSON to compact mode as one input', function()
        vim.api.nvim_buf_set_lines(buf, 1, 2, false, { '{', '"a": 1', '}' })
        vim.fn.systemlist = function(args, input)
            call = { args = args, input = input }
            return { '{"a":1}' }
        end
        json.oneline(2, 4)
        assert.are.same({ args = { 'jq', '-c', '.' }, input = '{\n"a": 1\n}' }, call)
        assert.are.same({ 'before', '{"a":1}', 'after' }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    end)

    it('keeps the buffer unchanged and reports jq errors', function()
        vim.fn.systemlist = function()
            vim.v.shell_error = 4
            return { 'parse error', 'invalid JSON' }
        end
        vim.bo[buf].modified = false
        json.pretty(2, 2)
        assert.are.same({ 'before', '{"a":1}', 'after' }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
        assert.is_false(vim.bo[buf].modified)
        assert.are.same({ { 'parse error\ninvalid JSON', vim.log.levels.ERROR } }, notifications)
    end)
end)
