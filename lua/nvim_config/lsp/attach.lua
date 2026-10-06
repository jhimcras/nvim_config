local ut = require('nvim_config.util.map')
local api = vim.api
local M = {}

local function general_mappings()
    ut.nnoremap('gW', vim.lsp.buf.workspace_symbol, {'buffer'})

    -- Diagnostics
    ut.nnoremap('[d', function() vim.diagnostic.jump{count=-1, float=true} end, {'buffer'})
    ut.nnoremap(']d', function() vim.diagnostic.jump{count=1, float=true} end, {'buffer'})
    ut.nnoremap('<leader>do', vim.diagnostic.setloclist, {'buffer'})
end

local function reference_highlighting(client, bufnr)
    if not client:supports_method('textDocument/documentHighlight', bufnr) then return end
    local group = api.nvim_create_augroup('lsp_reference_highlight_' .. bufnr, { clear = true })
    api.nvim_create_autocmd('CursorHold', { group = group, buffer = bufnr, callback = function() vim.lsp.buf.document_highlight() end })
    api.nvim_create_autocmd('CursorHoldI', { group = group, buffer = bufnr, callback = function() vim.lsp.buf.document_highlight() end })
    api.nvim_create_autocmd('CursorMoved', { group = group, buffer = bufnr, callback = function() vim.lsp.buf.clear_references() end })
end

-- On Windows fugitive buffers read `fugitive:\\\D:\...`; normalize slashes before
-- probing for a scheme.
local function has_uri_scheme(bufnr)
    local name = vim.api.nvim_buf_get_name(bufnr):gsub('\\', '/')
    return name:match('^%a[%w+.-]*://') ~= nil
end

function M.make_on_attach(extras)
    return function(client, bufnr)
        if vim.bo[bufnr].buftype ~= '' or has_uri_scheme(bufnr) then
            vim.lsp.buf_detach_client(bufnr, client.id)
            return
        end
        general_mappings()
        reference_highlighting(client, bufnr)
        if extras then extras(client, bufnr) end
    end
end

return M
