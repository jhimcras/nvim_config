local M = {}

M.SymError = ' '
M.SymWarn = ' '
M.SymInfo = ' '
M.SymHint = ' '
-- M.SymError = '█'
-- M.SymWarn = '▆'
-- M.SymInfo = '■'
-- M.SymHint = '▁'

M.progress_state = require('nvim_config.lsp.progress').progress_state

function M.summary(bufnr)
    bufnr = bufnr or 0
    local clients = vim.lsp.get_clients{bufnr = bufnr}
    if next(clients) == nil then
        return ''
    end
    local ls = M
    local S = vim.diagnostic.severity
    local counts = vim.diagnostic.count(bufnr)
    local parts = {}
    for _, seg in ipairs({
        { counts[S.ERROR], ls.SymError },
        { counts[S.WARN],  ls.SymWarn  },
        { counts[S.INFO],  ls.SymInfo  },
        { counts[S.HINT],  ls.SymHint  },
    }) do
        if seg[1] and seg[1] > 0 then
            parts[#parts + 1] = seg[2] .. seg[1]
        end
    end
    -- vim.lsp.status() concatenates every buffered report; keep only the newest.
    local prog = ''
    for _, c in ipairs(clients) do
        for progress in c.progress do
            local value = progress.value
            if type(value) == 'table' and value.kind then
                prog = value.message and (value.title .. ': ' .. value.message)
                    or value.title
            end
        end
    end
    prog = vim.trim(prog)
    if prog ~= '' then
        parts[#parts + 1] = prog
    else
        local any_running, any_done = false, false
        for _, c in ipairs(clients) do
            local state = ls.progress_state[c.id]
            if state == 'running' then any_running = true end
            if state == 'done' then any_done = true end
        end
        if any_done and not any_running and #parts == 0 then
            parts[#parts + 1] = '✓'
        end
    end
    return table.concat(parts, ' ')
end

return M
