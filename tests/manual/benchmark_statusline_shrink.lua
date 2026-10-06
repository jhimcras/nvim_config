-- Run in a terminal: nvim -u NONE -i NONE -n -c 'luafile tests/manual/benchmark_statusline_shrink.lua'
-- Results: /tmp/statusline_shrink_benchmark.json (override with STATUSLINE_BENCH_OUTPUT).
vim.opt.rtp:prepend(vim.fn.getcwd())
vim.o.swapfile = false
vim.o.laststatus = 2
package.loaded['nvim_config.prjroot'] = {
    GetProjectRoot = function() return '/tmp/statusline-benchmark' end,
}
package.loaded['nvim_config.git'] = { git_branch_commit = function() return 'benchmark-branch' end }
local status = require('nvim_config.status')
local counts = { search = 0, lsp = 0, entry = 0 }
local searchcount = vim.fn.searchcount
vim.fn.searchcount = function(opts)
    counts.search = counts.search + 1
    return searchcount(opts)
end
-- Deterministic long LSP progress, without a language server or external process.
status.lsp = function()
    counts.lsp = counts.lsp + 1
    return 'indexing: benchmark workspace 1234/9999'
end
_G.StatuslineBenchmarkEntry = function()
    counts.entry = counts.entry + 1
    return status.statusline_entry()
end
local buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_name(buf, '/tmp/statusline-benchmark/deep/directory/long_filename_for_shrinking.lua')
local lines = {}
for i = 1, 5000 do lines[i] = 'benchmark needle needle needle ' .. i end
vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
vim.bo.fileencoding = 'utf-8'
vim.fn.setreg('/', 'needle')
vim.o.hlsearch = true
vim.v.hlsearch = 1
vim.cmd('vsplit')
vim.cmd('vsplit')
vim.cmd('vsplit')
local windows = vim.api.nvim_list_wins()
local qfwin = windows[4]
local qfbuf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_win_set_buf(qfwin, qfbuf)
vim.bo[qfbuf].buftype = 'quickfix'
vim.bo[qfbuf].filetype = 'qf'
vim.w[qfwin].quickfix_title = 'Search: needle in /tmp/statusline-benchmark/deep/directory'
vim.o.statusline = '%!v:lua.StatuslineBenchmarkEntry()'
vim.schedule(function()
    local results = { nvim = vim.version(), rows = {}, iterations = 50, lines = #lines }
    for _, columns in ipairs({ 96, 480 }) do
        vim.o.columns = columns
        vim.cmd('wincmd =')
        for _, active in ipairs({ windows[1], qfwin }) do
            vim.api.nvim_set_current_win(active)
            vim.cmd('redraw!')
            vim.wait(10, function() return false end)
            counts = { search = 0, lsp = 0, entry = 0 }
            local elapsed = 0
            local started = vim.uv.hrtime()
            for _ = 1, results.iterations do
                local before = vim.uv.hrtime()
                vim.cmd('redrawstatus!')
                elapsed = elapsed + vim.uv.hrtime() - before
                -- Give queued redraw/UI work a chance to run; PTY reader drains output.
                vim.wait(1, function() return false end)
            end
            results.rows[#results.rows + 1] = {
                width = vim.api.nvim_win_get_width(active),
                active = active == qfwin and 'quickfix' or 'general',
                redraw_ms = elapsed / 1e6,
                drained_ms = (vim.uv.hrtime() - started) / 1e6,
                calls = counts,
            }
        end
    end
    vim.fn.writefile({vim.json.encode(results)}, os.getenv('STATUSLINE_BENCH_OUTPUT') or '/tmp/statusline_shrink_benchmark.json')
    vim.cmd('qa!')
end)
