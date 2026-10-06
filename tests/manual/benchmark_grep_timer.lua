-- nvim --headless -u NONE -l tests/manual/benchmark_grep_timer.lua
-- Stub only the process/project/launcher; exercise grep and real libuv timers.
vim.opt.rtp:prepend(vim.fn.getcwd())
local exit
package.loaded['nvim_config.util.job'] = {
    AsyncProcess = function(_, _, _, opts)
        exit = opts.onexit
        return 1, function() end, function() return 'running' end
    end,
}
package.loaded['nvim_config.util.map'] = { nnoremap = function() end }
package.loaded['nvim_config.env'] = {}
package.loaded['nvim_config.prjroot'] = { GetCurrentProjectRoot = function() return vim.fn.getcwd() end }
package.loaded['nvim_config.launcher'] = {
    GetRunningProcesses = function() return {} end,
    RegisterProcess = function() end,
    UnregisterProcess = function() end,
}
local starts, ticks, handles = 0, 0, {}
local new_timer = vim.uv.new_timer
vim.uv.new_timer = function()
    local handle = new_timer()
    local proxy = {
        start = function(_, delay, interval, cb)
            starts = starts + 1
            handle:start(delay, interval, function()
                ticks = ticks + 1
                cb()
            end)
        end,
        stop = function() handle:stop() end,
        close = function() handle:close() end,
    }
    handles[#handles + 1] = handle
    return proxy
end
local function active()
    local count = 0
    for _, handle in ipairs(handles) do
        if not handle:is_closing() and handle:is_active() then count = count + 1 end
    end
    return count
end
local grep = require('nvim_config.grep')
local origin = vim.api.nvim_get_current_win()
local rows = {}
for _, scenario in ipairs({ 'exit', 'signal', 'close' }) do
    local row = { scenario = scenario, rounds = 20, active_immediately = 0, idle_ticks = 0 }
    local cpu = os.clock()
    for _ = 1, row.rounds do
        local old_starts = starts
        grep.asyncGrep('needle', false, origin)
        assert(starts == old_starts + 1, 'one timer per search')
        assert(active() == 1, 'one active timer during search')
        vim.wait(130, function() return false end)
        local searching_ticks = ticks
        if scenario == 'close' then
            vim.cmd('lclose')
        else
            exit(0, scenario == 'signal' and 9 or 0)
        end
        row.active_immediately = row.active_immediately + active()
        vim.wait(250, function() return false end)
        row.idle_ticks = row.idle_ticks + ticks - searching_ticks
        assert(active() == 0, 'timer must not leak')
        if scenario == 'close' then exit(0, 0) else vim.cmd('lclose') end
    end
    row.cpu_ms = (os.clock() - cpu) * 1000
    rows[#rows + 1] = row
end
vim.uv.new_timer = new_timer
local output = os.getenv('GREP_BENCH_OUTPUT') or '/tmp/grep_timer_benchmark.json'
vim.fn.writefile({ vim.json.encode({ nvim = tostring(vim.version()), rows = rows }) }, output)
print(vim.fn.readfile(output)[1])
