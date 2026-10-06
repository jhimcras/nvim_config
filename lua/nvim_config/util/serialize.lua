local M = {}

function M.insert_unique_by(t, value, eq)
    for _, v in ipairs(t) do
        if eq(v, value) then
            return false
        end
    end
    table.insert(t, value)
    return true
end

function M.normalize_path_separator(path, is_windows)
    local normalized = path:gsub("\\", "/")
    if is_windows then
        return normalized
    end
    return normalized
end

function M.serialize(tbl, indent)
    indent = indent or 0
    local pad = string.rep(" ", indent)
    local lines = { "{" }
    for k, v in pairs(tbl) do
        local key = type(k) == "string" and k or ("[" .. tostring(k) .. "]")
        local value
        if type(v) == "table" then
            value = M.serialize(v, indent + 2)
        elseif type(v) == "string" then
            value = string.format("%q", v)
        else
            value = tostring(v)
        end
        table.insert(lines, string.format("%s  %s = %s,", pad, key, value))
    end
    table.insert(lines, pad .. "}")
    return table.concat(lines, "\n")
end

return M
