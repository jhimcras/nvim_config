local M = {}

function M.setup(colorcolumn)
    local function set_colorcolumn(cc)
        if vim.bo.buftype == '' then
            vim.wo.colorcolumn = tostring(cc)
        else
            vim.wo.colorcolumn = '0'
        end
    end
    vim.api.nvim_create_autocmd({'BufWinEnter', 'WinEnter'}, {callback = function() set_colorcolumn(colorcolumn) end})
    vim.api.nvim_create_autocmd('WinLeave', {callback = function() set_colorcolumn(0) end})
end

return M
