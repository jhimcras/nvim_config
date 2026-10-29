local M = {}
local api = vim.api
local blocks = require('nvim_config.coderunner.blocks')
local render = require('nvim_config.coderunner.render')
local runner = require('nvim_config.coderunner.run')
local live, observed = {}, {}

function M.diagrams(buf)
    buf = buf == 0 and api.nvim_get_current_buf() or buf
    if not api.nvim_buf_is_valid(buf) or not api.nvim_buf_is_loaded(buf) then return {} end
    local list = blocks.get(buf, runner.root(buf))
    local items = {}
    for _, block in ipairs(list or {}) do
        if render.describe(block) then
            local found = render.lookup(block)
            items[#items + 1] = { start_row = block.start_row, end_row = block.end_row,
                key = block.key, lang = block.lang, path = found.path, format = found.format,
                stale = found.stale == true, status = found.status,
                error = found.error and found.error:match('^[^\r\n]*') }
        end
    end
    return items
end

function M.request_live(buf, row)
    buf = buf == 0 and api.nvim_get_current_buf() or buf
    if not api.nvim_buf_is_valid(buf) or not api.nvim_buf_is_loaded(buf) then return false end
    local list = blocks.get(buf, runner.root(buf))
    for _, block in ipairs(list or {}) do
        if row >= block.start_row and row <= block.end_row then
            local desc = render.describe(block)
            if not desc then return false end
            live[buf] = live[buf] or {}
            local previous = live[buf][block.key]
            if previous and previous.key == desc.key and not previous.result then return true end
            if previous and not previous.result then previous.cancel() end
            if render.lookup(block).status == 'pending' then return true end
            local job = render.start(block, { buf = buf }, function(done)
                if live[buf] and live[buf][block.key] == done then live[buf][block.key] = nil end
            end)
            live[buf][block.key] = job
            return job ~= nil
        end
    end
    return false
end

local function signature(buf)
    local list = blocks.get(buf, runner.root(buf))
    local out = {}
    for _, block in ipairs(list or {}) do
        out[#out + 1] = { block.key, block.hash, block.start_row, block.end_row, block.duplicate }
    end
    return vim.json.encode(out)
end

function M.setup()
    for _, jobs in pairs(live) do for _, job in pairs(jobs) do job.cancel() end end
    live, observed = {}, {}
    local group = api.nvim_create_augroup('CodeRunnerProvider', { clear = true })
    local function watch(buf)
        if vim.bo[buf].filetype == 'markdown' then observed[buf] = signature(buf) end
    end
    api.nvim_create_autocmd({ 'BufReadPost', 'FileType' }, { group = group, callback = function(a) watch(a.buf) end })
    api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, { group = group, callback = function(a)
        if vim.bo[a.buf].filetype ~= 'markdown' then return end
        local current = signature(a.buf)
        if observed[a.buf] ~= current then
            observed[a.buf] = current
            render.event(a.buf)
        end
    end })
    api.nvim_create_autocmd({ 'BufUnload', 'BufDelete' }, { group = group, callback = function(a)
        for _, job in pairs(live[a.buf] or {}) do job.cancel() end
        live[a.buf], observed[a.buf] = nil, nil
    end })
    for _, buf in ipairs(api.nvim_list_bufs()) do if api.nvim_buf_is_loaded(buf) then watch(buf) end end
end
return M
