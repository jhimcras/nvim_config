local env = require 'env'
local M = {}

function M.setup()
    require('nvim-tundra').setup {
        -- transparent_background = true,
        dim_inactive_windows = {
            enabled = true,
        },
        overwrite = {
            highlights = {
                DiagnosticError = { bold = false },
                DiagnosticWarn = { bold = false },
                DiagnosticInfo = { bold = false },
                DiagnosticHint = { bold = false },
                SpecialKey = { link = '', fg = '#a5b4fc' },
            },
        },
        plugins = {
            -- telescope = true,
            lsp = true,
        },
    }
    vim.cmd.colorscheme 'tundra'

    -- require('catppuccin').setup {
    -- }
    -- vim.cmd.colorscheme 'catppuccin'

    vim.o.pumblend = 10
    -- ut.set_highlight('Pmenu', { ctermbg=238 })
    vim.cmd.let '$TERM="xterm-256color"'
    if not env.os.win then
        vim.o.termguicolors = true
    end
    vim.api.nvim_create_autocmd('TextYankPost', { callback = function()
        vim.hl.on_yank { timeout = 200 }
    end } )
end

return M
