local M = {}

local registry = require('nvim_config.launcher.registry')
local running_processes = registry.processes
local api = vim.api
local pr = require('nvim_config.prjroot')
local util_map = require('nvim_config.util.map')
local jump = require('nvim_config.launcher.jump')

function M.CloseLauncherBuffer(buf)
    buf = buf or api.nvim_get_current_buf()
    if running_processes[buf] then
        local choice = vim.fn.confirm('This process is still running. Stop it and delete the buffer?', "&Stop\n&Cancel", 2)
        if choice ~= 1 then return end
        registry.terminate(buf)
    end
    api.nvim_buf_delete(buf, { force = true })
end

function M.set_launcher_mapping(buf, terminate)
    util_map.nnoremap('gq', M.CloseLauncherBuffer, { buffer = buf })
    util_map.nnoremap(']e', jump.NextMatch, { buffer = buf })
    util_map.nnoremap('[e', jump.PrevMatch, { buffer = buf })
    util_map.nnoremap('<cr>', jump.Jump, { buffer = buf })
    util_map.nnoremap('<c-c>', terminate, { buffer = buf })
end

function M.WipeLauncherBuffers()
    local prjroot = pr.GetCurrentProjectRoot()
    if not prjroot then return end
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_valid(buf) then
            local success, buf_prj = pcall(api.nvim_buf_get_var, buf, 'prjroot_folder')
            if success and buf_prj == prjroot then
                M.CloseLauncherBuffer(buf)
            end
        end
    end
end

function M.setup()
    -- Route typed buffer-deletion commands through the launcher guard.
    local abbrevs = { 'bd', 'bw', 'bdelete', 'bwipe', 'bwipeout' }
    for _, abr in ipairs(abbrevs) do
        local command_name = 'Launcher' .. abr:sub(1, 1):upper() .. abr:sub(2)
        api.nvim_create_user_command(command_name, function(opts)
            local targets = #opts.fargs > 0 and opts.fargs or { '' }
            for _, target in ipairs(targets) do
                local buf = target == '' and api.nvim_get_current_buf() or tonumber(target) or vim.fn.bufnr(target)
                if buf > 0 and running_processes[buf] then
                    M.CloseLauncherBuffer(buf)
                else
                    vim.cmd[abr] { args = target ~= '' and { target } or {}, bang = opts.bang }
                end
            end
        end, { nargs = '*', bang = true, force = true })
        vim.cmd(string.format([[cnoreabbrev <expr> %s (getcmdtype() == ':' && getcmdpos() <= %d ? '%s' : '%s')]], abr, #abr + 1, command_name, abr))
    end
end

return M
