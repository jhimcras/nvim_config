local view = require('nvim_config.coderunner.result_view')
local api = vim.api

describe('coderunner result view', function()
    after_each(function() view.release(9001) end)
    it('closes with q, reopens the retained result and releases its buffer', function()
        local job = { id = 9001, status = 'success', result = { stdout = 'hello', stderr = 'warning',
            code = 0, elapsed = 12, stdout_truncated = true, artifacts = { '/tmp/image.png' } } }
        local v = view.open(job)
        assert.is_false(vim.bo[v.buf].modifiable)
        local text = table.concat(api.nvim_buf_get_lines(v.buf, 0, -1, false), '\n')
        assert.matches('stdout [truncated]', text, 1, true); assert.matches('/tmp/image.png', text, 1, true)
        api.nvim_buf_call(v.buf, function() vim.fn.maparg('q', 'n', false, true).callback() end)
        assert.is_false(api.nvim_win_is_valid(v.win))
        assert.equals(v.buf, view.open(job).buf)
        view.release(job.id); assert.is_false(api.nvim_buf_is_valid(v.buf))
        assert.is_nil(view.open(nil))
    end)
    it('normalizes CRLF in streaming and final displays without changing results', function()
        local job = { id = 9001, status = 'running', stdout = 'one\r\ntwo\r\n', stderr = 'warn\r\n' }
        local v = view.open(job)
        local function check()
            local text = table.concat(api.nvim_buf_get_lines(v.buf, 0, -1, false), '\n')
            assert.matches('one\ntwo\n', text, 1, true)
            assert.matches('warn\n', text, 1, true)
            assert.is_nil(text:find('\r', 1, true))
        end
        check()
        job.result = { stdout = job.stdout, stderr = job.stderr }
        job.status = 'success'
        view.update(job)
        check()
        assert.equals('one\r\ntwo\r\n', job.result.stdout)
        assert.equals('warn\r\n', job.result.stderr)
        assert.equals(job.stdout, job.result.stdout)
    end)
    it('final results always win over late streaming updates', function()
        local job = { id = 9001, status = 'running', stdout = 'partial', stderr = '' }
        local v = view.open(job)
        job.status, job.result = 'success', { stdout = 'final', stderr = '' }
        view.update(job)
        job.stdout = 'late partial'; view.update(job)
        local text = table.concat(api.nvim_buf_get_lines(v.buf, 0, -1, false), '\n')
        assert.matches('final', text); assert.is_nil(text:find('late partial', 1, true))
    end)
end)
