local M = {}

function M.GetWorkspaceSymbols(query)
    --local workspace_symbols
    local pull_result = function(_, _, result, _) workspace_symbols = result; print('number of symbols: ' .. #result) end
    if not query then query = '' end
    --local _, cancel_function = vim.lsp.buf_request(0, 'workspace/symbol', {query = query}, pull_result)
    local workspace_symbols = vim.lsp.buf_request_sync(0, 'workspace/symbol', {query = query}, 10000)
    for _, val in pairs(workspace_symbols) do
        return val.result
    end
    --return workspace_symbols
end

function M.GetWSTextList(workspace_symbols)
    local ws_text_list = {}
    for _, val in ipairs(workspace_symbols) do
        ws_text_list[#ws_text_list+1] = string.format("%s|%d|%d|%s", val.location.uri:sub(9), val.location.range.start.line+1, val.location.range.start.character+1, val.name)
    end
    return ws_text_list
end

function M.GetCurrentWSSymbolList(query)
    local workspace_symbols = M.GetWorkspaceSymbols(query)
    return M.GetWSTextList(workspace_symbols)
end

return M
