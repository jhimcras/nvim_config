local M = {}

local ut = require('nvim_config.util.map')

-- First duplicated object key in the JSON text, or nil.
local function find_duplicate_key(text)
    local stack = {}
    local pos = 1
    while true do
        local i = text:find('["{}%[%]]', pos)
        if not i then return end
        local c = text:sub(i, i)
        local top = stack[#stack]
        if c == '"' then
            local j = i
            repeat
                j = text:find('["\\]', j + 1)
                if not j then return end
                if text:sub(j, j) == '\\' then j = j + 1 end
            until text:sub(j, j) == '"'
            -- A string right after '{' or ',' inside an object is a key.
            if top and top.obj and text:sub(math.max(1, i - 200), i - 1):find('[{,]%s*$') then
                local ok, key = pcall(vim.json.decode, text:sub(i, j))
                key = ok and key or text:sub(i, j)
                if top.keys[key] then return key end
                top.keys[key] = true
            end
            pos = j + 1
        else
            if c == '{' then stack[#stack+1] = { obj = true, keys = {} }
            elseif c == '[' then stack[#stack+1] = {}
            else stack[#stack] = nil end
            pos = i + 1
        end
    end
end

local function run_jq(args, line1, line2)
    local lines = vim.api.nvim_buf_get_lines(0, line1 - 1, line2, false)
    local input = table.concat(lines, '\n')
    local dup = find_duplicate_key(input)
    if dup then
        vim.notify('Duplicate JSON key "' .. dup .. '": buffer left unchanged', vim.log.levels.WARN)
        return
    end
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
    api.nvim_create_autocmd('FileType', { pattern = 'json', callback = function()
        ut.nnoremap('<leader>jp', '<cmd>JsonPretty<cr>', { 'buffer' })
        ut.nnoremap('<leader>jo', '<cmd>JsonOneline<cr>', { 'buffer' })
        ut.xnoremap('<leader>jp', ':JsonPretty<cr>', { 'buffer' })
        ut.xnoremap('<leader>jo', ':JsonOneline<cr>', { 'buffer' })
    end })
end

return M
