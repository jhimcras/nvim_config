local M = {}

local output = require('nvim_config.launcher.output')
local term = require('nvim_config.launcher.term')
local object = require('nvim_config.launcher.object')
local jump = require('nvim_config.launcher.jump')
local guard = require('nvim_config.launcher.guard')
local registry = require('nvim_config.launcher.registry')
local api = vim.api

M.running_processes = registry.processes
M.Launch = output.Launch
M.LaunchOnTerm = term.LaunchOnTerm
M.LaunchObject = object.LaunchObject
M.Restore = output.Restore
M.GetHighlights = output.GetHighlights
M.GetMatches = jump.GetMatches
M.NextMatch = jump.NextMatch
M.PrevMatch = jump.PrevMatch
M.Jump = jump.Jump
M.CloseLauncherBuffer = guard.CloseLauncherBuffer
M.WipeLauncherBuffers = guard.WipeLauncherBuffers
M.TerminateCurrentLauncherBuffer = output.TerminateCurrentLauncherBuffer
M.GetLauncherList = object.GetLauncherList

function M.set_launcher_mapping(buf)
    guard.set_launcher_mapping(buf, output.TerminateCurrentLauncherBuffer)
end

function M.GetRunningProcesses()
    return registry.list()
end

function M.RegisterProcess(key, proc_info)
    registry.register(key, proc_info)
end

function M.UnregisterProcess(key)
    registry.unregister(key)
end

function M.ShowProcessList()
    require('nvim_config.launcher.process_list').Show()
end

function M.setup()
    api.nvim_create_autocmd({'BufRead', 'BufNew'}, { callback = object.BufMapping })
    guard.setup()
    api.nvim_create_autocmd('BufWipeout', {
        callback = function(args)
            registry.terminate(args.buf)
            output.cleanup(args.buf)
        end,
    })
end

return M
