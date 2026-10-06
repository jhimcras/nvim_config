-- Run: nvim --headless --clean -c "set lines=50 columns=140" -c "luafile tests/manual/benchmark_markdown_cursor.lua"
-- Compare against an older tree: MD_BENCH_BASELINE=<dir containing lua/> nvim ...
-- Measures the CursorMoved / CursorMovedI / TextChangedI path of rendermark.wrap
-- from the autocmd until its double-deferred refresh has finished.
vim.opt.rtp:prepend(vim.fn.getcwd())
if vim.env.MD_BENCH_BASELINE then vim.opt.rtp:prepend(vim.env.MD_BENCH_BASELINE) end
vim.g.is_testing = true
local print = function(s) io.stdout:write(s .. "\n") end
vim.o.scrolloff = 0

local uv = vim.uv
local counts = { mark = 0, clear = 0 }
for key, name in pairs({ mark = 'nvim_buf_set_extmark', clear = 'nvim_buf_clear_namespace' }) do
    local original = vim.api[name]
    vim.api[name] = function(...) counts[key] = counts[key] + 1; return original(...) end
end

require('nvim_config.rendermark.deco').setup({})
require('nvim_config.rendermark.html').setup()
local wrap = require('nvim_config.rendermark.wrap')
wrap.setup({ max_width = 120 })

local para = 'Lorem ipsum dolor sit amet, **consectetur** adipiscing elit, sed do eiusmod tempor '
    .. 'incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis `nostrud` '
    .. 'exercitation ullamco laboris nisi ut aliquip ex ea commodo [consequat](https://x.y/z).'
local section = {
    '## Section heading',
    '',
    para,
    '',
    '- ' .. para,
    '- [ ] ' .. para,
    '- [x] short checked item',
    '  - nested *item* with text',
    '',
    '> ' .. para,
    '',
    '```lua',
    'local function f(x)',
    '    return x + 1',
    'end',
    '```',
    '',
    '| name | value | description |',
    '| --- | :---: | ---: |',
    '| alpha | 1 | ' .. para:sub(1, 90) .. ' |',
    '| beta | 2 | short |',
    '',
    'Plain short line.',
    '',
}
local lines = {}
while #lines < tonumber(vim.env.MD_BENCH_LINES or 5000) do
    vim.list_extend(lines, section)
end

local buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
vim.bo[buf].filetype = 'markdown'
vim.api.nvim_exec_autocmds('FileType', { pattern = 'markdown' })
local win = vim.api.nvim_get_current_win()

-- Drain wrap's double-deferred refresh with a triple-deferred sentinel.
local function drain()
    local done = false
    vim.schedule(function() vim.schedule(function() vim.schedule(function() done = true end) end) end)
    vim.wait(2000, function() return done end, 0)
end

local function place(top)
    vim.fn.winrestview({ topline = top, lnum = top, col = 0 })
    wrap.refresh(win)
    drain()
end

local function measure(label, steps, step, prep)
    local times = {}
    local before = vim.deepcopy(counts)
    for i = 1, steps do
        if prep then prep(i) end
        collectgarbage('collect')
        local start = uv.hrtime()
        step(i)
        drain()
        times[i] = (uv.hrtime() - start) / 1e6
    end
    table.sort(times)
    local q = function(p) return times[math.max(1, math.ceil(#times * p))] end
    print(string.format('%-12s median %7.3f ms  p95 %7.3f ms  extmarks/step %6.1f  clears/step %5.1f',
        label, q(0.5), q(0.95), (counts.mark - before.mark) / steps,
        (counts.clear - before.clear) / steps))
end

local top = 1201
place(top)
local info = vim.fn.getwininfo(win)[1]
local span = info.botline - info.topline
print(string.format('lines=%d window=%dx%d visible=%d..%d', #lines,
    vim.api.nvim_win_get_width(win), vim.api.nvim_win_get_height(win), info.topline, info.botline))

measure('idle', 40, function() end)

-- j/k inside the window, no scrolling.
place(top)
local row, dir = top, 1
measure('j/k', 60, function()
    row = row + dir
    if row >= top + span - 3 or row <= top then dir = -dir end
    vim.api.nvim_win_set_cursor(win, { row, 0 })
    vim.api.nvim_exec_autocmds('CursorMoved', {})
end)

-- l/h on one row.
place(top)
vim.api.nvim_win_set_cursor(win, { top + 2, 0 })
wrap.refresh(win); drain()
measure('l/h', 60, function(i)
    vim.api.nvim_win_set_cursor(win, { top + 2, i % 40 })
    vim.api.nvim_exec_autocmds('CursorMoved', {})
end)

-- Typing on one row: CursorMovedI + TextChangedI per key. The edit and the
-- reparse the treesitter highlighter does on redraw happen before the clock.
local parser = vim.treesitter.get_parser(buf, 'markdown')
local trow = top + 2
local function type_key(i)
    vim.api.nvim_buf_set_text(buf, trow - 1, 0, trow - 1, 0, { 'x' })
    vim.api.nvim_win_set_cursor(win, { trow, i })
    parser:parse({ top - 1, top + span })
end
local function key_events()
    vim.api.nvim_exec_autocmds('CursorMovedI', {})
    vim.api.nvim_exec_autocmds('TextChangedI', {})
end
place(top)
vim.api.nvim_win_set_cursor(win, { trow, 0 })
wrap.refresh(win); drain()
measure('typing/key', 60, key_events, type_key)

-- 20 keys 30 ms apart, then a pause: CPU of the whole burst minus the same
-- burst with wrap off, so the edits, reparses and waits cancel out.
local function cpu_ms()
    local r = uv.getrusage()
    return (r.utime.sec + r.stime.sec) * 1e3 + (r.utime.usec + r.stime.usec) / 1e3
end
local function burst()
    local start = cpu_ms()
    for i = 1, 20 do
        type_key(i)
        key_events()
        vim.wait(30, function() return false end)
    end
    vim.wait(300, function() return false end)
    return cpu_ms() - start
end
local samples = {}
for k = 1, 5 do
    place(top)
    vim.api.nvim_win_set_cursor(win, { trow, 0 })
    wrap.refresh(win); drain()
    local on = burst()
    vim.b[buf].markdown_visual_wrap = false
    local off = burst()
    vim.b[buf].markdown_visual_wrap = true
    samples[k] = on - off
end
table.sort(samples)
print(string.format('%-12s median %7.3f ms of wrap CPU per 20-key burst', 'typing/burst', samples[3]))

-- Reference: what every event used to cost.
place(top)
measure('full', 30, function()
    vim.api.nvim_exec_autocmds('WinScrolled', {})
end)

vim.cmd('qa!')
