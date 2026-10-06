local M = {}
local env = require'nvim_config.env'
local ut = require('nvim_config.util.buffer')

M.general_root_markers = {
    '.git',
    'compile_command.json',
    'compile_flags.txt',
    'README.md',
    -- 'README.*',     -- Cannot use wildcard nor pattern here
    '.prjroot',
}

local function parent(path)
    return vim.fn.fnamemodify(path, ':p:h:h')
end

-- Lookups are cached: statusline, tabline and the BufRead/BufReadPre autocmds
-- ask for the same directories many times a second.  Root results expire after
-- ROOT_TTL_MS (markers created/deleted outside nvim) and are dropped on
-- BufWritePost/DirChanged; .prjroot configs are reloaded when mtime/size change.
local ROOT_TTL_MS = 5000
local root_cache = {}   -- markers key -> { [filepath or folder] = { root|false, time } }
local config_cache = {} -- conf_file -> { sec, nsec, size, cfg }

function M.ClearCache()
    root_cache = {}
end

function M.GetProjectRoot(filepath, root_markers)
    if not filepath then return nil end
    local rmarks = root_markers or M.general_root_markers
    local mkey = table.concat(rmarks, '\0')
    local cache = root_cache[mkey]
    if not cache then
        cache = {}
        root_cache[mkey] = cache
    end
    local now = vim.uv.now()
    local hit = cache[filepath]
    if hit and now - hit[2] < ROOT_TTL_MS then return hit[1] or nil end

    local folder = vim.fn.fnamemodify(filepath, ':p:h')
    hit = cache[folder]
    if hit and now - hit[2] < ROOT_TTL_MS then
        cache[filepath] = hit
        return hit[1] or nil
    end

    local visited = {}
    local root = false
    while folder ~= parent(folder) do
        visited[#visited+1] = folder
        for _, marker in pairs(rmarks) do
            if ut.IsExist(table.concat{folder, env.dir_sep, marker}) then
                root = folder
                break
            end
        end
        if root then break end
        folder = parent(folder)
    end
    local entry = { root, now }
    for _, f in ipairs(visited) do cache[f] = entry end
    cache[filepath] = entry
    return root or nil
end

function M.GetCurrentProjectRoot(root_markers)
    return vim.b.prjroot_folder or
           M.GetProjectRoot(ut.GetCurrentBufferDir(), root_markers)
end

function M.SetBufferProjectRoot(bufnr, folder)
    vim.api.nvim_buf_set_var(bufnr, 'prjroot_folder', folder)
end

local function load_config(conf_file)
    local st = vim.uv.fs_stat(conf_file)
    if not st then
        config_cache[conf_file] = nil
        return
    end
    local c = config_cache[conf_file]
    if c and c.sec == st.mtime.sec and c.nsec == st.mtime.nsec and c.size == st.size then
        return c.cfg
    end
    local cfg = dofile(conf_file)
    config_cache[conf_file] = { sec = st.mtime.sec, nsec = st.mtime.nsec, size = st.size, cfg = cfg }
    return cfg
end

function M.GetCurrentConfig(root_markers)
    local rmarks = root_markers or M.general_root_markers
    local prj_root = M.GetCurrentProjectRoot(rmarks)
    if prj_root then
        return load_config(prj_root .. '/.prjroot')
    end
end

function M.GetPrjrootConfig(filepath, root_markers)
    local prj_root = M.GetProjectRoot(filepath, root_markers)
    if prj_root then
        return load_config(prj_root .. '/.prjroot')
    end
end

function M.OpenProjectRootTerminal(splitcmd)
    local pr = M.GetCurrentProjectRoot()
    if pr then
        ut.OpenTerminal(pr, splitcmd)
    else
        ut.OpenTerminal(ut.GetCurrentBufferDir(), splitcmd)
    end
end

function M.setup()
    vim.api.nvim_create_autocmd({'BufWritePost', 'DirChanged'}, {callback = M.ClearCache})
    vim.api.nvim_create_autocmd({'BufRead', 'BufNew'}, {pattern = '.prjroot', callback = function() vim.bo.filetype = 'lua' end})
    vim.api.nvim_create_autocmd('BufRead', { callback = function()
        local cfg = M.GetCurrentConfig()
        if type(cfg) == 'table' and cfg.options then
            for opt, value in pairs(cfg.options) do
                vim.bo[opt] = value
            end
        end
    end})
end

return M
