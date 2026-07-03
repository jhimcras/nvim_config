local M = {}

local ut = require 'util'

local function run_jq(args, line1, line2)
    local lines = vim.api.nvim_buf_get_lines(0, line1 - 1, line2, false)
    local input = table.concat(lines, '\n')
    local out = vim.fn.systemlist(args, input)
    if vim.v.shell_error ~= 0 then
        vim.notify(table.concat(out, '\n'), vim.log.levels.ERROR)
        return
    end
    vim.api.nvim_buf_set_lines(0, line1 - 1, line2, false, out)
end

function M.pretty(line1, line2)
    run_jq({ 'jq', '.' }, line1, line2)
end

function M.oneline(line1, line2)
    run_jq({ 'jq', '-c', '.' }, line1, line2)
end

function M.setup()
    if vim.fn.executable('jq') ~= 1 then return end

    local api = vim.api
    api.nvim_create_user_command('JsonPretty', function(t) M.pretty(t.line1, t.line2) end, { range = '%' })
    api.nvim_create_user_command('JsonOneline', function(t) M.oneline(t.line1, t.line2) end, { range = '%' })

    api.nvim_create_autocmd('FileType', { pattern = 'json', callback = function()
        ut.nnoremap('<leader>jp', '<cmd>JsonPretty<cr>', { 'buffer' })
        ut.nnoremap('<leader>jo', '<cmd>JsonOneline<cr>', { 'buffer' })
        ut.xnoremap('<leader>jp', ':JsonPretty<cr>', { 'buffer' })
        ut.xnoremap('<leader>jo', ':JsonOneline<cr>', { 'buffer' })
    end })
end

return M
