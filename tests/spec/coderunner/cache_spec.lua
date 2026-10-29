local H = require('tests.spec.coderunner.helpers')
local cache = require('nvim_config.coderunner.cache')
local uv = vim.uv

describe('coderunner persistent cache', function()
    local root, paths
    local function image(letter, bytes, age)
        local path = cache.image(paths, 'dot', string.rep(letter, 64), 'png')
        H.write(path, bytes); if age then uv.fs_utime(path, age, age) end
        return path
    end
    before_each(function() root = H.workspace(); paths = cache.paths(root) end)
    after_each(function() vim.fn.delete(paths.dir, 'rf'); vim.fn.delete(root, 'rf') end)
    it('replaces atomically and preserves old bytes when rename fails', function()
        local path = image('a', 'old')
        assert(cache.atomic(path, 'new')); assert.equals('new', cache.read(path))
        local rename = uv.fs_rename
        uv.fs_rename = function() return nil, 'denied' end
        local ok = cache.atomic(path, 'bad'); uv.fs_rename = rename
        assert.is_nil(ok); assert.equals('new', cache.read(path))
        assert.same({ vim.fs.basename(path) }, vim.fn.readdir(paths.images))
    end)
    it('merges independent manifest updates inside the manifest lock', function()
        local count = 0
        cache.update(paths, 'a', function(e) e.success = { key = 'a' } end, function(ok) assert(ok); count = count + 1 end)
        cache.update(paths, 'b', function(e) e.failure = { key = 'b', message = 'error' } end, function(ok) assert(ok); count = count + 1 end)
        H.wait(function() return count == 2 end)
        local manifest = cache.manifest(paths)
        assert.equals('a', manifest.a.success.key); assert.equals('b', manifest.b.failure.key)
    end)
    it('waits for live owners, supports cancellation and reclaims dead owner locks', function()
        local path = paths.dir .. '/test.lock'
        local release
        cache.lock(path, function(r) release = r end); assert.is_function(release)
        local called = false
        local waiting = cache.lock(path, function() called = true end)
        waiting.cancel(); release(); vim.wait(50, function() return false end, 10)
        assert.is_false(called)
        H.write(path, vim.json.encode({ pid = 2147483647, token = 'dead' }))
        local reclaimed
        cache.lock(path, function(r) reclaimed = r end)
        H.wait(function() return reclaimed ~= nil end); reclaimed()
        assert.is_nil(uv.fs_stat(path))
    end)
    it('prunes oldest first while protecting current, preview, and in-use images', function()
        local a, b, c = image('a', 'aaaa', 1), image('b', 'bbbb', 2), image('c', 'cccc', 3)
        cache.use(b, 1)
        local result = assert(cache.prune(paths, { [c] = true }, true, 8))
        assert.same({ a }, result.removed); assert.equals(8, result.size)
        result = assert(cache.prune(paths, { [c] = true }, true, 1))
        assert.is_true(result.over_limit); assert.equals(8, result.size)
        cache.use(b, -1)
        result = assert(cache.prune(paths, {}, true, 'unlimited')); assert.same({}, result.removed)
        result = assert(cache.prune(paths, {}, true, 0)); assert.equals(0, result.size)
    end)
    it('refuses incomplete collections and corrupt manifests rather than deleting', function()
        local a = image('a', 'a')
        local result, err = cache.prune(paths, {}, false)
        assert.is_nil(result); assert.matches('incomplete', err); assert.is_truthy(uv.fs_stat(a))
        H.write(paths.manifest, 'bad json')
        local called
        cache.update(paths, 'a', function() error('must not run') end, function(ok, message) called = message; assert.is_nil(ok) end)
        assert.matches('invalid cache metadata', called)
    end)
    it('validates all root folders before returning any root', function()
        assert.is_truthy(vim.tbl_contains(assert(cache.roots()), paths.root))
        H.write(paths.dir .. '/root.json', '{}')
        local roots, err = cache.roots(); assert.is_nil(roots); assert.matches('invalid', err)
    end)
    it('does not follow manifest paths or image symlinks outside the cache', function()
        local external = H.write(root .. '/outside.png', 'outside')
        H.write(paths.manifest, vim.json.encode({ block = { success = { key = 'old', path = external } } }))
        assert.is_nil(cache.lookup(paths, 'block', 'new', paths.images .. '/missing.png').path)
        if uv.os_uname().sysname ~= 'Windows_NT' then
            local path = cache.image(paths, 'dot', string.rep('a', 64), 'png')
            assert(uv.fs_symlink(external, path)); assert.is_falsy(cache.nonempty(path))
            assert.same({}, assert(cache.prune(paths, {}, true)).removed)
        end
        assert.equals('outside', cache.read(external))
    end)
    it('merges writes from two Neovim instances without losing either entry', function()
        local worker = H.write(root .. '/writer.lua', [[
vim.opt.rtp:prepend(vim.fn.getcwd())
local cache = require('nvim_config.coderunner.cache')
local paths = cache.paths(arg[1])
local done
cache.update(paths, arg[2], function(e)
    vim.uv.sleep(50)
    e.success = { key = arg[2] }
end, function(ok, err) assert(ok, err); done = true end)
assert(vim.wait(5000, function() return done end, 10))
]])
        local results = {}
        for _, key in ipairs({ 'first', 'second' }) do
            vim.system({ vim.v.progpath, '-u', 'NONE', '-i', 'NONE', '-l', worker, root, key }, {},
                function(result) results[#results + 1] = result end)
        end
        H.wait(function() return #results == 2 end)
        for _, result in ipairs(results) do assert.equals(0, result.code, result.stderr) end
        local manifest = cache.manifest(paths)
        assert.equals('first', manifest.first.success.key)
        assert.equals('second', manifest.second.success.key)
    end)

end)
