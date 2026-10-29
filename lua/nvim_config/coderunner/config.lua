local M = {}

M.defaults = {
    runners = {}, renderers = {}, max_jobs = 4, timeout = 30000,
    max_output = 1024 * 1024, auto_render = true, auto_render_debounce = 200,
    render_max_size = 512 * 1024 * 1024, attachments = './assets',
    link_style = 'markdown', create_attachments_dir = 'ask',
    diagnostics = true, render_on_open = false,
}

local function quantity(value, units)
    if type(value) ~= 'string' then return nil end
    local digits, unit = value:match('^([1-9]%d*)(%a+)$')
    local scale = units[unit]
    local n = digits and tonumber(digits)
    -- Keep integer arithmetic exact in LuaJIT doubles.
    if not n or not scale or n > 9007199254740991 / scale then return nil end
    return n * scale
end

function M.parse_time(value)
    return quantity(value, { ms = 1, s = 1000, m = 60000, h = 3600000 })
end

function M.parse_size(value)
    return quantity(value, { B = 1, KB = 1024, MB = 1048576, GB = 1073741824 })
end

local function list(value, nonempty_strings)
    if type(value) ~= 'table' or not vim.islist(value) or #value == 0 then return false end
    for _, v in ipairs(value) do
        if type(v) ~= 'string' or (nonempty_strings and v == '') or v:find('\0', 1, true) then
            return false
        end
    end
    return true
end

local function text(value)
    return type(value) == 'string' and value ~= '' and not value:find('\0', 1, true)
end

local function attachments(value)
    if not text(value) or value:find('\\', 1, true) or value:match('^/') or value:match('^%a:') then
        return false
    end
    for part in value:gmatch('[^/]+') do if part == '..' then return false end end
    return true
end

local function entry(raw, kind, path, report)
    if type(raw) ~= 'table' then report('error', path, 'must be a table'); return end
    local valid = true
    local function check(ok, key, message)
        if not ok then valid = false; report('error', path .. key, message) end
    end
    check(list(raw.match, true), '.match', 'must be a non-empty array of non-empty strings')
    check((raw.cmd ~= nil) ~= (raw.steps ~= nil), '', 'needs exactly one of cmd and steps')
    if raw.cmd ~= nil then
        check(list(raw.cmd, false) and text(raw.cmd[1]), '.cmd', 'must be a non-empty argv array')
    end
    if raw.steps ~= nil then
        local ok = type(raw.steps) == 'table' and vim.islist(raw.steps) and #raw.steps > 0
        if ok then
            for _, step in ipairs(raw.steps) do
                if not list(step, false) or not text(step[1]) then ok = false end
            end
        end
        check(ok, '.steps', 'must be a non-empty array of argv arrays')
    end
    for _, key in ipairs({ 'ext', 'cwd' }) do
        if raw[key] ~= nil then check(text(raw[key]), '.' .. key, 'must be a non-empty string') end
    end
    -- ext becomes part of a temporary input filename, never a path.
    if type(raw.ext) == 'string' then
        check(not raw.ext:find('[/\\]') and raw.ext ~= '.' and raw.ext ~= '..', '.ext', 'must be a filename extension')
    end
    if raw.timeout ~= nil then check(M.parse_time(raw.timeout) ~= nil, '.timeout', 'expected positive duration (ms/s/m/h)') end
    if raw.input ~= nil then check(raw.input == 'file' or raw.input == 'stdin', '.input', 'expected file or stdin') end
    if raw.env ~= nil then
        check(type(raw.env) == 'table', '.env', 'must be a string map')
        if type(raw.env) == 'table' then
            for k, v in pairs(raw.env) do
                check(text(k) and not k:find('=', 1, true) and type(v) == 'string' and not v:find('\0', 1, true), '.env', 'must be a string map')
            end
        end
    end
    local allowed = { match = true, ext = true, cmd = true, steps = true, timeout = true, input = true, env = true, cwd = true }
    if kind == 'renderers' then
        allowed.output, allowed.formats = true, true
        if raw.output ~= nil then check(raw.output == 'file' or raw.output == 'stdout', '.output', 'expected file or stdout') end
        local ok, seen = list(raw.formats, true), {}
        if ok then
            for _, fmt in ipairs(raw.formats) do
                if (fmt ~= 'svg' and fmt ~= 'png') or seen[fmt] then ok = false end
                seen[fmt] = true
            end
        end
        check(ok, '.formats', 'expected distinct svg/png formats')
        local function no_attrs(value)
            if type(value) == 'string' then return not value:match('{attr%.[^{}]+}') end
            if type(value) == 'table' then
                for _, v in pairs(value) do if not no_attrs(v) then return false end end
            end
            return true
        end
        for _, key in ipairs({ 'cmd', 'steps', 'env', 'cwd' }) do
            check(no_attrs(raw[key]), '.' .. key, 'renderer must not use {attr.*}')
        end
    end
    local result = {}
    for k, v in pairs(raw) do
        if allowed[k] then result[k] = vim.deepcopy(v)
        else report('warning', path .. '.' .. tostring(k), 'unknown key') end
    end
    if not valid then return end
    if result.timeout then result.timeout = M.parse_time(result.timeout) end
    result.input = result.input or 'file'
    result.env = result.env or {}
    result.cwd = result.cwd or (kind == 'runners' and '{docdir}' or '{tmpdir}')
    if kind == 'renderers' then result.output = result.output or 'file' end
    return result
end

-- Validate a layer without defaults. Invalid entries are retained as false so
-- replacing a named command never silently restores a lower-priority command.
function M.validate(opts, source)
    local layer, diagnostics = { runners = {}, renderers = {} }, {}
    local function report(level, path, message)
        diagnostics[#diagnostics + 1] = { level = level, message = path .. ': ' .. message }
    end
    if type(opts) ~= 'table' then
        report('error', source or 'config', 'must return a table')
        return layer, diagnostics
    end
    for k, v in pairs(opts) do
        if k == 'runners' or k == 'renderers' then
            if type(v) ~= 'table' then report('error', k, 'must be a table')
            else
                for name, raw in pairs(v) do
                    if not text(name) then report('error', k, 'entry name must be a non-empty string')
                    else
                        local e = entry(raw, k, k .. '.' .. name, report)
                        if e then e.source = source or 'global' end
                        layer[k][name] = e or false
                    end
                end
            end
        elseif M.defaults[k] == nil then report('warning', tostring(k), 'unknown key')
        else
            local parsed, ok = v, true
            if k == 'timeout' or k == 'auto_render_debounce' then
                parsed = M.parse_time(v); ok = parsed ~= nil
            elseif k == 'max_output' or k == 'render_max_size' then
                parsed = k == 'render_max_size' and v == 'unlimited' and v or M.parse_size(v)
                ok = parsed ~= nil
            elseif k == 'max_jobs' then
                ok = type(v) == 'number' and v >= 1 and v <= 9007199254740991 and v == math.floor(v)
            elseif k == 'attachments' then ok = attachments(v)
            elseif k == 'link_style' then ok = v == 'markdown' or v == 'wiki'
            elseif k == 'create_attachments_dir' then ok = v == 'ask' or v == 'never' or v == 'always'
            else ok = type(v) == 'boolean' end
            if ok then layer[k] = parsed else report('error', k, 'invalid value') end
        end
    end
    return layer, diagnostics
end

function M.merge(global, workspace)
    local result = vim.deepcopy(M.defaults)
    for _, layer in ipairs({ global or {}, workspace or {} }) do
        for k, v in pairs(layer) do
            if k == 'runners' or k == 'renderers' then
                for name, e in pairs(v) do result[k][name] = vim.deepcopy(e) end
            else result[k] = vim.deepcopy(v) end
        end
    end
    return result
end

function M.select(config, kind, lang)
    local candidates = {}
    for name, e in pairs(config[kind]) do
        if e and vim.tbl_contains(e.match, lang) then candidates[#candidates + 1] = { name = name, entry = e } end
    end
    table.sort(candidates, function(a, b)
        if a.entry.source ~= b.entry.source then return a.entry.source == 'workspace' end
        return a.name < b.name
    end)
    local first = candidates[1]
    if first then return first.entry, first.name end
end

return M
