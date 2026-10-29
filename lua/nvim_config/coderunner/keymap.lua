local M = {}
function M.setup()
    local function attach(buf)
        if vim.bo[buf].filetype ~= 'markdown' then return end
        for key, command in pairs({ cr = 'CodeRun', cR = 'CodeRun!', cc = 'CodeCancel', co = 'CodeOutput',
            cd = 'CodeRender', cD = 'CodeRender!', ce = 'CodeExport', cE = 'CodeExportAll' }) do
            vim.keymap.set('n', '<leader>' .. key, '<Cmd>' .. command .. '<CR>', { buffer = buf, desc = command })
        end
    end
    vim.api.nvim_create_autocmd('FileType', { pattern = 'markdown',
        group = vim.api.nvim_create_augroup('CodeRunnerKeymap', { clear = true }),
        callback = function(a) attach(a.buf) end })
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do if vim.api.nvim_buf_is_loaded(buf) then attach(buf) end end
end
return M
