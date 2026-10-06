local cache = require('nvim_config.util.cache')

describe('util/cache.lua time and return-value contracts', function()
    local original_now, original_timer, original_schedule_wrap
    local now, timers

    before_each(function()
        original_now, original_timer = vim.uv.now, vim.uv.new_timer
        original_schedule_wrap = vim.schedule_wrap
        now, timers = 0, {}
        vim.uv.now = function() return now end
        -- Drive timers explicitly: no sleeps, wall-clock races, or leaked handles.
        vim.schedule_wrap = function(fn) return fn end
        vim.uv.new_timer = function()
            local timer = {}
            function timer:start(ms, _, fn) self.due, self.fn = now + ms, fn end
            function timer:stop() self.due = nil end
            function timer:close() self.closed = true; self.due = nil end
            timers[#timers + 1] = timer
            return timer
        end
    end)

    after_each(function()
        vim.uv.now, vim.uv.new_timer = original_now, original_timer
        vim.schedule_wrap = original_schedule_wrap
    end)

    local function advance(ms)
        now = now + ms
        for _, timer in ipairs(timers) do
            if timer.due and timer.due <= now then
                timer.due = nil
                timer.fn()
            end
        end
    end

    it('expires at the TTL boundary, even when a cached result is false or nil', function()
        local calls = 0
        local fn = cache.memoize_ttl(function()
            calls = calls + 1
            return false, nil, calls, nil
        end, { ttl_ms = 10 })
        local function result()
            local a, b, c, d = fn()
            assert.is_false(a)
            assert.is_nil(b)
            assert.is_nil(d)
            assert.are.equal(4, select('#', fn()))
            return c
        end
        assert.are.equal(1, result())
        advance(9)
        assert.are.equal(1, result())
        advance(1)
        assert.are.equal(2, result())
        assert.are.equal(2, calls)
    end)

    it('distinguishes numeric, string, boolean, nil and absent arguments', function()
        local calls = 0
        local fn = cache.memoize_ttl(function() calls = calls + 1; return calls end, { ttl_ms = 10 })
        assert.are.equal(1, fn(1))
        assert.are.equal(2, fn('1'))
        assert.are.equal(3, fn(false))
        assert.are.equal(4, fn(nil))
        assert.are.equal(5, fn())
        assert.are.equal(1, fn(1))
        assert.are.equal(5, calls)
    end)

    it('uses the caller key function to share equivalent arguments', function()
        local calls = 0
        local fn = cache.memoize_ttl(function(obj) calls = calls + 1; return obj.value end,
            { ttl_ms = 10, key_fn = function(obj) return obj.id end })
        assert.are.equal('first', fn({ id = 1, value = 'first' }))
        assert.are.equal('first', fn({ id = 1, value = 'ignored' }))
        assert.are.equal('second', fn({ id = 2, value = 'second' }))
        assert.are.equal(2, calls)
    end)

    it('debounces to the latest call and preserves nil arguments', function()
        local received = {}
        local fn = cache.debounce(function(...)
            received[#received + 1] = { n = select('#', ...), ... }
        end, 10)
        fn('old')
        advance(9)
        fn('latest', nil, 3, nil)
        advance(9)
        assert.are.same({}, received)
        advance(1)
        assert.are.same({ { n = 4, 'latest', nil, 3 } }, received)
    end)

    it('throttles with an immediate call and the latest pending trailing call', function()
        local received = {}
        local fn = cache.throttle(function(value) received[#received + 1] = value end, 10)
        fn('first')
        fn('discarded')
        fn('latest')
        assert.are.same({ 'first' }, received)
        advance(10)
        assert.are.same({ 'first', 'latest' }, received)
        advance(10)
        fn('next')
        assert.are.same({ 'first', 'latest', 'next' }, received)
    end)
end)
