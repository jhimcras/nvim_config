local util_buffer = require('nvim_config.util.buffer')
local components = require('nvim_config.status.components')
local layouts = require('nvim_config.status.layouts')
local M = {
    lsp = require('nvim_config.lsp.status').summary,
    current_function = require('nvim_config.symbol').current_function,
}

function M.titlecontext()
    local session = vim.fn.fnamemodify(vim.v.this_session, ':t:r')
    if session ~= '' then
        return session
    end
    return vim.fn.fnamemodify(vim.fn.getcwd(), ':~')
end


local function get_entry_func(buftype, filetype, protocol)
    local components = layouts

    if components[protocol] then
        return components[protocol]
    elseif components[buftype] then
        return components[buftype]
    elseif components[filetype] then
        return components[filetype]
    end

    return components.general
end

function M.statusline_entry()
    local winid = vim.g.statusline_winid or 0
    local bufnr = vim.api.nvim_win_get_buf(winid)
    local protocol = util_buffer.GetBufferProtocol(bufnr)
    local w = vim.api.nvim_win_get_width(winid)
    local activation = winid == vim.api.nvim_get_current_win()
    local entryfunc = get_entry_func(vim.bo[bufnr].buftype, vim.bo[bufnr].filetype, protocol)
    local is_read = require('nvim_config.read_mode').is_active(winid)
    local mode = is_read and 'read' or vim.fn.mode()
    local tree = entryfunc(activation, mode, winid)

    local excluded = {}
    -- Cache full/compact text for this render only, including empty results.
    local ctx = { api = M, excluded = excluded, candidates = {}, cache = {} }
    local result = components.make_statusline_text(bufnr, winid, tree, '', ctx)
    if components.measure_sl_text(result) > w then
        table.sort(ctx.candidates, function(a, b)
            if a.priority ~= b.priority then return a.priority < b.priority end
            return a.order < b.order
        end)
        for _, c in ipairs(ctx.candidates) do
            if not excluded[c.fn] then
                excluded[c.fn] = true
                result = components.make_statusline_text(bufnr, winid, tree, '', ctx)
                if components.measure_sl_text(result) <= w then break end
            end
        end
    end

    return result
end

function M.setup()
    -- Skip in tests (headless UI errors).
    if vim.g.is_testing then return end

    vim.o.laststatus = 2
    vim.o.statusline = "%!v:lua.require'nvim_config.status'.statusline_entry()"

end

return M
