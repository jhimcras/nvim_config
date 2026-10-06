local M = {}
local api = vim.api
local native_cmd = vim.cmd
local registry = require('nvim_config.launcher.registry')

function M.get_unsaved_buffers()
    local unsaved = {}
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].modified then
            local name = vim.api.nvim_buf_get_name(bufnr)
            table.insert(unsaved, name ~= '' and vim.fn.fnamemodify(name, ':~:.') or '[No Name]')
        end
    end
    return unsaved
end


function M.get_running_processes()
    local processes = registry.list()

    -- Terminal buffers the launcher doesn't track
    local tracked_bufs = {}
    for _, p in ipairs(processes) do
        local b = p.buf or (type(p.key) == 'number' and p.key)
        if type(b) == 'number' then
            tracked_bufs[b] = true
        end
    end

    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_valid(buf) then
            local buftype = vim.bo[buf].buftype
            if buftype == 'terminal' then
                if not tracked_bufs[buf] then
                    local job_id = vim.b[buf].terminal_job_id or vim.bo[buf].channel
                    if job_id and job_id > 0 then
                        if vim.fn.jobwait({job_id}, 0)[1] == -1 then
                            table.insert(processes, {
                                type = 'terminal',
                                buf = buf,
                                job_id = job_id,
                                cmd = vim.api.nvim_buf_get_name(buf),
                                key = buf
                            })
                        end
                    end
                end
            end
        end
    end

    return processes
end

local function get_modified_buffers()
    local buffers = {}
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].modified then
            local name = vim.api.nvim_buf_get_name(bufnr)
            table.insert(buffers, {
                bufnr = bufnr,
                label = name ~= '' and vim.fn.fnamemodify(name, ':~:.') or '[No Name]',
            })
        end
    end
    return buffers
end

local function buffer_labels(buffers)
    local labels = {}
    for _, b in ipairs(buffers) do
        table.insert(labels, b.label)
    end
    return labels
end

local function clear_modified_buffers(buffers)
    for _, item in ipairs(buffers) do
        local bufnr = item.bufnr
        if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr) then
            vim.bo[bufnr].modified = false
        end
    end
end

local function exit_confirm_text(has_processes, has_unsaved)
    if has_processes and has_unsaved then
        return "Stop processes, ignore unsaved changes, and continue?", "&Stop and Ignore\n&Cancel"
    elseif has_processes then
        return "Stop and Continue?", "&Stop and Continue\n&Cancel"
    else
        return "Ignore and Continue?", "&Ignore\n&Cancel"
    end
end


function M.terminate_all_processes(processes)
    for _, p in ipairs(processes) do
        if p.terminate then
            p.terminate(15)
        elseif p.handle and not p.handle:is_closing() then
            if type(p.handle.kill) == 'function' then
                p.handle:kill(15)
            end
        elseif p.job_id then
            vim.fn.jobstop(p.job_id)
        end
    end
end


local quit_all_commands = { qa = true, qall = true, quita = true, quitall = true }
local write_quit_all_commands = { wqa = true, wqall = true, xa = true, xall = true }

local function install_command_wrapper(state, original_cmd)
    local function run_forced_quit(command)
        state.skip_quit_guard = true
        local ok, err = pcall(original_cmd, command)
        state.skip_quit_guard = false
        if not ok then error(err) end
    end

    -- vim.cmd('qa') doesn't expand abbreviations.
    vim.cmd = setmetatable({}, {
        __index = original_cmd,
        __call = function(_, command)
            if type(command) == 'string' then
                local name, bang = command:match('^%s*(%a+)(!?)%s*$')
                if quit_all_commands[name] or write_quit_all_commands[name] then
                    if bang == '!' then
                        return run_forced_quit(command)
                    end
                    return original_cmd(quit_all_commands[name] and 'SessionQuitAll' or 'SessionWriteQuitAll')
                end
            end
            return original_cmd(command)
        end,
    })

    return run_forced_quit
end

local function install_cmdline_guard(state, exit_guard_group)
    api.nvim_create_autocmd('CmdlineLeavePre', {
        group = exit_guard_group,
        callback = function()
            local name = vim.fn.getcmdline():match('^%s*(%a+)!%s*$')
            if vim.fn.getcmdtype() == ':' and (quit_all_commands[name] or write_quit_all_commands[name]) then
                state.skip_quit_guard = true
                vim.schedule(function() state.skip_quit_guard = false end)
            end
        end,
    })

end

local function abort_exit()
    print("Aborting exit...")
    -- A modified buffer is what actually stops :qa
    local abort_buf = vim.api.nvim_create_buf(false, true)
    local unique_id = math.random(1000, 9999)
    pcall(vim.api.nvim_buf_set_name, abort_buf, "[CANCELLED EXIT " .. unique_id .. "]")
    vim.api.nvim_set_option_value('modified', true, { buf = abort_buf })

    -- Cleaned up on a timer, after Neovim sees it
    local timer = vim.uv.new_timer()
    timer:start(50, 0, vim.schedule_wrap(function()
        if vim.api.nvim_buf_is_valid(abort_buf) then
            vim.api.nvim_buf_delete(abort_buf, { force = true })
        end
        timer:close()
    end))

    -- C-c interrupts the command line
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-c>", true, false, true), 'm', true)
end

local function handle_quit_guard(state, get_processes, cancel_mode, force_global)
    if state.exit_warned or state.skip_quit_guard then return true end

    local buf = vim.api.nvim_get_current_buf()
    local wins = vim.api.nvim_list_wins()
    local is_last_win = force_global or (#wins <= 1)

    local processes = get_processes()
    local modified_buffers = get_modified_buffers()

    -- Single buffer close
    local current_proc = nil
    for _, p in ipairs(processes) do
        local p_buf = p.buf or (type(p.key) == 'number' and p.key)
        if p_buf == buf then
            current_proc = p
            break
        end
    end

    local is_launcher_buffer = vim.bo[buf].filetype == 'launcher'
        or (vim.bo[buf].filetype == 'terminal' and vim.b[buf].lc_object ~= nil)
    local is_unsaved_nofile = (vim.bo[buf].buftype == 'nofile' and vim.bo[buf].modified and not is_launcher_buffer)

    -- Not the last window nor a special buffer: stay silent
    if not is_last_win and not is_unsaved_nofile then
        if not current_proc or is_launcher_buffer or vim.bo[buf].filetype == 'qf' then
            return true
        end
    end

    local msg = ""

    -- Current buffer's warnings, always shown
    if is_unsaved_nofile then
        msg = msg .. "Unsaved changes in scratch buffer: " .. 
                   (vim.api.nvim_buf_get_name(buf) ~= "" and vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ':t') or "[No Name]") .. "\n"
    end
    if current_proc and (is_last_win or not is_launcher_buffer) then
        msg = msg .. "Process [" .. (current_proc.obj or current_proc.title or "Launcher") .. "] is still running in this buffer.\n"
    end

    -- Global warnings, only for the last window
    local other_processes = {}
    if is_last_win then
        if #modified_buffers > 0 then
            msg = msg .. "\nGlobal Unsaved buffers:\n  " .. table.concat(buffer_labels(modified_buffers), "\n  ") .. "\n"
        end
        -- Only if there are processes besides the current one
        for _, p in ipairs(processes) do
            if p ~= current_proc then
                table.insert(other_processes, p.obj or p.title or p.cmd or "Process")
            end
        end
        if #other_processes > 0 then
            msg = msg .. "\nOther running processes:\n  " .. table.concat(other_processes, "\n  ") .. "\n"
        end
    end

    if msg == "" then return true end
    local has_processes = (current_proc and (is_last_win or not is_launcher_buffer)) or (is_last_win and #other_processes > 0)
    local has_unsaved = is_unsaved_nofile or (is_last_win and #modified_buffers > 0)
    local prompt, choices = exit_confirm_text(has_processes, has_unsaved)
    msg = msg .. "\n" .. prompt

    vim.cmd('redraw')
    if vim.fn.confirm(msg, choices, 2) ~= 1 then
        if cancel_mode == 'abort' then
            abort_exit()
        end
        return false
    end

    if is_last_win then
        state.exit_warned = true
        M.terminate_all_processes(processes)
        clear_modified_buffers(modified_buffers)
    else
        -- An individual :q terminates only the current one
        if current_proc then
            M.terminate_all_processes({current_proc})
        end
        vim.bo[buf].modified = false
    end
    return true
end

local function register_quit_commands(state, original_cmd, run_forced_quit, get_processes)
    api.nvim_create_user_command('SessionQuitAll', function(opts)
        if opts.bang then return run_forced_quit('qa!') end
        if handle_quit_guard(state, get_processes, 'return', true) == false then
            return
        end
        original_cmd('qa')
    end, { bang = true })

    vim.cmd([[cnoreabbrev <expr> qa (getcmdtype() == ':' && getcmdline() ==# 'qa' ? 'SessionQuitAll' : 'qa')]])
    vim.cmd([[cnoreabbrev <expr> qall (getcmdtype() == ':' && getcmdline() ==# 'qall' ? 'SessionQuitAll' : 'qall')]])
    vim.cmd([[cnoreabbrev <expr> quita (getcmdtype() == ':' && getcmdline() ==# 'quita' ? 'SessionQuitAll' : 'quita')]])
    vim.cmd([[cnoreabbrev <expr> quitall (getcmdtype() == ':' && getcmdline() ==# 'quitall' ? 'SessionQuitAll' : 'quitall')]])

    api.nvim_create_user_command('SessionWriteQuitAll', function(opts)
        if opts.bang then return run_forced_quit('wqa!') end
        local ok, err = pcall(vim.cmd, 'wall')
        if not ok then
            vim.cmd('redraw')
            vim.notify('Write failed, aborting quit: ' .. tostring(err), vim.log.levels.ERROR)
            return
        end
        if handle_quit_guard(state, get_processes, 'return', true) == false then
            return
        end
        original_cmd('qa')
    end, { bang = true })

    vim.cmd([[cnoreabbrev <expr> wqa (getcmdtype() == ':' && getcmdline() ==# 'wqa' ? 'SessionWriteQuitAll' : 'wqa')]])
    vim.cmd([[cnoreabbrev <expr> wqall (getcmdtype() == ':' && getcmdline() ==# 'wqall' ? 'SessionWriteQuitAll' : 'wqall')]])
    vim.cmd([[cnoreabbrev <expr> xa (getcmdtype() == ':' && getcmdline() ==# 'xa' ? 'SessionWriteQuitAll' : 'xa')]])
    vim.cmd([[cnoreabbrev <expr> xall (getcmdtype() == ':' && getcmdline() ==# 'xall' ? 'SessionWriteQuitAll' : 'xall')]])

end

function M.setup(get_processes)
    local state = { exit_warned = false, skip_quit_guard = false }
    local group = api.nvim_create_augroup("ExitGuard", { clear = true })
    local run_forced_quit = install_command_wrapper(state, native_cmd)
    install_cmdline_guard(state, group)
    register_quit_commands(state, native_cmd, run_forced_quit, get_processes)
    api.nvim_create_autocmd("QuitPre", {
        group = group,
        callback = function()
            handle_quit_guard(state, get_processes, 'abort', false)
        end,
    })
end

return M
