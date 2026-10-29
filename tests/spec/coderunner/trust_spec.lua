local T = require('nvim_config.coderunner.trust')
local H = require('tests.spec.coderunner.helpers')
local valid = "return {runners={py={match={'py'},cmd={'python','{file}'}}}}"

describe('coderunner trust', function()
    local root, file, secure_read, secure_trust, calls
    before_each(function()
        root = H.workspace()
        file = root .. '/.coderunner.lua'
        secure_read, secure_trust = vim.secure.read, vim.secure.trust
        calls = 0
        vim.secure.read = function(path)
            calls = calls + 1
            local f = assert(io.open(path, 'rb'))
            local bytes = f:read('*a'); f:close()
            return bytes
        end
    end)
    after_each(function()
        vim.secure.read, vim.secure.trust = secure_read, secure_trust
        vim.fn.delete(root, 'rf')
    end)

    it('does not prompt or evaluate configuration during status/automatic resolution', function()
        H.write(file, "vim.g.coderunner_evaluated = true; " .. valid)
        assert.equals('unloaded', T.status(root).state)
        local cfg, status = require('nvim_config.coderunner').resolve(root, false)
        assert.equals('unloaded', status.state)
        assert.same({}, cfg.runners)
        assert.is_nil(vim.g.coderunner_evaluated)
        assert.equals(0, calls)
    end)

    it('fails closed when the configuration path is a directory', function()
        vim.fn.mkdir(file)
        local status = T.status(root)
        assert.equals('unreadable', status.state)
        assert.is_false(T.allowed(status, 'global', 'renderers', true))
        assert.equals(0, calls)
    end)

    it('loads only secure.read approved bytes and caches hash and origin', function()
        H.write(file, valid)
        local status = T.load(root)
        assert.equals('loaded', status.state)
        assert.equals(vim.fn.sha256(valid), status.hash)
        assert.equals('workspace', status.config.runners.py.source)
        assert.equals('loaded', T.status(root).state)
        assert.equals(1, calls)
        require('nvim_config.coderunner').resolve(root, true)
        assert.equals(1, calls)
    end)

    it('refuses denied files without executing their Lua', function()
        H.write(file, "error('must not run')")
        vim.secure.read = function() calls = calls + 1; return nil end
        assert.equals('denied', T.load(root).state)
        assert.is_nil(T.status(root).config)
        assert.equals(1, calls)
        assert.is_false(T.allowed(T.status(root), 'workspace', 'runners', false))
    end)

    it('invalidates same-size changed contents before subsequent use', function()
        H.write(file, valid)
        T.load(root)
        H.write(file, valid:gsub('python', 'PYTHON'))
        assert.equals('unloaded', T.status(root).state)
        assert.is_nil(T.status(root).config)
        assert.equals(1, calls)
        local _, status = require('nvim_config.coderunner').resolve(root, true)
        assert.equals('loaded', status.state)
        assert.equals(2, calls)
        vim.fn.delete(file)
        assert.equals('absent', T.status(root).state)
    end)

    it('rejects syntax/runtime/non-table errors and retains valid sibling entries', function()
        for _, bytes in ipairs({ 'return {', "error('bad config')", 'return 1' }) do
            H.write(file, bytes)
            local status = T.load(root)
            assert.equals('invalid', status.state)
            assert.is_nil(status.config)
            assert.equals('error', status.diagnostics[1].level)
        end
        H.write(file, "return {runners={bad=false, good={match={'py'},cmd={'python'}}}}")
        local status = T.load(root)
        assert.equals('loaded', status.state)
        assert.is_false(status.config.runners.bad)
        assert.is_table(status.config.runners.good)
    end)

    it('rejects a file changed during approval or evaluation', function()
        H.write(file, valid)
        vim.secure.read = function()
            H.write(file, 'return {}')
            return valid
        end
        assert.equals('unloaded', T.load(root).state)
        assert.is_nil(T.status(root).config)
        vim.secure.read = function()
            return "local f=assert(io.open(" .. string.format('%q', file) .. ",'wb')); f:write('return {}'); f:close(); return {}"
        end
        -- Match disk to the approved code, then let the code mutate itself.
        H.write(file, vim.secure.read())
        assert.equals('unloaded', T.load(root).state)
        assert.is_nil(T.status(root).config)
    end)

    it('revokes through Neovim and clears memory even when revocation fails', function()
        H.write(file, valid)
        T.load(root)
        vim.secure.trust = function(opts)
            assert.same({ action = 'remove', path = file }, opts)
            return false, 'test failure'
        end
        assert.is_false(T.untrust(root))
        assert.equals('unloaded', T.status(root).state)
    end)

    it('applies every source/state/request permission combination', function()
        for _, state in ipairs({ 'absent', 'unloaded', 'denied', 'invalid', 'unreadable', 'loaded' }) do
            for _, kind in ipairs({ 'runners', 'renderers' }) do
                for _, batch in ipairs({ false, true }) do
                    assert.equals(state == 'loaded', T.allowed({ state = state }, 'workspace', kind, batch))
                    local expected = kind ~= 'renderers' or not batch or state == 'loaded' or state == 'absent'
                    assert.equals(expected, T.allowed({ state = state }, 'global', kind, batch))
                end
            end
        end
    end)

    it('isolates workspaces and registers idempotent explicit commands', function()
        local runner = require('nvim_config.coderunner')
        runner.setup({})
        runner.setup({})
        for _, name in ipairs({ 'CodeRunnerLoad', 'CodeRunnerTrust', 'CodeRunnerUntrust' }) do
            assert.equals(2, vim.fn.exists(':' .. name))
        end
        H.write(file, valid)
        T.load(root)
        local other = H.workspace()
        assert.equals('absent', T.status(other).state)
        vim.fn.delete(other, 'rf')
    end)
end)
