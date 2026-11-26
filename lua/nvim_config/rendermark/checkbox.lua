-- Toggle `[ ]`/`[x]` on the cursor line or Visual selection (Obsidian syntax).
-- A list item without a checkbox gets `[ ]`; non-list lines are untouched.

local ut = require('nvim_config.util.map')

local M = {}

local function toggled(line)
    local indent, marker, rest = line:match('^(%s*)([%-%*%+]%s+)(.*)$')
    if not indent then
        indent, marker, rest = line:match('^(%s*)(%d+[%.%)]%s+)(.*)$')
    end
    if not indent then return line end

    local box, tail = rest:match('^%[(.)%](.*)$')
    if box then
        local new_box = box == ' ' and 'x' or ' '
        return indent .. marker .. '[' .. new_box .. ']' .. tail
    end
    return indent .. marker .. '[ ] ' .. rest
end

-- Rows [first, last] (0-based) are replaced in one call; only changed lines are written back.
local function toggle_rows(buf, first, last)
    local lines = vim.api.nvim_buf_get_lines(buf, first, last + 1, false)
    local out, changed = {}, false
    for i, line in ipairs(lines) do
        out[i] = toggled(line)
        changed = changed or out[i] ~= line
    end
    if changed then vim.api.nvim_buf_set_lines(buf, first, first + #lines, false, out) end
end

function M.toggle_visual()
    local buf = vim.api.nvim_get_current_buf()
    toggle_rows(buf, vim.fn.line("'<") - 1, vim.fn.line("'>") - 1)
end

function M.setup(_)
    local group = vim.api.nvim_create_augroup('rendermark_checkbox', { clear = true })
    vim.api.nvim_create_autocmd('FileType', {
        group = group,
        pattern = { 'markdown', 'markdown.mdx' },
        callback = function(args)
            local buf = args.buf
            ut.nnoremap('<C-Space>', function()
                local row = vim.api.nvim_win_get_cursor(0)[1] - 1
                toggle_rows(buf, row, row)
            end, { buffer = buf })
            ut.xnoremap('<C-Space>', ':<C-u>lua require("nvim_config.rendermark.checkbox").toggle_visual()<CR>',
                { buffer = buf })
        end,
    })
end

return M
