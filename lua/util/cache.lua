local M = {}

M.MEMOIZE_CLEANUP_HOUR_MS = 3600000

local function pack(...)
  return { n = select("#", ...), ... }
end

local unpack_fn = table.unpack or unpack

local function default_key(...)
  local n = select("#", ...)
  if n == 0 then return "__noargs__" end
  local parts = {}
  for i = 1, n do
    local v = select(i, ...)
    local t = type(v)
    if t == "number" or t == "boolean" or t == "nil" then
      parts[#parts + 1] = tostring(v)
    elseif t == "string" then
      parts[#parts + 1] = "s:" .. v
    else
      parts[#parts + 1] = t .. ":" .. tostring(v)
    end
  end
  return table.concat(parts, "|")
end

function M.ttl_caching_result(func, expired_ms)
    if not func then return function() return nil end end
    local cached_time
    local cached_result
    return function()
        local now = vim.uv.now()
        if cached_result and now - cached_time  < expired_ms then
            return cached_result
        end
        cached_result = func()
        cached_time = now
        return cached_result
    end
end

function M.memoize_ttl(func, opts)
    assert(type(func) == "function", "memoize_ttl: func must be a function")

    opts = opts or {}
    local ttl_ms = assert(tonumber(opts.ttl_ms), "memoize_ttl: opts.ttl_ms must be a number")
    local key_fn = opts.key_fn or default_key
    local cleanup_ms = tonumber(opts.cleanup_ms) or 0
    local opportunistic_every = tonumber(opts.opportunistic_every) or 100

    local cache = {}
    local calls_since_sweep = 0
    local timer

    local function sweep_expired()
        if ttl_ms <= 0 then
            return
        end
        local now = vim.uv.now()
        for k, entry in pairs(cache) do
            if (now - entry.time) >= ttl_ms then
                cache[k] = nil
            end
        end
    end

    if cleanup_ms > 0 and ttl_ms > 0 then
        timer = vim.uv.new_timer()
        timer:start(cleanup_ms, cleanup_ms, function()
            sweep_expired()
        end)
        pcall(vim.api.nvim_create_autocmd, "VimLeavePre", {
            callback = function()
                if timer then
                    timer:stop()
                    timer:close()
                    timer = nil
                end
            end,
            once = true,
        })
    end

    return function(...)
        if ttl_ms <= 0 then
            return func(...)
        end

        local key = key_fn(...)
        local now = vim.uv.now()
        local entry = cache[key]
        if entry and (now - entry.time) < ttl_ms then
            return unpack_fn(entry.pack, 1, entry.pack.n)
        end

        local result = pack(func(...))
        cache[key] = { time = now, pack = result }

        if not timer then
            calls_since_sweep = calls_since_sweep + 1
            if calls_since_sweep >= opportunistic_every then
                calls_since_sweep = 0
                sweep_expired()
            end
        end

        return unpack_fn(result, 1, result.n)
    end
end

function M.debounce(fn, ms)
    assert(type(fn) == "function", "debounce: fn must be a function")
    ms = tonumber(ms) or 0

    local timer
    return function(...)
        local packed = pack(...)
        if not timer then timer = vim.uv.new_timer() end
        timer:stop()
        timer:start(ms, 0, vim.schedule_wrap(function()
            fn(unpack_fn(packed, 1, packed.n))
        end))
    end
end

return M
