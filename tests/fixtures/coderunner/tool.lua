-- nvim -l tool.lua MODE [ARGS...]. Keep stdout free of Neovim UI output.
local mode = arg[1]
if mode == 'echo' then
    io.stdout:write(assert(io.open(arg[2], 'rb')):read('*a'))
elseif mode == 'stdin' then
    io.stdout:write(io.stdin:read('*a'))
elseif mode == 'exit' then
    io.stdout:write('step ' .. arg[2] .. '\n')
    os.exit(tonumber(arg[2]))
elseif mode == 'sleep-ms' or mode == 'hang' then
    vim.uv.sleep(mode == 'hang' and 3600000 or tonumber(arg[2]))
elseif mode == 'emit-wait' then
    io.stdout:write('before\n'); io.stdout:flush()
    io.stderr:write('warning\n'); io.stderr:flush()
    vim.uv.sleep(3600000)
elseif mode == 'flood' then
    local remaining = tonumber(arg[2])
    while remaining > 0 do
        local n = math.min(4096, remaining)
        io.stdout:write(string.rep('o', n)); io.stdout:flush()
        io.stderr:write(string.rep('e', n)); io.stderr:flush()
        remaining = remaining - n
    end
elseif mode == 'dump' then
    local args = {}
    for i = 2, #arg do args[#args + 1] = arg[i] end
    io.stdout:write(vim.json.encode({ args = args, cwd = vim.uv.cwd(),
        var = vim.env.CODERUNNER_TEST_VAR, path = vim.env.PATH, stdin = io.stdin:read('*a') }))
elseif mode == 'write' then
    local f = assert(io.open(arg[2], 'wb'))
    f:write(arg[3]); f:close()
elseif mode == 'spawn' then
    local child, pid = vim.uv.spawn(vim.v.progpath, {
        args = { '-u', 'NONE', '-i', 'NONE', '-l', arg[0], 'hang' },
        stdio = { 0, 1, 2 },
    }, function() end)
    assert(child, pid)
    local f = assert(io.open(arg[2] .. '.tmp', 'wb'))
    f:write(tostring(pid)); f:close()
    assert(vim.uv.fs_rename(arg[2] .. '.tmp', arg[2]))
    if arg[3] == 'exit' then os.exit(0) end
    vim.uv.sleep(3600000)
else
    error('unknown coderunner fixture mode: ' .. tostring(mode))
end
