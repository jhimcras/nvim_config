local M = {}
local api = vim.api
local ut = require('util')
local launcher = require('launcher')

local process_list_buf = nil
local refresh_timer = nil

function M.Show()
    if process_list_buf and api.nvim_buf_is_valid(process_list_buf) then
        local wins = vim.fn.win_findbuf(process_list_buf)
        if #wins > 0 then
            api.nvim_set_current_win(wins[1])
            return
        end
    end

    process_list_buf = ut.NewScratchBuffer({ orientation = 'vertical', size = 60 })
    api.nvim_buf_set_name(process_list_buf, '[Process List]')
    api.nvim_buf_set_option(process_list_buf, 'filetype', 'processlist')

    M.SetMappings(process_list_buf)
    M.Update()
    M.StartRefresh()

    api.nvim_create_autocmd('BufWipeout', {
        buffer = process_list_buf,
        callback = function()
            M.StopRefresh()
            process_list_buf = nil
        end
    })
end

function M.SetMappings(buf)
    ut.nnoremap('gq', function() vim.cmd.bwipeout(buf) end, { buffer = buf })
    ut.nnoremap('<C-c>', function() M.TerminateSelected() end, { buffer = buf })
    ut.nnoremap('<CR>', function() M.JumpToProcess() end, { buffer = buf })
end

local function gather_processes()
    local processes = launcher.GetRunningProcesses()

    -- Add terminal buffers not tracked by launcher
    local tracked_bufs = {}
    for _, p in ipairs(processes) do
        if type(p.key) == 'number' then
            tracked_bufs[p.key] = true
        end
    end

    for _, buf in ipairs(api.nvim_list_bufs()) do
        if api.nvim_buf_is_valid(buf) and api.nvim_buf_get_option(buf, 'buftype') == 'terminal' then
            if not tracked_bufs[buf] then
                local job_id = vim.b[buf].terminal_job_id
                if job_id and vim.fn.jobwait({job_id}, 0)[1] == -1 then
                    table.insert(processes, {
                        type = 'terminal',
                        buf = buf,
                        job_id = job_id,
                        cmd = api.nvim_buf_get_name(buf),
                        key = buf
                    })
                end
            end
        end
    end

    return processes
end

function M.Update()
    if not process_list_buf or not api.nvim_buf_is_valid(process_list_buf) then return end

    local processes = gather_processes()
    local lines = {
        string.format("%-10s | %-30s | %-10s | %-10s", "TYPE", "NAME/COMMAND", "STATUS", "ID"),
        string.rep("-", 70)
    }

    M.process_data = processes -- Store for interaction

    for _, p in ipairs(processes) do
        local name = p.obj or p.title or p.cmd or "unknown"
        if #name > 30 then name = name:sub(1, 27) .. "..." end
        
        local status = "running"
        if p.type == 'grep' then
            -- status is already searching if it's in the list
            status = "searching"
        end

        local id = p.pid or p.job_id or (type(p.key) == 'number' and p.key) or "-"
        table.insert(lines, string.format("%-10s | %-30s | %-10s | %-10s", p.type, name, status, id))
    end

    api.nvim_buf_set_option(process_list_buf, 'modifiable', true)
    api.nvim_buf_set_lines(process_list_buf, 0, -1, false, lines)
    api.nvim_buf_set_option(process_list_buf, 'modifiable', false)
end

function M.StartRefresh()
    if refresh_timer then return end
    refresh_timer = vim.uv.new_timer()
    refresh_timer:start(500, 500, vim.schedule_wrap(function()
        M.Update()
    end))
end

function M.StopRefresh()
    if refresh_timer then
        refresh_timer:stop()
        refresh_timer:close()
        refresh_timer = nil
    end
end

function M.TerminateSelected()
    local line = api.nvim_win_get_cursor(0)[1]
    local idx = line - 2 -- Adjust for header
    if idx <= 0 or not M.process_data or not M.process_data[idx] then return end

    local p = M.process_data[idx]
    vim.notify("Terminating " .. (p.obj or p.cmd or "process"), vim.log.levels.WARN)

    if p.terminate then
        p.terminate(15)
    elseif p.handle and not p.handle:is_closing() then
        p.handle:kill(15)
    elseif p.job_id then
        vim.fn.jobstop(p.job_id)
    end
end

function M.JumpToProcess()
    local line = api.nvim_win_get_cursor(0)[1]
    local idx = line - 2
    if idx <= 0 or not M.process_data or not M.process_data[idx] then return end

    local p = M.process_data[idx]
    local buf = p.buf or (type(p.key) == 'number' and p.key)
    if buf and api.nvim_buf_is_valid(buf) then
        local wins = vim.fn.win_findbuf(buf)
        if #wins > 0 then
            api.nvim_set_current_win(wins[1])
        else
            vim.cmd('vsplit')
            api.nvim_set_current_buf(buf)
        end
    end
end

return M
