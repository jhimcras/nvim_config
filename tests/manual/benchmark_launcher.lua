-- LAUNCHER_BENCH_SOURCE points to a directory containing ansi_parser.lua and launcher/init.lua.
-- For a namespaced checkout use its lua/nvim_config directory.
-- Run: nvim --headless -i NONE -u NONE -l tests/manual/benchmark_launcher.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local source = os.getenv('LAUNCHER_BENCH_SOURCE')
if source then
    vim.opt.rtp:prepend(vim.fn.fnamemodify(source, ':h:h'))
    local launcher_source = source .. '/launcher/init.lua'
    if vim.fn.filereadable(launcher_source) == 0 then launcher_source = source .. '/launcher.lua' end
    package.loaded['nvim_config.ansi_parser'] = dofile(source .. '/ansi_parser.lua')
    package.loaded['nvim_config.launcher'] = dofile(launcher_source)
end
local launcher = require('nvim_config.launcher')
local util = require('nvim_config.util.job')
local callbacks
util.AsyncProcess = function(_, _, _, opts)
    callbacks = opts
    return 1, function() end, function() end, {}
end
package.loaded['nvim_config.spinner'] = nil
local rows = {}
for _, count in ipairs({1000, 2000, 4000}) do
    local samples = {}
    for trial = 1, 3 do
        local buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_win_set_buf(0, buf)
        launcher.Launch('mock', {}, '.', nil, nil, nil, 'use', buf, nil, 'bench', {
            { pattern = '(file%d+%.cpp):(%d+)', extract = {'filename', 'row'}, highlight = {[0] = '#ff1234'} },
        })
        local start = vim.uv.hrtime()
        for i = 1, count do
            callbacks.onread(nil, '\27[31mfile' .. i .. '.cpp:42\27[0m\n')
            -- Deterministic bursts: 100 read callbacks per UI turn.
            if i % 100 == 0 then vim.wait(0, function() return false end) end
        end
        vim.wait(0, function() return false end)
        callbacks.onexit(0, 0)
        samples[trial] = (vim.uv.hrtime() - start) / 1e6
        assert(#vim.b[buf].launcher_matches == count)
        assert(vim.api.nvim_buf_line_count(buf) == count + 1)
        vim.api.nvim_buf_delete(buf, {force = true})
    end
    table.sort(samples)
    rows[#rows + 1] = {chunks = count, median_ms = samples[2]}
end
local ansi = {}
for _, size in ipairs({1024, 10240, 55296}) do
    local text = '\27[31m' .. string.rep('x', size) .. '\27[0m'
    local start = vim.uv.hrtime()
    for _ = 1, 20 do assert(#require('nvim_config.ansi_parser').parse_ansi(text) == size) end
    ansi[#ansi + 1] = {bytes = size, mean_ms = (vim.uv.hrtime() - start) / 1e6 / 20}
end
print(vim.json.encode({nvim = tostring(vim.version()), launcher = rows, ansi = ansi}))
vim.cmd('qa!')
