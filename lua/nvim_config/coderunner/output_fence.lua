local M = {}
local api = vim.api
local ns = api.nvim_create_namespace('coderunner.output')
local blocks = require('nvim_config.coderunner.blocks')

local function lines(buf, block)
    return api.nvim_buf_get_lines(buf, block.start_row, block.end_row + 1, false)
end

function M.capture(buf, block)
    return { buf = buf, root = block.root, source = lines(buf, block),
        output = block.output and lines(buf, block.output), top_level = block.top_level,
        mark = api.nvim_buf_set_extmark(buf, ns, block.start_row, 0, { right_gravity = true }) }
end

function M.clear(snapshot)
    if snapshot and api.nvim_buf_is_valid(snapshot.buf) then
        api.nvim_buf_del_extmark(snapshot.buf, ns, snapshot.mark)
    end
end

function M.apply(snapshot, result)
    local buf = snapshot.buf
    if not api.nvim_buf_is_loaded(buf) then return false, 'document is closed' end
    if not vim.bo[buf].modifiable then return false, 'document is not modifiable' end
    if not snapshot.top_level then return false, 'output insertion supports only top-level fences' end
    local pos = api.nvim_buf_get_extmark_by_id(buf, ns, snapshot.mark, {})
    local current, err = blocks.get(buf, snapshot.root)
    if not current then return false, err end
    local block
    for _, b in ipairs(current) do if b.start_row == pos[1] then block = b; break end end
    if not block or not block.closed or not vim.deep_equal(snapshot.source, lines(buf, block)) then
        return false, 'source changed while running'
    end
    local output = block.output and lines(buf, block.output)
    if not vim.deep_equal(snapshot.output, output) then return false, 'output changed while running' end
    local stdout, longest = result.stdout or '', 0
    for run in stdout:gmatch('`+') do longest = math.max(longest, #run) end
    local fence = string.rep('`', math.max(3, longest + 1))
    local replacement = { fence .. 'output' .. (result.status == 'success' and '' or ' {.error}') }
    if stdout ~= '' then
        local body = vim.split(stdout, '\n', { plain = true })
        if body[#body] == '' then table.remove(body) end
        vim.list_extend(replacement, body)
    end
    replacement[#replacement + 1] = fence
    local first, last
    if block.output then first, last = block.output.start_row, block.output.end_row + 1
    else
        first, last = block.end_row + 1, block.end_row + 1
        table.insert(replacement, 1, '')
    end
    api.nvim_buf_set_lines(buf, first, last, false, replacement)
    return true
end

return M
