local H = require('tests.spec.coderunner.helpers')
local exec = require('nvim_config.coderunner.exec')
local uv = vim.uv
local function run(argv, opts)
    local result
    exec.run_step(argv, opts, function(r) result = r end)
    H.wait(function() return result ~= nil end)
    return result
end
local function dead(pid)
    if not uv.kill(pid, 0) then return true end
    -- Linux may retain an orphan zombie until the container init reaps it.
    local f = io.open('/proc/' .. pid .. '/stat', 'r')
    if not f then return false end
    local stat = f:read('*a'); f:close()
    return stat:match('%) Z ') ~= nil
end

describe('coderunner exec', function()
    local root
    before_each(function() root = H.workspace() end)
    after_each(function() vim.fn.delete(root, 'rf') end)
    it('passes literal arguments, stdin, env overrides and cwd', function()
        local result = run(H.tool('dump', '; rm -rf', '$(x)', ''), {
            cwd = root, env = { CODERUNNER_TEST_VAR = 'ok' }, stdin = '한글\n',
        })
        assert.equals('success', result.status)
        local report = vim.json.decode(result.stdout)
        assert.same({ '; rm -rf', '$(x)', '' }, report.args)
        assert.equals(root, vim.fs.normalize(report.cwd)); assert.equals('ok', report.var)
        assert.equals('한글\n', report.stdin); assert.is_string(report.path)
    end)
    it('distinguishes failed exit, missing program and invalid cwd', function()
        local result = run(H.tool('exit', '7'))
        assert.equals('failed', result.status); assert.equals(7, result.code)
        assert.equals('not_found', run({ root .. '/missing-tool' }).status)
        assert.equals('spawn_failed', run({ root .. '/missing-tool' }, { cwd = root .. '/missing' }).status)
        assert.equals('spawn_failed', run(H.tool('exit', '0'), { cwd = H.write(root .. '/file', '') }).status)
    end)
    it('drains both large streams while retaining only the limit', function()
        local result = run(H.tool('flood', '1048577'), { max_output = 101 })
        assert.equals('success', result.status)
        assert.equals(string.rep('o', 101), result.stdout)
        assert.equals(string.rep('e', 101), result.stderr)
        assert.is_true(result.stdout_truncated); assert.is_true(result.stderr_truncated)
    end)
    it('reports timeout and retains output read before cancellation', function()
        local result = run(H.tool('emit-wait'), { timeout = 100 })
        assert.equals('before\n', result.stdout); assert.equals('warning\n', result.stderr)
        assert.equals('timeout', result.status)
        assert.is_true(result.elapsed >= 40)
    end)
    it('cancels immediately and reports signal exits without an exit code', function()
        local result
        local job = exec.run_step(H.tool('hang'), {}, function(r) result = r end)
        assert.is_true(job.cancel()); H.wait(function() return result ~= nil end)
        assert.equals('cancelled', result.status)
        -- Windows has no signals: a terminated process reports exit code 1 and no signal.
        if uv.os_uname().sysname == 'Windows_NT' then
            assert.equals(1, result.code)
            assert.is_nil(result.signal)
        else
            assert.is_nil(result.code)
            assert.is_number(result.signal)
        end
        assert.is_false(job.cancel())
        if uv.os_uname().sysname ~= 'Windows_NT' then
            result = nil
            job = exec.run_step(H.tool('hang'), {}, function(r) result = r end)
            uv.kill(job.pid, 'sigterm'); H.wait(function() return result ~= nil end)
            assert.equals('failed', result.status); assert.equals(15, result.signal)
            assert.is_nil(result.code)
        end
    end)
    it('kills descendants on cancellation, timeout and normal leader exit', function()
        for _, mode in ipairs({ 'cancel', 'timeout', 'exit' }) do
            local pidfile, result = root .. '/' .. mode, nil
            local job = exec.run_step(H.tool('spawn', pidfile, mode == 'exit' and 'exit' or 'wait'),
                { timeout = mode == 'timeout' and 500 or 3000 }, function(r) result = r end)
            H.wait(function() return uv.fs_stat(pidfile) ~= nil end)
            local pid = tonumber(vim.fn.readfile(pidfile)[1])
            if mode == 'cancel' then job.cancel() end
            H.wait(function() return result ~= nil end)
            H.wait(function() return dead(pid) end)
            assert.equals(mode == 'exit' and 'success' or mode == 'cancel' and 'cancelled' or 'timeout', result.status)
        end
    end)
    it('streams before completion and preserves output on explicit cancellation', function()
        local result, chunks = nil, { stdout = '', stderr = '' }
        local job = exec.run_step(H.tool('emit-wait'), { on_output = function(stream, chunk)
            chunks[stream] = chunks[stream] .. chunk
        end }, function(r) result = r end)
        H.wait(function() return chunks.stdout ~= '' and chunks.stderr ~= '' end)
        assert.is_nil(result); job.cancel()
        H.wait(function() return result ~= nil end)
        assert.equals('cancelled', result.status)
        assert.equals('before\n', result.stdout); assert.equals('warning\n', result.stderr)
    end)
    it('distinguishes exact limits from truncated streams and start permission errors', function()
        local exact = run(H.tool('flood', '10'), { max_output = 10 })
        assert.is_false(exact.stdout_truncated); assert.is_false(exact.stderr_truncated)
        local overflow = run(H.tool('flood', '11'), { max_output = 10 })
        assert.is_true(overflow.stdout_truncated); assert.is_true(overflow.stderr_truncated)
        if uv.os_uname().sysname ~= 'Windows_NT' then
            local path = H.write(root .. '/noexec', '#!/bin/sh\n')
            uv.fs_chmod(path, 384)
            assert.equals('spawn_failed', run({ path }).status)
        end
    end)
    it('normalizes invalid UTF-8 and preserves valid multi-byte sequences', function()
        local path = H.write(root .. '/bytes', '한글\n\255\192\128\237\160\128')
        local result = run(H.tool('echo', path))
        assert.equals('한글\n' .. string.rep('�', 6), result.stdout)
        assert.equals('�', exec.clean_utf8('\240'))
        assert.equals('😀', exec.clean_utf8('😀'))
    end)
end)
