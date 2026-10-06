local M = {}

-- ANSI SGR colors -> Neovim highlight groups
M.ansi_highlight_groups = {
    ['30'] = 'AnsiBlack',   ['31'] = 'AnsiRed',    ['32'] = 'AnsiGreen',  ['33'] = 'AnsiYellow',
    ['34'] = 'AnsiBlue',    ['35'] = 'AnsiMagenta', ['36'] = 'AnsiCyan',   ['37'] = 'AnsiWhite',
    ['0']  = 'Normal'
}

-- Returns cleaned_text, { {col_start, col_end, group}, ... }
function M.parse_ansi(text)
    local parts = {}
    local length = 0
    local highlights = {}
    local current_hl = 'Normal'
    local hl_start = 0

    local pos = 1
    while pos <= #text do
        -- Matches [1m, [1;31m, [0m
        local start, finish, code = text:find("\27%[([%d;]+)m", pos)
        local plain_end = start and start - 1 or #text
        if plain_end >= pos then
            parts[#parts + 1] = text:sub(pos, plain_end)
            length = length + plain_end - pos + 1
        end
        if start then
            -- Several codes (1;31): take the last recognized one
            local codes = vim.split(code, ';')
            local last_code = codes[#codes]
            
            local new_hl = M.ansi_highlight_groups[last_code] or 'Normal'
            if new_hl ~= current_hl then
                if length > hl_start then
                    table.insert(highlights, {hl_start, length, current_hl})
                end
                current_hl = new_hl
                hl_start = length
            end
            pos = finish + 1
        else
            break
        end
    end
    -- Final segment
    if length > hl_start then
        table.insert(highlights, {hl_start, length, current_hl})
    end
    return table.concat(parts), highlights
end

return M
