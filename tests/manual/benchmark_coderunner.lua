-- nvim --headless -u NONE -i NONE -l tests/manual/benchmark_coderunner.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
vim.g.is_testing = true
local api, uv = vim.api, vim.uv
local H = require('tests.spec.coderunner.helpers')
local blocks = require('nvim_config.coderunner.blocks')
local auto = require('nvim_config.coderunner.autorender')
local root = H.workspace()
local lines = {}
for i = 1, 200 do
    lines[#lines + 1] = '```dot {#diagram' .. i .. '}'
    lines[#lines + 1] = 'digraph { a -> b }'
    lines[#lines + 1] = '```'
    for _ = 1, 22 do lines[#lines + 1] = 'plain markdown text' end
end
local text = table.concat(lines, '\n') .. '\n'
local buf = H.buffer(root, text)
api.nvim_set_current_buf(buf)
require('nvim_config.coderunner').setup({ auto_render_debounce = '1h', renderers = {
    dot = { match = { 'dot' }, formats = { 'svg' }, cmd = { 'dot', '-Tsvg', '{file}', '-o', '{output}' } },
} })
local reads, parses, commands = 0, 0, 0
local get_lines, parse, command = api.nvim_buf_get_lines, blocks.parse, require('nvim_config.coderunner.command').run
api.nvim_buf_get_lines = function(b, first, last, ...)
    if b == buf and first == 0 and last == -1 then reads = reads + 1 end
    return get_lines(b, first, last, ...)
end
blocks.parse = function(...) parses = parses + 1; return parse(...) end
require('nvim_config.coderunner.command').run = function(...) commands = commands + 1; return command(...) end
local function measure(label, count, action)
    reads, parses, commands = 0, 0, 0
    collectgarbage('collect')
    local start = uv.hrtime()
    for i = 1, count do action(i) end
    print(vim.json.encode({ scenario = label, calls = count, ms_per_call = (uv.hrtime() - start) / 1e6 / count,
        buffer_reads = reads, parses = parses, processes = commands }))
end
blocks.invalidate(buf)
measure('blocks-cold', 1, function() assert(#blocks.get(buf, root) == 200) end)
measure('blocks-cached', 1000, function() assert(#blocks.get(buf, root) == 200) end)
measure('blocks-after-edit', 30, function(i)
    api.nvim_buf_set_lines(buf, 10, 11, false, { 'edited prose ' .. i }); blocks.get(buf, root)
end)
measure('save-unchanged', 30, function() auto.write(buf) end)
measure('save-one-key-changed', 30, function(i)
    lines[2] = 'digraph { a -> b' .. i .. ' }'; H.write(root .. '/note.md', table.concat(lines, '\n') .. '\n')
    auto.write(buf)
end)
auto.close(buf)
api.nvim_buf_get_lines, blocks.parse = get_lines, parse
require('nvim_config.coderunner.command').run = command
api.nvim_buf_delete(buf, { force = true }); vim.fn.delete(root, 'rf')
