local M = {}


-- Shift `rgb` ('#RRGGBB' or packed number) toward white (pct > 0) or black (pct < 0).
function M.shade(rgb, pct)
    if type(rgb) == 'string' then
        rgb = tonumber(rgb:gsub('^#', ''), 16)
    end
    if type(rgb) ~= 'number' then
        return nil
    end
    local out = 0
    for _, shift in ipairs({ 16, 8, 0 }) do
        local c = math.floor(rgb / 2 ^ shift) % 256
        local target = pct >= 0 and 255 or 0
        c = math.floor(c + (target - c) * math.abs(pct) / 100 + 0.5)
        out = out + math.max(0, math.min(255, c)) * 2 ^ shift
    end
    return string.format('#%06X', out)
end


function M.set_highlight(name, args)
    if type(args) == 'table' then
        local a = { name }
        for key, arg in pairs(args) do
            a[#a+1] = string.format(' %s=%s', key, tostring(arg))
        end
        vim.cmd.highlight(table.concat(a))
    elseif type(args) == 'string' then
        vim.cmd.highlight {'link', name, args}
    end
end


function M.set_highlights(hls)
    for group, value in pairs(hls) do
        if type(value) ~= "table" then
            -- skip non-table values
        elseif value[1] then
            -- indexed table
            for idx, sub in pairs(value) do
                local has_modes
                for k, v in pairs(sub) do
                    if type(v) == "table" then
                        vim.api.nvim_set_hl(0, ("%s_%s_%s"):format(group, idx, k), v)
                        has_modes = true
                    end
                end
                if not has_modes then
                    vim.api.nvim_set_hl(0, ("%s_%s"):format(group, idx), sub)
                end
            end
        else
            -- plain highlight
            vim.api.nvim_set_hl(0, group, value)
        end
    end
end


return M
