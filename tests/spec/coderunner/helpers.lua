local M = {}

function M.write(path, content)
    vim.fn.mkdir(vim.fs.dirname(path), 'p')
    local f = assert(io.open(path, 'wb'))
    f:write(content or ''); f:close()
    return path
end

function M.workspace()
    local root = vim.fs.normalize(vim.fn.tempname())
    vim.fn.mkdir(root .. '/.git', 'p')
    return root
end

function M.buffer(root, content)
    local path = M.write(root .. '/note.md', content)
    local buf = vim.fn.bufadd(path)
    vim.fn.bufload(buf)
    return buf
end

function M.wait(predicate, timeout)
    assert(vim.wait(timeout or 5000, predicate, 10), 'coderunner wait timed out')
end

function M.tool(...)
    local argv = { vim.v.progpath, '-u', 'NONE', '-i', 'NONE', '-l',
        vim.fs.joinpath(vim.fn.getcwd(), 'tests/fixtures/coderunner/tool.lua') }
    vim.list_extend(argv, { ... })
    return argv
end

return M
