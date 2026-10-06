local util_hl = require('nvim_config.util.hl')
local api = vim.api
local progress = require('nvim_config.lsp.progress')
local status = require('nvim_config.lsp.status')
local M = {
    make_on_attach = require('nvim_config.lsp.attach').make_on_attach,
    progress_state = progress.progress_state,
    SymError = status.SymError,
    SymWarn = status.SymWarn,
    SymInfo = status.SymInfo,
    SymHint = status.SymHint,
}

function M.setup()
    require('nvim_config.lsp.float').setup()
    vim.lsp.log.set_level('WARN')

    vim.diagnostic.config {
        signs =  {
            text = {
                [vim.diagnostic.severity.ERROR] = M.SymError,
                [vim.diagnostic.severity.WARN] = M.SymWarn,
                [vim.diagnostic.severity.INFO] = M.SymInfo,
                [vim.diagnostic.severity.HINT] = M.SymHint,
            },
        }
    }

    util_hl.set_highlight('LspReferenceText', { gui='bold' })
    util_hl.set_highlight('LspReferenceRead', { gui='bold' })
    util_hl.set_highlight('LspReferenceWrite', { gui='bold' })

    progress.setup()

    require('nvim_config.lsp.servers.clangd').setup()
    require('nvim_config.lsp.servers.lua_ls').setup()
    require('nvim_config.lsp.servers.python').setup()
    require('nvim_config.lsp.servers.markdown').setup()

    local prjroot = require 'nvim_config.prjroot'
    local lsp_server_names = { 'clangd', 'lua_ls', 'ty' }

    api.nvim_create_autocmd('BufReadPre', {
        desc = 'Apply per-project LSP settings from .prjroot',
        callback = function(ev)
            local fname = vim.api.nvim_buf_get_name(ev.buf)
            if fname == '' then return end
            local cfg = prjroot.GetPrjrootConfig(fname)
            if not cfg then return end
            if cfg.lsp_env then
                for _, name in ipairs(lsp_server_names) do
                    vim.lsp.config(name, { cmd_env = cfg.lsp_env })
                end
            end
            if cfg.clangd_args then
                vim.lsp.config('clangd', { cmd = require('nvim_config.lsp.servers.clangd').cmd(cfg.clangd_args) })
            end
        end,
    })

end

return M
