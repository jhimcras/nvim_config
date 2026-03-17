local ut = require('util')

describe('util.serialize', function()
    it('empty table returns "{\\n}"', function()
        assert.equals('{\n}', ut.serialize({}))
    end)

    it('string value is quoted', function()
        local out = ut.serialize({ s = 'hello' })
        assert.truthy(out:find('"hello"', 1, true))
    end)

    it('numeric key uses bracket notation', function()
        local out = ut.serialize({ 'x' })
        assert.truthy(out:find('[1]', 1, true))
        assert.truthy(out:find('"x"', 1, true))
    end)

    it('integer value is serialized', function()
        local out = ut.serialize({ a = 1 })
        assert.truthy(out:find('a = 1', 1, true))
    end)

    it('nested table is serialized recursively', function()
        local out = ut.serialize({ a = { b = 2 } })
        assert.truthy(out:find('b = 2', 1, true))
    end)
end)


describe('util.insert_unique_by', function()
    local eq_val = function(a, b) return a == b end

    it('inserts a new value and returns true', function()
        local t = {}
        local inserted = ut.insert_unique_by(t, 42, eq_val)
        assert.is_true(inserted)
        assert.equals(42, t[1])
    end)

    it('does not insert a duplicate and returns false', function()
        local t = { 42 }
        local inserted = ut.insert_unique_by(t, 42, eq_val)
        assert.is_false(inserted)
        assert.equals(1, #t)
    end)

    it('inserted value appears at end of table', function()
        local t = { 1, 2 }
        ut.insert_unique_by(t, 3, eq_val)
        assert.equals(3, t[#t])
    end)

    it('custom eq function compares by field', function()
        local eq_name = function(a, b) return a.name == b.name end
        local t = { { name = 'foo' } }
        local dup = ut.insert_unique_by(t, { name = 'foo' }, eq_name)
        assert.is_false(dup)
        local new = ut.insert_unique_by(t, { name = 'bar' }, eq_name)
        assert.is_true(new)
    end)
end)


describe('util.normalize_path_separator', function()
    it('converts backslashes to forward slashes on unix', function()
        -- env.os.win is false on Linux; backslash → forward slash
        local result = ut.normalize_path_separator('a\\b\\c')
        assert.equals('a/b/c', result)
    end)

    it('path without separators is unchanged', function()
        local result = ut.normalize_path_separator('filename')
        assert.equals('filename', result)
    end)
end)


describe('util.memoize_ttl', function()
    it('ttl_ms=0 calls underlying function every time (no caching)', function()
        local count = 0
        local f = ut.memoize_ttl(function() count = count + 1; return count end, { ttl_ms = 0 })
        f(); f(); f()
        assert.equals(3, count)
    end)

    it('ttl_ms large: second call returns cached result (underlying called once)', function()
        local count = 0
        local f = ut.memoize_ttl(function() count = count + 1; return count end, { ttl_ms = 99999 })
        local r1 = f()
        local r2 = f()
        assert.equals(1, count)
        assert.equals(r1, r2)
    end)

    it('different args produce different cache entries', function()
        local count = 0
        local f = ut.memoize_ttl(function(x) count = count + 1; return x * 2 end, { ttl_ms = 99999 })
        assert.equals(2, f(1))
        assert.equals(4, f(2))
        assert.equals(2, count)
    end)

    it('multiple return values are preserved through cache', function()
        local f = ut.memoize_ttl(function() return 10, 20, 30 end, { ttl_ms = 99999 })
        local a, b, c = f()
        assert.equals(10, a)
        assert.equals(20, b)
        assert.equals(30, c)
        -- second call hits cache
        local a2, b2, c2 = f()
        assert.equals(10, a2)
        assert.equals(20, b2)
        assert.equals(30, c2)
    end)

    it('cache expires after ttl and underlying is called again', function()
        local count = 0
        local f = ut.memoize_ttl(function() count = count + 1; return count end, { ttl_ms = 1 })
        f()
        vim.uv.sleep(10)
        vim.uv.update_time()  -- flush cached timestamp so memoize sees elapsed time
        f()
        assert.equals(2, count)
    end)
end)
