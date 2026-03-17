local M = {}

function M.setup(colorcolumn)
    local function set_colorcolumn(cc)
        if vim.wo.diff or vim.bo.buftype ~= '' then
            vim.wo.colorcolumn = '0'
        else
            vim.wo.colorcolumn = tostring(cc)
        end
    end
    vim.api.nvim_create_autocmd({'BufWinEnter', 'WinEnter'}, {callback = function() set_colorcolumn(colorcolumn) end})
    vim.api.nvim_create_autocmd('WinLeave', {callback = function() set_colorcolumn(0) end})
    vim.api.nvim_create_autocmd('OptionSet', {pattern = 'diff', callback = function() set_colorcolumn(colorcolumn) end})
end

return M
