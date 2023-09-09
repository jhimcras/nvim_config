local M = {}

function M.setup()
    -- Disable cursorline and match parenthesis highlighting in insert mode
    vim.o.cursorline = true
    vim.api.nvim_create_autocmd({'InsertLeave', 'WinEnter'}, { callback = function() vim.wo.cursorline = true end })
    vim.api.nvim_create_autocmd({'InsertLeave', 'WinEnter'}, { command = 'DoMatchParen' })
    vim.api.nvim_create_autocmd({'InsertEnter', 'WinLeave'}, { callback = function() vim.wo.cursorline = false end })
    vim.api.nvim_create_autocmd({'InsertEnter', 'WinLeave'}, { command = 'NoMatchParen' })
end

return M
