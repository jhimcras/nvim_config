-- nvim -l tool.lua MODE [ARGS...]. Keep stdout free of Neovim UI output.
-- Bypass Windows text-mode newline translation and Ctrl-Z EOF handling.
local function write(fd, bytes)
    local offset = 1
    while offset <= #bytes do
        offset = offset + assert(vim.uv.fs_write(fd, bytes:sub(offset), -1))
    end
end

local function stdin()
    local chunks = {}
    while true do
        local bytes = assert(vim.uv.fs_read(0, 4096, -1))
        if bytes == '' then break end
        chunks[#chunks + 1] = bytes
    end
    return table.concat(chunks)
end

local mode = arg[1]
if mode == 'echo' then
    local f = assert(io.open(arg[2], 'rb'))
    local bytes = f:read('*a'); f:close()
    write(1, bytes)
elseif mode == 'stdin' then
    write(1, stdin())
elseif mode == 'exit' then
    write(1, 'step ' .. arg[2] .. '\n')
    os.exit(tonumber(arg[2]))
elseif mode == 'sleep-ms' or mode == 'hang' then
    vim.uv.sleep(mode == 'hang' and 3600000 or tonumber(arg[2]))
elseif mode == 'emit-wait' then
    write(1, 'before\n')
    write(2, 'warning\n')
    vim.uv.sleep(3600000)
elseif mode == 'flood' then
    local remaining = tonumber(arg[2])
    while remaining > 0 do
        local n = math.min(4096, remaining)
        write(1, string.rep('o', n))
        write(2, string.rep('e', n))
        remaining = remaining - n
    end
elseif mode == 'dump' then
    local args = {}
    for i = 2, #arg do args[#args + 1] = arg[i] end
    write(1, vim.json.encode({ args = args, cwd = vim.uv.cwd(),
        var = vim.env.CODERUNNER_TEST_VAR, path = vim.env.PATH, stdin = stdin() }))
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
