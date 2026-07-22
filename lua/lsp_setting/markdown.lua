local M = {}

function M.setup()
    if vim.fn.executable('markdown-oxide') then
        local capabilities = vim.lsp.protocol.make_client_capabilities()
        capabilities.workspace.didChangeWatchedFiles.dynamicRegistration = true

        vim.lsp.config('markdown_oxide', {
            cmd = { 'markdown-oxide' },
            filetypes = { 'markdown' },
            root_markers = { '.git', '.obsidian', '.moxide.toml' },
            capabilities = capabilities,
        })
        vim.lsp.enable('markdown_oxide')
    end
end

return M
