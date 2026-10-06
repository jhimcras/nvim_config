local api = vim.api
local util_cache = require('nvim_config.util.cache')
local M = {}

-- [client_id] = 'running' | 'done' for progress (e.g. indexing).
M.progress_state = {}

local function update_progress_state(ev)
    local kind = ev.data.params.value.kind
    local client_id = ev.data.client_id
    if kind == 'begin' then
        M.progress_state[client_id] = 'running'
    elseif kind == 'end' then
        local client = vim.lsp.get_client_by_id(client_id)
        if client and next(client.progress.pending) == nil then
            M.progress_state[client_id] = 'done'
        end
    end
end

function M.setup()
    local redrawstatus_throttled = util_cache.throttle(function() vim.cmd.redrawstatus() end, 80)
    api.nvim_create_autocmd({'LspProgress', 'DiagnosticChanged'}, {
        callback = function(ev)
            if ev.event == 'LspProgress' then
                update_progress_state(ev)
            end
            redrawstatus_throttled()
        end,
    })

end

return M
