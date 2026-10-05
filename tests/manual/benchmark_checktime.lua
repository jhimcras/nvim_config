-- CHECKTIME_INIT=/tmp/checktime_before_init.lua nvim --headless -i NONE -u NONE -l tests/manual/benchmark_checktime.lua
-- Defaults to init.lua; loads only its file-reloading setup function.
local source = table.concat(vim.fn.readfile(os.getenv('CHECKTIME_INIT') or 'init.lua'), '\n')
local setup = assert(source:match('(local function SetAutoChangedFileReloading%(%).*\nend)\n\nlocal function C_CPP_HeaderCorrection'))
-- Execute the requested scan outside the autocmd: Neovim defers an all-buffer
-- checktime while autocmd_busy, whereas a numbered check runs immediately.
local pending
_G.checktime_benchmark_cmd = { checktime = function(buffer) pending = buffer or 'all' end }
assert(loadstring('local api, cmd = vim.api, checktime_benchmark_cmd\n' .. setup .. '\nSetAutoChangedFileReloading()'))()
vim.o.autoread = true
vim.o.swapfile = false
vim.notify = function() end
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, 'p')
local buffers, rows = {}, {}
local windows = {}
local function changed(index)
    local path = dir .. '/' .. index
    vim.fn.writefile({ 'changed content ' .. index }, path)
    local stat = assert(vim.uv.fs_stat(path))
    assert(vim.uv.fs_utime(path, stat.atime.sec, stat.mtime.sec + 2))
end
local function contents(index)
    return vim.api.nvim_buf_get_lines(buffers[index], 0, -1, false)[1]
end
local function event(name)
    vim.api.nvim_exec_autocmds(name, { buffer = buffers[1] })
    assert(pending, 'event should request checktime')
    if pending == 'all' then vim.cmd.checktime() else vim.cmd.checktime(pending) end
    pending = nil
end
local ok, err = pcall(function()
    for _, count in ipairs({ 1, 100, 500 }) do
        for index = #buffers + 1, count do
            local path = dir .. '/' .. index
            vim.fn.writefile({ 'original' }, path)
            buffers[index] = vim.fn.bufadd(path)
            vim.bo[buffers[index]].buflisted = true
            vim.fn.bufload(buffers[index])
            windows[index] = vim.api.nvim_open_win(buffers[index], false, {
                relative = 'editor', row = 0, col = 0, width = 1, height = 1,
                style = 'minimal', noautocmd = true,
            })
        end
        vim.api.nvim_set_current_buf(buffers[1])
        for _, name in ipairs({ 'BufEnter', 'CursorHold', 'CursorHoldI', 'FocusGained' }) do
            for _ = 1, 20 do event(name) end
            local samples = {}
            for round = 1, 7 do
                local start = vim.uv.hrtime()
                for _ = 1, 200 do event(name) end
                samples[round] = (vim.uv.hrtime() - start) / 1e6 / 200
            end
            table.sort(samples)
            rows[#rows + 1] = { buffers = count, event = name, median_ms = samples[4] }
        end
    end
    changed(1)
    changed(2)
    event('CursorHold')
    assert(contents(1) == 'changed content 1', 'current buffer should reload')
    local scoped = contents(2) == 'original'
    if os.getenv('CHECKTIME_EXPECT_SCOPED') == '1' then
        assert(scoped, 'idle event should leave other buffers alone')
        for _, name in ipairs({ 'BufEnter', 'CursorHoldI' }) do
            event(name)
            assert(contents(2) == 'original', name .. ' should leave other buffers alone')
        end
    end
    event('FocusGained')
    assert(contents(2) == 'changed content 2', 'focus event should reload other buffers')
    local mode, cmdwintype = vim.fn.mode, vim.fn.getcmdwintype
    for _, guard in ipairs({ 'insert', 'command-window' }) do
        vim.fn.mode = function() return guard == 'insert' and 'i' or 'n' end
        vim.fn.getcmdwintype = function() return guard == 'command-window' and ':' or '' end
        for _, name in ipairs({ 'BufEnter', 'CursorHold', 'CursorHoldI', 'FocusGained' }) do
            vim.api.nvim_exec_autocmds(name, { buffer = buffers[1] })
            assert(pending == nil, guard .. ' should skip checktime')
        end
    end
    vim.fn.mode, vim.fn.getcmdwintype = mode, cmdwintype
    print(vim.json.encode({ nvim = tostring(vim.version()), scoped = scoped, rows = rows }))
end)
for _, window in ipairs(windows) do vim.api.nvim_win_close(window, true) end
for _, buffer in ipairs(buffers) do
    vim.api.nvim_buf_delete(buffer, { force = true })
end
vim.fn.delete(dir, 'rf')
assert(ok, err)
