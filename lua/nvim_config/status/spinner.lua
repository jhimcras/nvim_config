local M = {}
local targets = {}
local timer
local api = vim.api

local function stop_if_empty()
    if timer and next(targets) == nil then
        timer:stop()
        timer:close()
        timer = nil
    end
end

local function tick()
    if not timer then return end
    local buffers, windows = {}, {}
    for key, target in pairs(targets) do
        local valid = target.buf and api.nvim_buf_is_valid(target.buf)
            or target.win and api.nvim_win_is_valid(target.win)
        if not valid then
            targets[key] = nil
        elseif target.buf then
            buffers[target.buf] = true
        else
            windows[target.win] = true
        end
    end
    stop_if_empty()
    for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
        if windows[win] or buffers[api.nvim_win_get_buf(win)] then
            api.nvim__redraw({ win = win, statusline = true })
        end
    end
end

function M.start(target)
    local key = {}
    targets[key] = target
    if not timer then
        timer = vim.uv.new_timer()
        timer:start(0, 120, vim.schedule_wrap(tick))
    end
    return key
end

function M.stop(key)
    if key then targets[key] = nil end
    stop_if_empty()
end

return M
