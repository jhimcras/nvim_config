local M = {}

local function check_execute_cmd(cmd)
    if vim.fn.exists(':' .. cmd) == 2 then
        vim.cmd(cmd)
    end
end

function M.setup()
    -- Disable cursorline and match parenthesis highlighting in insert mode
    vim.o.cursorline = true
    vim.api.nvim_create_autocmd({'InsertLeave', 'WinEnter'}, { callback = function() if not vim.b.read_mode then vim.wo.cursorline = true end end })
    vim.api.nvim_create_autocmd({'InsertLeave', 'WinEnter'}, { callback = function() check_execute_cmd 'DoMatchParen' end })
    vim.api.nvim_create_autocmd({'InsertEnter', 'WinLeave'}, { callback = function() vim.wo.cursorline = false end })
    vim.api.nvim_create_autocmd({'InsertEnter', 'WinLeave'}, { callback = function() check_execute_cmd 'NoMatchParen' end })
end

return M
