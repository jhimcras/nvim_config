local registry = require('nvim_config.launcher.registry')

describe('launcher/registry.lua process ownership', function()
    local original_jobstop

    before_each(function()
        original_jobstop = vim.fn.jobstop
        -- Keep the table identity shared with launcher.running_processes.
        for key in pairs(registry.processes) do registry.unregister(key) end
    end)

    after_each(function()
        vim.fn.jobstop = original_jobstop
        for key in pairs(registry.processes) do registry.unregister(key) end
    end)

    it('lists buffer and external keys without mutating registered metadata', function()
        local info = { type = 'general', obj = 'build' }
        registry.register(12, info)
        registry.register('external', { type = 'external', pid = 42 })
        local by_key = {}
        for _, process in ipairs(registry.list()) do by_key[process.key] = process end
        assert.are.same({ type = 'general', obj = 'build', key = 12 }, by_key[12])
        assert.are.equal(42, by_key.external.pid)
        by_key[12].obj = 'changed'
        assert.are.equal('build', info.obj)
        assert.is_nil(info.key)
    end)

    it('replaces metadata for a reused key and unregisters without stopping it', function()
        local stops = 0
        registry.register(12, { terminate = function() stops = stops + 1 end })
        registry.register(12, { obj = 'replacement' })
        assert.are.equal('replacement', registry.processes[12].obj)
        registry.unregister(12)
        assert.are.same({}, registry.list())
        assert.are.equal(0, stops)
    end)

    it('stops terminal jobs through jobstop even when a terminate callback exists', function()
        local stopped
        vim.fn.jobstop = function(job) stopped = job end
        registry.register(12, { type = 'terminal', job_id = 77,
            terminate = function() error('terminal must use jobstop') end })
        registry.terminate(12)
        assert.are.equal(77, stopped)
        assert.is_nil(registry.processes[12])
    end)

    it('sends SIGTERM once through the callback and removes the process', function()
        local signals = {}
        registry.register('grep', { terminate = function(signal) signals[#signals + 1] = signal end })
        registry.terminate('grep')
        registry.terminate('grep')
        assert.are.same({ 15 }, signals)
        assert.is_nil(registry.processes.grep)
    end)

    it('falls back to an open libuv handle when no callback exists', function()
        local signal
        local handle = { is_closing = function() return false end,
            kill = function(_, value) signal = value end }
        registry.register('external', { handle = handle })
        registry.terminate('external')
        assert.are.equal(15, signal)
        assert.is_nil(registry.processes.external)
    end)

    it('removes a closing handle without trying to kill it', function()
        registry.register('external', { handle = {
            is_closing = function() return true end,
            kill = function() error('already closing') end,
        } })
        registry.terminate('external')
        assert.are.same({}, registry.list())
    end)
end)
