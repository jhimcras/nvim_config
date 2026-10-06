local M = {}

function M.setup_loupe()
    vim.g.LoupeCenterResults = 0
end

function M.setup_vsnip()
    vim.g.vsnip_snippet_dir = vim.fn.stdpath('config') .. '/vsnip'
end

function M.setup_fugitive()
    vim.api.nvim_create_autocmd('FileType', {
        pattern = 'fugitive',
        callback = function()
            vim.opt_local.winfixheight = true
        end,
    })
end

return M
