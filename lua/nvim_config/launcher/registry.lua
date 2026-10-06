local M = {}

M.processes = {}

function M.list()
    local processes = {}
    for k, v in pairs(M.processes) do
        local p = vim.tbl_extend('force', v, { key = k })
        table.insert(processes, p)
    end
    return processes
end

function M.register(key, proc_info)
    M.processes[key] = proc_info
end

function M.unregister(key)
    M.processes[key] = nil
end

function M.terminate(key)
    local proc = M.processes[key]
    if not proc then return end
    if proc.type == 'terminal' then
        vim.fn.jobstop(proc.job_id)
    elseif proc.terminate then
        proc.terminate(15)
    elseif proc.handle and not proc.handle:is_closing() and type(proc.handle.kill) == 'function' then
        proc.handle:kill(15)
    end
    M.processes[key] = nil
end

return M
