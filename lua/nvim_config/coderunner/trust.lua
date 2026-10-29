local M = {}
local loaded = {}

local function path(root)
    return vim.fs.joinpath(root, '.coderunner.lua')
end

local function read(file)
    local stat = vim.uv.fs_stat(file)
    if not stat or stat.type ~= 'file' then return nil end
    local f = io.open(file, 'rb')
    if not f then return nil end
    local content = f:read('*a')
    f:close()
    return content
end

-- Reads bytes only; never evaluates Lua or invokes a trust prompt.
function M.status(root)
    local file = path(root)
    local bytes = read(file)
    if not bytes then
        loaded[file] = nil
        return { state = vim.uv.fs_stat(file) and 'unreadable' or 'absent', path = file }
    end
    local hash = vim.fn.sha256(bytes)
    local cached = loaded[file]
    if cached and cached.hash ~= hash then loaded[file] = nil; cached = nil end
    return { state = cached and cached.state or 'unloaded', path = file, hash = hash,
        config = cached and cached.config, diagnostics = cached and cached.diagnostics }
end

function M.load(root)
    local before = M.status(root)
    if before.state == 'absent' then return before end
    -- Invalidate before prompting or evaluating: errors must never restore old commands.
    loaded[before.path] = nil
    local ok, bytes = pcall(vim.secure.read, before.path)
    if not ok or not bytes then
        loaded[before.path] = { hash = before.hash, state = 'denied' }
        return M.status(root)
    end
    local hash = vim.fn.sha256(bytes)
    if read(before.path) ~= bytes then return { state = 'unloaded', path = before.path, error = 'configuration changed during load' } end
    local chunk, err = loadstring(bytes, '@' .. before.path)
    local success, opts = false, nil
    if chunk then success, opts = pcall(chunk) else opts = err end
    local config, diagnostics
    if success and type(opts) == 'table' then
        config, diagnostics = require('nvim_config.coderunner.config').validate(opts, 'workspace')
    else
        diagnostics = { { level = 'error', message = before.path .. ': ' .. tostring(opts or 'must return a table') } }
    end
    -- Trusted Lua may itself modify the file; never cache under different bytes.
    if read(before.path) ~= bytes then return { state = 'unloaded', path = before.path, error = 'configuration changed during load' } end
    loaded[before.path] = { hash = hash, config = config, diagnostics = diagnostics,
        state = config and 'loaded' or 'invalid' }
    return M.status(root)
end

function M.untrust(root)
    local file = path(root)
    loaded[file] = nil
    return vim.secure.trust({ action = 'remove', path = file })
end

-- Lua entry names cannot be inspected before trust. Services block fallback
-- until the whole workspace configuration has been loaded.
function M.can_select(status)
    return status.state == 'loaded' or status.state == 'absent'
end

function M.allowed(status, source, kind, batch)
    if source == 'workspace' then return status.state == 'loaded' end
    if source ~= 'global' then return false end
    if kind == 'renderers' and batch then
        return status.state == 'loaded' or status.state == 'absent'
    end
    return true
end

return M
