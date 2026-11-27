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
    -- In a commit object `o` on a file opens another diff pair; without closing
    -- the previous pair all four windows diff against each other.
    vim.api.nvim_create_autocmd('User', {
        pattern = 'FugitiveCommit',
        callback = function()
            local buf = vim.api.nvim_get_current_buf()
            local rhs = vim.fn.maparg('o', 'n')
            if not rhs:find('GF%(') then return end
            local cmd = rhs:gsub('^:<C%-U>', ''):gsub('<CR>$', '')
            vim.keymap.set('n', 'o', function()
                -- Pick first: fugitive turns diff off in a pair's survivor.
                local stale = vim.tbl_filter(function(win)
                    return vim.api.nvim_win_is_valid(win) and vim.wo[win].diff
                end, vim.b[buf].fugitive_o_wins or {})
                for _, win in ipairs(stale) do
                    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, false) end
                end
                local before = {}
                for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do before[win] = true end
                vim.cmd(cmd)
                local opened = {}
                for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
                    if not before[win] then opened[#opened + 1] = win end
                end
                vim.b[buf].fugitive_o_wins = opened
            end, { buffer = buf, silent = true })
        end,
    })
end

return M
