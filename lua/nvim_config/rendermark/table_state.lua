local M = { rows = {} }
local table_enabled = true

function M.set_enabled(enabled)
    table_enabled = enabled
end

function M.table_row(buf, row)
    local rows = M.rows[buf]
    return rows and rows[row]
end

local function buffer_enabled(buf)
    return vim.g.markdown_visual_wrap_enabled ~= false and vim.b[buf].markdown_visual_wrap == true
end

local table_query -- lazy treesitter query: pipe tables
local function get_table_query()
    if table_query == nil then
        local ok, q = pcall(vim.treesitter.query.parse, 'markdown', '(pipe_table) @t')
        table_query = ok and q or false
    end
    return table_query or nil
end

-- Pipe tables touching [first, last) as { first_row, last_row } (0-based, inclusive).
function M.find_tables(buf, root, first, last)
    local tables = {}
    local tq = table_enabled and get_table_query() or nil
    if not tq then
        return tables
    end
    for _, node in tq:iter_captures(root, buf, first, last) do
        local r1, _, r2, c2 = node:range()
        if c2 == 0 then r2 = r2 - 1 end
        -- Trim trailing pipe-less prose the grammar absorbs into the table.
        local rows = vim.api.nvim_buf_get_lines(buf, r1, r2 + 1, false)
        local tend = r1 + 1 -- header + delimiter
        for k = 3, #rows do
            if rows[k]:find('|', 1, true) then
                tend = r1 + k - 1
            else
                break
            end
        end
        tables[#tables + 1] = { r1, tend }
    end
    return tables
end

-- Rows of [first, last) inside tables this module draws, rendered yet or not.
-- Their images belong to the table layout, never to the inline image renderer.
function M.table_source_rows(buf, first, last)
    local rows = {}
    if not table_enabled or not buffer_enabled(buf) then
        return rows
    end
    local ok, parser = pcall(vim.treesitter.get_parser, buf, 'markdown')
    if not ok or not parser then
        return rows
    end
    local ok_tree, trees = pcall(function() return parser:parse({ first, last }) end)
    local tree = ok_tree and trees and trees[1]
    if not tree then
        return rows
    end
    for _, t in ipairs(M.find_tables(buf, tree:root(), first, last)) do
        for l = t[1], t[2] do
            rows[l] = true
        end
    end
    return rows
end

-- Rows [first, last) widened to whole pipe tables, which render_table draws at once.
function M.widen(buf, first, last)
    local tq = table_enabled and get_table_query() or nil
    local ok, parser = pcall(vim.treesitter.get_parser, buf, 'markdown')
    if not tq or not ok or not parser then
        return first, last
    end
    -- The text is unchanged since the last full render parsed it.
    local tree = parser:trees()[1]
    if not tree then
        return first, last
    end
    repeat
        local grown = false
        for _, node in tq:iter_captures(tree:root(), buf, first, last) do
            local r1, _, r2, c2 = node:range()
            if c2 == 0 then r2 = r2 - 1 end
            if r1 < first then first, grown = r1, true end
            if r2 + 1 > last then last, grown = r2 + 1, true end
        end
    until not grown
    return first, last
end

-- Row heights and table image placement, which image positions depend on.
return M
