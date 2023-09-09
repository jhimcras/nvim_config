local M = {}
local env = require 'env'
local api = vim.api
local ut = require 'util'

function M.SessionDir()
    local session_folder = table.concat { vim.fn.stdpath('data'), env.dir_sep, 'sessions' }
    return { 'fd', '-tf', '--base-directory', session_folder }
end

function M.OpenSession(session)
    vim.cmd('%bwipeout!')
    vim.cmd.source(string.format('%s/sessions/%s', vim.fn.stdpath('data'), session))
end

function M.SaveSession(session_name)
    if session_name and session_name ~= '' then
        vim.cmd('mksession! ' .. vim.fn.stdpath('data') .. '/sessions/' .. session_name)
        vim.notify(string.format('Session %s has been saved.', session_name), vim.log.levels.INFO)
    elseif vim.v.this_session ~= '' then
        vim.cmd('mksession! ' .. vim.v.this_session)
        vim.notify(string.format('Session %s has been saved.', vim.fn.fnamemodify(vim.v.this_session, ':p:t')), vim.log.levels.INFO)
    else
        vim.notify('No session name.', vim.log.levels.ERROR)
    end
    vim.go.tabline = require'status'.TabLine()
end

function M.RemoveSession(session_name)
    local rmcmd = ''
    if env.os.unix then
        rmcmd = '!rm -rf '
    elseif env.os.win then
        rmcmd = '!del /q '
    else
        vim.notify('Not supported OS.', vim.log.levels.ERROR)
        return
    end
    local this_session_name = vim.fn.fnamemodify(vim.v.this_session, ':p:t')
    if session_name and session_name ~= '' and session_name ~= this_session_name then
        local sname = vim.fn.stdpath('data') .. '/sessions/' .. session_name
        if vim.fn.filereadable(sname) == 0 then
            vim.notify(string.format("Session %s doesn't exist.", session_name), vim.log.levels.ERROR)
            return
        end
        vim.fn.execute(rmcmd .. sname, 'silent!')
        vim.notify(string.format('Session %s has been removed.', session_name), vim.log.levels.INFO)
    elseif vim.v.this_session ~= '' then
        if vim.fn.filereadable(vim.v.this_session) == 0 then
            vim.notify(string.format("Session %s doesn't exist.", this_session_name), vim.log.levels.ERROR)
            return
        end
        vim.fn.execute(rmcmd .. vim.v.this_session, 'silent!')
        vim.v.this_session = ''
        vim.notify(string.format('Session %s has been removed.', this_session_name), vim.log.levels.INFO)
    else
        vim.notify('No session name to remove.', vim.log.levels.ERROR)
    end
    vim.o.tabline = require'status'.TabLine()
end

function M.CloseSession()
    vim.cmd('%bwipeout!')
    vim.cmd.cd('~')
    vim.v.this_session = ''
end

function M.SessionList()
    local session_list = vim.fn.globpath(vim.fn.stdpath('data')..'/sessions/', '*', true, true)
    for i, s in ipairs(session_list) do
        session_list[i] = vim.fn.fnamemodify(s, ':t')
    end
    return session_list
end

function M.setup()
    api.nvim_create_user_command('SaveSession', function(t) M.SaveSession(t.args) end, { nargs='?', complete="customlist,v:lua.require'session'.SessionList" })
    api.nvim_create_user_command('RemoveSession', function(t) M.RemoveSession(t.args) end, { nargs='?', complete="customlist,v:lua.require'session'.SessionList" })
    api.nvim_create_user_command('CloseSession', M.CloseSession, {})

    -- Session mapping
    ut.nnoremap('<F12>', M.SaveSession)

end

return M
