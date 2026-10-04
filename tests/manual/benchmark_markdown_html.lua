-- Run: nvim --headless -u tests/minimal_init.lua -l tests/manual/benchmark_markdown_html.lua
-- Optional first argument: path to an older html.lua implementation.
local html = arg[1] and dofile(arg[1]) or require('rendermark.html')
local uv = vim.uv
local get_lines = vim.api.nvim_buf_get_lines
local parse = vim.treesitter.get_parser
local reads, parses = 0, 0
vim.api.nvim_buf_get_lines = function(buf, first, last, strict)
    if first == 0 and last == -1 then reads = reads + 1 end
    return get_lines(buf, first, last, strict)
end
vim.treesitter.get_parser = function(...)
    parses = parses + 1
    return parse(...)
end
print('kind,lines,median_ms,p95_ms,full_reads_per_edit,parser_requests_per_edit')
for _, kind in ipairs({ 'plain', 'sparse', 'dense' }) do
    for _, count in ipairs({ 1000, 10000, 50000 }) do
        local buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_win_set_buf(0, buf)
        local lines = {}
        for i = 1, count do
            lines[i] = (kind == 'dense' or (kind == 'sparse' and i % 1000 == 10))
                and '<mark>text</mark> before<br>after' or 'ordinary markdown text'
        end
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
        html.refresh(buf, 0, { { 0, 20 } })
        local times = {}
        reads, parses = 0, 0
        for i = 1, 25 do
            vim.api.nvim_buf_set_lines(buf, 0, 1, false, { 'edited text ' .. i })
            collectgarbage('collect')
            local start = uv.hrtime()
            html.refresh(buf, 0, { { 0, 20 } })
            times[i] = (uv.hrtime() - start) / 1e6
        end
        table.sort(times)
        print(string.format('%s,%d,%.3f,%.3f,%.1f,%.1f',
            kind, count, times[13], times[24], reads / 25, parses / 25))
        vim.api.nvim_buf_delete(buf, { force = true })
    end
end
vim.cmd('qa!')
