local M = {}
local env = require'env'
local ut = require'util'

M.general_root_markers = {
    '.git',
    'compile_command.json',
    'compile_flags.txt',
    'README.*',
    '.prjroot',
}

local function parent(path)
    return vim.fn.fnamemodify(path, ':p:h:h')
end

function M.GetProjectRoot(filepath, root_markers)
    if not filepath then return nil end
    local rmarks = root_markers or M.general_root_markers
    local folder = vim.fn.fnamemodify(filepath, ':p:h')
    while folder ~= parent(folder) do
        for _, marker in pairs(rmarks) do
            if ut.IsExist(table.concat{folder, env.dir_sep, marker}) then
                return folder
            end
        end
        folder = parent(folder)
    end
end

function M.GetCurrentProjectRoot(root_markers)
    return vim.b.prjroot_folder or
           M.GetProjectRoot(vim.api.nvim_buf_get_name(0), root_markers)
end

function M.SetBufferProjectRoot(bufnr, folder)
    vim.api.nvim_buf_set_var(bufnr, 'prjroot_folder', folder)
end

function M.GetCurrentConfig(root_markers)
    local rmarks = root_markers or M.general_root_markers
    local prj_root = M.GetCurrentProjectRoot(rmarks)
    if prj_root then
        local conf_file =  prj_root .. '/.prjroot'
        if ut.IsExist(conf_file) then
            return dofile(conf_file)
        end
    end
end

function M.GetPrjrootConfig(filepath, root_markers)
    local prj_root = M.GetProjectRoot(filepath, root_markers)
    if prj_root then
        local conf_file =  prj_root .. '/.prjroot'
        if ut.IsExist(conf_file) then
            return dofile(conf_file)
        end
    end
end

function M.setup()
    ut.nnoremap('<m-t>v', function() ut.OpenProjectRootTerminal('vertical') end)
    ut.nnoremap('<m-t>x', function() ut.OpenProjectRootTerminal('horizontal') end)
    ut.nnoremap('<m-t>t', function() ut.OpenProjectRootTerminal('tab') end)
    vim.api.nvim_create_autocmd({'BufRead', 'BufNew'}, {pattern = '.prjroot', callback = function() vim.bo.filetype = 'lua' end})
    vim.api.nvim_create_user_command('PrjRootConfig', function(t) vim.cmd.vsplit {mods = t.smods, args = {(M.GetCurrentProjectRoot() or '.') .. '/.prjroot'}} end, {})
end

return M
