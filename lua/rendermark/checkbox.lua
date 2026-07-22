-- rendermark checkbox toggle: cycle `[ ]`/`[x]` on the cursor line (or every
-- selected line in Visual mode). Obsidian-compatible syntax — a list marker
-- with no checkbox gets `[ ]` inserted; anything checked (`[x]`, `[X]`, ...)
-- normalizes back to `[ ]`. Lines without a list marker are left untouched.

local ut = require 'util'

local M = {}

local function toggle_line(buf, row)
    local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
    if not line then return end

    local indent, marker, rest = line:match('^(%s*)([%-%*%+]%s+)(.*)$')
    if not indent then
        indent, marker, rest = line:match('^(%s*)(%d+[%.%)]%s+)(.*)$')
    end
    if not indent then return end

    local box, tail = rest:match('^%[(.)%](.*)$')
    local new_line
    if box then
        local new_box = box == ' ' and 'x' or ' '
        new_line = indent .. marker .. '[' .. new_box .. ']' .. tail
    else
        new_line = indent .. marker .. '[ ] ' .. rest
    end
    vim.api.nvim_buf_set_lines(buf, row, row + 1, false, { new_line })
end

function M.toggle_visual()
    local buf = vim.api.nvim_get_current_buf()
    local first, last = vim.fn.line("'<"), vim.fn.line("'>")
    for row = first - 1, last - 1 do
        toggle_line(buf, row)
    end
end

function M.setup(_)
    local group = vim.api.nvim_create_augroup('rendermark_checkbox', { clear = true })
    vim.api.nvim_create_autocmd('FileType', {
        group = group,
        pattern = { 'markdown', 'markdown.mdx' },
        callback = function(args)
            local buf = args.buf
            ut.nnoremap('<C-Space>', function()
                toggle_line(buf, vim.api.nvim_win_get_cursor(0)[1] - 1)
            end, { buffer = buf })
            ut.xnoremap('<C-Space>', ':<C-u>lua require("rendermark.checkbox").toggle_visual()<CR>',
                { buffer = buf })
        end,
    })
end

return M
