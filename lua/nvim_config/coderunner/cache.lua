local M = {}
local uv = vim.uv
local sequence = 0
local using = {}

function M.read(path)
    local f = io.open(path, 'rb')
    if not f then return nil end
    local bytes = f:read('*a'); f:close()
    return bytes
end
local function json(path)
    local bytes = M.read(path)
    if not bytes then return {} end
    local ok, value = pcall(vim.json.decode, bytes)
    if ok and type(value) == 'table' then return value end
    return nil, 'invalid cache metadata: ' .. path
end
function M.atomic(path, bytes)
    sequence = sequence + 1
    local temp = path .. '.tmp-' .. uv.os_getpid() .. '-' .. sequence
    local fd, err = uv.fs_open(temp, 'wx', 384)
    if not fd then return nil, err end
    local written; written, err = uv.fs_write(fd, bytes, 0)
    uv.fs_close(fd)
    if written ~= #bytes then uv.fs_unlink(temp); return nil, err or 'short cache write' end
    local ok; ok, err = uv.fs_rename(temp, path)
    if not ok then uv.fs_unlink(temp) end
    return ok, err
end
function M.paths(root)
    root = vim.fs.normalize(uv.fs_realpath(root) or root)
    local dir = vim.fs.joinpath(vim.fn.stdpath('cache'), 'coderunner', vim.fn.sha256(root):sub(1, 24))
    vim.fn.mkdir(dir .. '/diagrams', 'p')
    if not uv.fs_stat(dir .. '/root.json') then M.atomic(dir .. '/root.json', vim.json.encode({ root = root })) end
    return { root = root, dir = dir, images = dir .. '/diagrams', manifest = dir .. '/manifest.json' }
end
function M.image(paths, lang, key, format)
    return paths.images .. '/' .. (lang or 'code'):gsub('[^%w_-]', '-') .. '-' .. key .. '.' .. format
end
function M.valid_image(paths, path)
    return type(path) == 'string' and vim.fs.dirname(path) == paths.images
        and (path:match('/[%w_-]+%-%x+%.png$') ~= nil or path:match('/[%w_-]+%-%x+%.svg$') ~= nil)
end
local function nonempty(path)
    local s = uv.fs_lstat(path)
    return s and s.type == 'file' and s.size > 0
end
M.nonempty = nonempty
function M.manifest(paths)
    local data, err = json(paths.manifest)
    if not data then return nil, err end
    for _, entry in pairs(data) do
        if type(entry) ~= 'table' or entry.success and type(entry.success) ~= 'table'
            or entry.failure and type(entry.failure) ~= 'table' then
            return nil, 'invalid cache manifest entry'
        end
    end
    return data
end

-- Reclaim only a verifiably dead owner, and recheck bytes/inode before unlink.
local function reclaim(path)
    local before, bytes = uv.fs_stat(path), M.read(path)
    local owner = json(path)
    if owner and type(owner.pid) == 'number' and owner.pid > 0 then
        local alive, reason = uv.kill(owner.pid, 0)
        if not alive and tostring(reason):find('ESRCH', 1, true) then
            local after = uv.fs_stat(path)
            if before and after and before.ino == after.ino and before.mtime.sec == after.mtime.sec
                and M.read(path) == bytes then uv.fs_unlink(path) end
        end
    end
end

-- O_EXCL and a live owner prevent concurrent writers, including other instances.
-- Cancellation also removes the scheduled retry without ever taking the lock.
function M.lock(path, callback)
    local stopped, owned = false, false
    local token = tostring(uv.os_getpid()) .. ':' .. tostring(uv.hrtime())
    local handle = {}
    local function release()
        if not owned then return end
        local owner = json(path)
        if owner and owner.token == token then uv.fs_unlink(path) end
        owned = false
    end
    function handle.cancel() stopped = true; release() end
    local function attempt()
        if stopped then return end
        local fd, err = uv.fs_open(path, 'wx', 384)
        if fd then
            local bytes = vim.json.encode({ pid = uv.os_getpid(), token = token })
            local written = uv.fs_write(fd, bytes, 0); uv.fs_close(fd)
            if written ~= #bytes then uv.fs_unlink(path); callback(nil, 'cannot write cache lock'); return end
            owned = true; callback(release); return
        end
        if not tostring(err):find('EEXIST', 1, true) then callback(nil, err); return end
        reclaim(path)
        vim.defer_fn(attempt, 20)
    end
    attempt()
    return handle
end
function M.update(paths, block_key, change, callback)
    return M.lock(paths.dir .. '/manifest.lock', function(release, err)
        if not release then callback(nil, err); return end
        local manifest; manifest, err = M.manifest(paths)
        local ok
        if manifest then
            local entry = manifest[block_key] or {}
            local changed, message = pcall(change, entry)
            if changed then
                manifest[block_key] = entry
                ok, err = M.atomic(paths.manifest, vim.json.encode(manifest))
            else err = tostring(message) end
        end
        release(); callback(ok, err)
    end)
end
function M.lookup(paths, block_key, key, path)
    local manifest, err = M.manifest(paths)
    if not manifest then return { status = 'none', error = err } end
    local record = manifest[block_key] or {}
    local failure = record.failure and record.failure.key == key and record.failure or nil
    local result = { status = failure and 'failed' or 'none', error = failure and failure.message }
    if nonempty(path) then result.path, result.stale = path, false
    elseif record.success and M.valid_image(paths, record.success.path) and nonempty(record.success.path) then
        result.path, result.stale = record.success.path, true
    end
    if result.path and not failure then result.status = 'ready' end
    return result
end
function M.use(path, delta)
    using[path] = (using[path] or 0) + delta
    if using[path] <= 0 then using[path] = nil end
end
function M.busy(paths, ignore_gc)
    for path in pairs(using) do if vim.fs.dirname(path) == paths.images then return true end end
    local images = uv.fs_scandir(paths.images)
    if images then
        while true do
            local name = uv.fs_scandir_next(images)
            if not name then break end
            if name:match('%.lock$') then
                local path = paths.images .. '/' .. name
                reclaim(path)
                if uv.fs_stat(path) then return true end
            end
        end
    end
    local scan = uv.fs_scandir(paths.dir)
    if scan then
        while true do
            local name = uv.fs_scandir_next(scan)
            if not name then break end
            if name:match('%.lock$') and not (ignore_gc and name == 'gc.lock') then
                local path = paths.dir .. '/' .. name
                reclaim(path)
                if uv.fs_stat(path) then return true end
            end
        end
    end
    return false
end
function M.files(paths)
    local scan, err = uv.fs_scandir(paths.images)
    if not scan then return nil, err end
    local files = {}
    while true do
        local name = uv.fs_scandir_next(scan)
        if not name then break end
        local path = paths.images .. '/' .. name
        local stat = uv.fs_lstat(path)
        if not stat then return nil, 'incomplete cache scan' end
        if stat.type == 'file' and M.valid_image(paths, path) then
            files[#files + 1] = { path = path, size = stat.size,
                time = stat.mtime.sec + stat.mtime.nsec / 1e9 }
        end
    end
    return files
end
-- An incomplete document collection must never authorize deletion.
function M.prune(paths, protected, complete, limit, dry_run)
    if not complete then return nil, 'incomplete document collection; cache preserved' end
    local files, err = M.files(paths)
    if not files then return nil, err end
    table.sort(files, function(a, b) return a.time == b.time and a.path < b.path or a.time < b.time end)
    local total, removed = 0, {}
    for _, file in ipairs(files) do total = total + file.size end
    for _, file in ipairs(files) do
        if (limit == nil or limit ~= 'unlimited' and total > limit)
            and not protected[file.path] and not using[file.path] and not uv.fs_stat(file.path .. '.lock') then
            if not dry_run then
                local ok; ok, err = uv.fs_unlink(file.path)
                if not ok then return nil, err end
            end
            removed[#removed + 1] = file.path; total = total - file.size
        end
    end
    return { removed = removed, size = total, over_limit = type(limit) == 'number' and total > limit }
end
function M.roots()
    local base = vim.fs.joinpath(vim.fn.stdpath('cache'), 'coderunner')
    local scan = uv.fs_scandir(base)
    if not scan then return {} end
    local roots = {}
    while true do
        local name, typ = uv.fs_scandir_next(scan)
        if not name then break end
        if typ ~= 'directory' or not name:match('^%x+$') then return nil, 'invalid cache root folder' end
        local data = json(base .. '/' .. name .. '/root.json')
        if not data or type(data.root) ~= 'string' or not uv.fs_stat(data.root)
            or vim.fn.sha256(data.root):sub(1, 24) ~= name then return nil, 'invalid cache root metadata' end
        roots[#roots + 1] = data.root
    end
    return roots
end
return M
