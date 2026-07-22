local lsp_setting = require('lsp_setting')

local M = {}

local on_attach = lsp_setting.make_on_attach(nil)

function M.setup()
    -- vim.lsp.config.jedi_lanuage_server = {
    --     on_init = on_init,
    --     on_attach = on_attach,
    --     cmd = {"jedi-language-server"},
    --     filetypes = { 'python' },
    -- }
    -- vim.lsp.enable('jedi_lanuage_server')
    vim.lsp.config.ty = {
        on_init = lsp_setting.on_init,
        on_attach = on_attach,
        cmd = {'ty', 'server'},
        filetypes = { 'python' },
    }
    vim.lsp.enable('ty')
end

return M
