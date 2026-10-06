local M = {}
local env = require 'nvim_config.env'
local api = vim.api
local util_serialize = require('nvim_config.util.serialize')
local lists = require('nvim_config.session.lists')
local exit_guard = require('nvim_config.session.exit_guard')
local get_unsaved_buffers = exit_guard.get_unsaved_buffers
local terminate_all_processes = exit_guard.terminate_all_processes
M.get_running_processes = exit_guard.get_running_processes

local function emit(event, action, path)
    api.nvim_exec_autocmds('User', {
        pattern = event,
        data = { action = action, path = path, session = vim.v.this_session },
    })
end

local function save_session(path)
    lists.save(path)
    vim.cmd('mksession! ' .. path)
end

local function auto_save()
    if vim.v.this_session ~= "" then
        save_session(vim.v.this_session)
    end
end

function M.OpenSession(session)
    local unsaved = get_unsaved_buffers()
    local processes = M.get_running_processes()

    if #unsaved > 0 or #processes > 0 then
        local msg = ""
        if #unsaved > 0 then
            msg = msg .. "Unsaved buffers:\n  " .. table.concat(unsaved, "\n  ") .. "\n\n"
        end
        if #processes > 0 then
            local proc_names = {}
            for _, p in ipairs(processes) do
                table.insert(proc_names, p.obj or p.title or p.cmd or "Unknown")
            end
            msg = msg .. "Running processes:\n  " .. table.concat(proc_names, "\n  ") .. "\n\n"
        end
        msg = msg .. "Continue?"
        if vim.fn.confirm(msg, "&Stop and Open Session\n&Cancel", 2) ~= 1 then
            return
        end
    end

    auto_save()
    -- Terminate processes before the wipeout
    terminate_all_processes(processes)
    vim.cmd('%bwipeout!')
    local sess_path = string.format('%s/sessions/%s', vim.fn.stdpath('data'), session)
    vim.cmd.source(sess_path)
    lists.restore(sess_path)
    -- mksession doesn't restore cmdheight; reset it so windows get the rows back.
    vim.o.cmdheight = 1
    emit('SessionLoaded', 'open', sess_path)
end


function M.SaveSession(session_name)
    local session_path

    if session_name and session_name ~= '' then
        session_path = vim.fn.stdpath('data') .. '/sessions/' .. session_name
    elseif vim.v.this_session ~= '' then
        session_path = vim.v.this_session
    else
        vim.notify('No session name.', vim.log.levels.ERROR)
        return
    end

    save_session(session_path)

    vim.notify(
        string.format('Session %s has been saved.', vim.fn.fnamemodify(session_path, ':t')),
        vim.log.levels.INFO
    )

    emit('SessionChanged', 'save', session_path)
end


-- TODO: Should delete qflist files.
function M.RemoveSession(session_name)
    local removed_path
    local this_session_name = vim.fn.fnamemodify(vim.v.this_session, ':p:t')
    if session_name and session_name ~= '' and session_name ~= this_session_name then
        local sname = vim.fn.stdpath('data') .. '/sessions/' .. session_name
        sname = util_serialize.normalize_path_separator(sname)
        if vim.fn.filereadable(sname) == 0 then
            vim.notify(string.format("Session %s doesn't exist.", session_name), vim.log.levels.ERROR)
            return
        end
        removed_path = sname
        vim.fn.delete(sname, "rf")
        vim.notify(string.format('Session %s has been removed.', session_name), vim.log.levels.INFO)
    elseif vim.v.this_session ~= '' then
        if vim.fn.filereadable(vim.v.this_session) == 0 then
            vim.notify(string.format("Session %s doesn't exist.", this_session_name), vim.log.levels.ERROR)
            return
        end
        removed_path = vim.v.this_session
        vim.fn.delete(vim.v.this_session, "rf")
        vim.v.this_session = ''
        vim.notify(string.format('Session %s has been removed.', this_session_name), vim.log.levels.INFO)
    else
        vim.notify('No session name to remove.', vim.log.levels.ERROR)
        return
    end
    emit('SessionChanged', 'remove', removed_path)
end


function M.CloseSession()
    local session_path = vim.v.this_session
    local unsaved = get_unsaved_buffers()
    local processes = M.get_running_processes()

    if #unsaved > 0 or #processes > 0 then
        local msg = ""
        if #unsaved > 0 then
            msg = msg .. "Unsaved buffers:\n  " .. table.concat(unsaved, "\n  ") .. "\n\n"
        end
        if #processes > 0 then
            local proc_names = {}
            for _, p in ipairs(processes) do
                table.insert(proc_names, p.obj or p.title or p.cmd or "Unknown")
            end
            msg = msg .. "Running processes:\n  " .. table.concat(proc_names, "\n  ") .. "\n\n"
        end
        msg = msg .. "Continue?"
        if vim.fn.confirm(msg, "&Stop and Close Session\n&Cancel", 2) ~= 1 then
            return
        end
    end

    auto_save()
    -- Terminate processes before the wipeout
    terminate_all_processes(processes)
    vim.cmd('%bwipeout!')
    vim.cmd.cd('~')
    vim.v.this_session = ''
    vim.fn.setqflist({}, 'r')
    emit('SessionChanged', 'close', session_path)
end


local function is_session_file(name)
    return not (
        name:match('%.qf%.') or
        name:match('%.loc%.') or
        name:match('%.lua$')
    )
end


function M.SessionList(arglead)
    arglead = arglead or ''
    local session_list = vim.fn.globpath(vim.fn.stdpath('data')..'/sessions/', '*', true, true)
    local filtered_session_list = {}
    for _, path in ipairs(session_list) do
        local name = vim.fn.fnamemodify(path, ':t')
        if name:find(arglead, 1, true) == 1 and is_session_file(name) then
            table.insert(filtered_session_list, name)
        end
    end
    return filtered_session_list
end


function M.setup()
    api.nvim_create_user_command('SaveSession', function(t) M.SaveSession(t.args) end, { nargs='?', complete="customlist,v:lua.require'nvim_config.session'.SessionList" })
    api.nvim_create_user_command('RemoveSession', function(t) M.RemoveSession(t.args) end, { nargs='?', complete="customlist,v:lua.require'nvim_config.session'.SessionList" })
    api.nvim_create_user_command('CloseSession', M.CloseSession, {})

    vim.api.nvim_create_autocmd("VimLeave", {
        group = vim.api.nvim_create_augroup("SessionAutoSave", { clear = true }),
        callback = auto_save,
    })

    -- 'nvim -S' bypasses M.OpenSession() and its cmdheight fix.
    local cmdheight_fix_group = vim.api.nvim_create_augroup("SessionCmdheightFix", { clear = true })
    vim.api.nvim_create_autocmd("VimEnter", {
        group = cmdheight_fix_group,
        callback = function()
            if vim.v.this_session ~= "" then
                vim.o.cmdheight = 1
            end
        end,
    })

    -- Resizes and tab switches can leak leftover rows into cmdheight.
    vim.api.nvim_create_autocmd({ "VimResized", "TabEnter" }, {
        group = cmdheight_fix_group,
        callback = function()
            vim.o.cmdheight = 1
        end,
    })

    exit_guard.setup(function() return M.get_running_processes() end)
end

return M
