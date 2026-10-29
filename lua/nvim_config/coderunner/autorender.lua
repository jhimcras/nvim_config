local M = {}
local api = vim.api
local blocks = require('nvim_config.coderunner.blocks')
local render = require('nvim_config.coderunner.render')
local runner = require('nvim_config.coderunner.run')
local states = {}

local function markdown(buf)
    local name = api.nvim_buf_get_name(buf):lower()
    return vim.bo[buf].filetype == 'markdown' or name:match('%.md$') or name:match('%.markdown$')
end
local function saved(buf, state)
    local path, root = api.nvim_buf_get_name(buf), runner.root(buf)
    local text = require('nvim_config.coderunner.cache').read(path)
    if not text then return nil end
    if state and state.text == text and state.path == path and state.root == root then return state.blocks end
    local list = blocks.parse(text, { path = path, root = root })
    if state and list then state.text, state.path, state.root, state.blocks = text, path, root, list end
    return list
end
local function snapshot(list, state)
    local cfg, trust
    if list and list[1] then
        cfg, trust = require('nvim_config.coderunner').resolve(list[1].root, false)
        if state.snapshot_blocks == list and vim.deep_equal(state.config, cfg)
            and state.trust_state == trust.state and state.trust_hash == trust.hash then return state.baseline end
    end
    local result = {}
    for _, block in ipairs(list or {}) do
        local desc = render.describe(block, { batch = true })
        if desc then result[block.key] = { block = block, desc = desc } end
    end
    state.snapshot_blocks, state.config = list, cfg
    state.trust_state, state.trust_hash = trust and trust.state, trust and trust.hash
    return result
end
local function stop(item)
    if item then
        item.cancelled = true
        if item.job and not item.job.result then item.job.cancel() end
    end
end
function M.close(buf)
    local state = states[buf]
    if not state then return end
    states[buf] = nil
    for _, item in pairs(state.pending) do stop(item) end
    for _, item in pairs(state.open) do stop(item) end
    render.cancel_buffer(buf)
end
function M.read(buf)
    if not api.nvim_buf_is_valid(buf) or not markdown(buf) then return end
    M.close(buf)
    local state = { pending = {}, open = {}, failed = {} }
    state.baseline = snapshot(saved(buf, state), state)
    states[buf] = state
end
local function enqueue(buf, state, bucket, block, desc, opts)
    local item = { key = desc.key }
    bucket[block.key] = item
    vim.defer_fn(function()
        if item.cancelled or states[buf] ~= state or not api.nvim_buf_is_valid(buf)
            or not api.nvim_buf_is_loaded(buf) then return end
        -- Configuration/trust may change during debounce. start revalidates it.
        local current = render.describe(block, opts)
        if not current or current.key ~= item.key
            or opts.global_only and not current.config.render_on_open
            or not opts.global_only and not current.config.auto_render then
            bucket[block.key] = nil; return
        end
        local job = render.start(block, opts, function(done)
            if states[buf] ~= state or item.cancelled then return end
            if bucket[block.key] == item then bucket[block.key] = nil end
            if done.result.status == 'failed' then state.failed[block.key] = item.key
            elseif done.result.status == 'ready' then state.failed[block.key] = nil end
        end)
        item.job = job
        if not job then bucket[block.key] = nil end
    end, desc.config.auto_render_debounce)
end
function M.write(buf)
    if not api.nvim_buf_is_valid(buf) or not markdown(buf) then return end
    if not states[buf] then states[buf] = { baseline = {}, pending = {}, open = {}, failed = {} } end
    local state = states[buf]
    local list = saved(buf, state)
    if not list then return end
    local current = snapshot(list, state)
    for key, pending in pairs(state.pending) do
        if not current[key] or current[key].desc.key ~= pending.key then stop(pending); state.pending[key] = nil end
    end
    for key, pending in pairs(state.open) do
        if not current[key] or current[key].desc.key ~= pending.key then stop(pending); state.open[key] = nil end
    end
    for key, item in pairs(current) do
        local previous = state.baseline[key]
        if not previous or previous.desc.key ~= item.desc.key then
            stop(state.open[key]); state.open[key] = nil
            state.failed[key] = nil
            if item.desc.config.auto_render then
                enqueue(buf, state, state.pending, item.block, item.desc, { buf = buf, batch = true })
            end
        end
    end
    state.baseline = current
end
function M.visible(buf, win)
    if not api.nvim_buf_is_valid(buf) or not markdown(buf) then return end
    if not states[buf] then M.read(buf) end
    local state = states[buf]
    if not state then return end
    win = win or api.nvim_get_current_win()
    if not api.nvim_win_is_valid(win) or api.nvim_win_get_buf(win) ~= buf then return end
    local first, last = unpack(api.nvim_win_call(win, function()
        return { vim.fn.line('w0') - 1, vim.fn.line('w$') - 1 }
    end))
    local list = blocks.get(buf, runner.root(buf))
    for _, block in ipairs(list or {}) do
        if block.start_row <= last and block.end_row >= first then
            local opts = { buf = buf, batch = true, global_only = true }
            local desc = render.describe(block, opts)
            if desc and desc.config.render_on_open then
                local found = render.lookup(block, opts)
                local existing = state.open[block.key] or state.pending[block.key]
                if existing and existing.key ~= desc.key then stop(existing); state.open[block.key] = nil; existing = nil end
                if found.status ~= 'pending' and (not found.path or found.stale)
                    and not existing and state.failed[block.key] ~= desc.key then
                    enqueue(buf, state, state.open, block, desc, opts)
                end
            end
        end
    end
end
function M.setup()
    for buf in pairs(states) do M.close(buf) end
    local group = api.nvim_create_augroup('CodeRunnerAutoRender', { clear = true })
    api.nvim_create_autocmd({ 'BufReadPost', 'BufNewFile' }, { group = group, callback = function(a) M.read(a.buf) end })
    api.nvim_create_autocmd('BufWritePost', { group = group, callback = function(a) M.write(a.buf) end })
    api.nvim_create_autocmd('BufWinEnter', { group = group, callback = function(a) M.visible(a.buf) end })
    api.nvim_create_autocmd({ 'BufUnload', 'BufDelete' }, { group = group, callback = function(a) M.close(a.buf) end })
    for _, buf in ipairs(api.nvim_list_bufs()) do
        if api.nvim_buf_is_loaded(buf) then M.read(buf) end
    end
end
return M
