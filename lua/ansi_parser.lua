local M = {}

-- ANSI SGR color mapping to Neovim Highlight Groups
M.ansi_highlight_groups = {
    ['30'] = 'AnsiBlack',   ['31'] = 'AnsiRed',    ['32'] = 'AnsiGreen',  ['33'] = 'AnsiYellow',
    ['34'] = 'AnsiBlue',    ['35'] = 'AnsiMagenta', ['36'] = 'AnsiCyan',   ['37'] = 'AnsiWhite',
    ['0']  = 'Normal'
}

-- Parser that returns cleaned text and highlight definitions
-- Returns: cleaned_text, { {col_start, col_end, group}, ... }
function M.parse_ansi(text)
    local cleaned = ""
    local highlights = {}
    local current_hl = 'Normal'
    local hl_start = 0

    local pos = 1
    while pos <= #text do
        -- Updated regex to match sequences like [1m, [1;31m, [0m
        local start, finish, code = text:find("^\27%[([%d;]+)m", pos)
        if start then
            -- If multiple codes are present (e.g., 1;31), we typically use the last one or base color
            -- For simplicity, we split and pick the last recognized color code
            local codes = vim.split(code, ';')
            local last_code = codes[#codes]
            
            local new_hl = M.ansi_highlight_groups[last_code] or 'Normal'
            if new_hl ~= current_hl then
                if #cleaned > hl_start then
                    table.insert(highlights, {hl_start, #cleaned, current_hl})
                end
                current_hl = new_hl
                hl_start = #cleaned
            end
            pos = finish + 1
        else
            cleaned = cleaned .. text:sub(pos, pos)
            pos = pos + 1
        end
    end
    -- Add final highlight segment
    if #cleaned > hl_start then
        table.insert(highlights, {hl_start, #cleaned, current_hl})
    end
    return cleaned, highlights
end

return M
