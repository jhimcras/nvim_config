local M = {}

-- File extensions
local LIST_EXT_QF = ".qf.lua"
local LIST_EXT_LOC = ".loc"
local LIST_EXT_LAUNCHER = ".launcher.lua"

-- Create the directory if missing
local function ensure_dir(path)
    if vim.fn.isdirectory(path) == 0 then
        vim.fn.mkdir(path, "p")
    end
end
local env = require 'env'
local api = vim.api
local ut = require 'util'
local native_cmd = vim.cmd

local function write_list_file(data, path)
    local ok, content = pcall(vim.inspect, data)
    if not ok then
        return false, "Failed to serialize list"
    end

    local fd, err = io.open(path, "w")
    if not fd then
        return false, err
    end

    fd:write("return " .. content)
    fd:close()

    return true
end

local function get_list_cursor(winid)
    local cursor = vim.api.nvim_win_get_cursor(winid)
    return { row = cursor[1], col = cursor[2] }
end

local function build_origin_window(origin_winid)
    local winctx = ut.get_window_context(origin_winid)
    if not winctx then
        return nil
    end

    winctx.tab_nr = vim.api.nvim_tabpage_get_number(winctx.tabpage)
    winctx.cursor = nil
    return winctx
end

local function items_with_filename(items)
    local out = {}
    for _, item in ipairs(items) do
        local entry = vim.deepcopy(item)
        if entry.bufnr and entry.bufnr ~= 0 then
            entry.filename = vim.api.nvim_buf_get_name(entry.bufnr)
            entry.bufnr = nil
        end
        table.insert(out, entry)
    end
    return out
end

local function save_loclist(winid, path)
    if not winid or not vim.api.nvim_win_is_valid(winid) then
        return false, "Invalid window id"
    end

    ensure_dir(vim.fn.fnamemodify(path, ':h'))

    local info = vim.fn.getloclist(winid, { title = 1, items = 1 })
    if not info or not info.items or #info.items == 0 then
        return false, "List is empty or invalid"
    end

    -- Selection index for the location list
    local sel = vim.fn.getloclist(winid, { idx = 0 }).idx or 1

    local loc_winid = vim.fn.getloclist(winid, { winid = 0 }).winid
    local filter_chain, matches, cursor
    if loc_winid and loc_winid ~= 0 and vim.api.nvim_win_is_valid(loc_winid) then
        filter_chain = require'grep'.get_filter_chain(loc_winid)
        matches = vim.fn.getmatches(loc_winid)
        local c = vim.api.nvim_win_get_cursor(loc_winid)
        cursor = { row = c[1], col = c[2] }
    end

    local data = {
        kind         = "loc",
        title        = info.title,
        items        = items_with_filename(info.items),
        origin       = build_origin_window(winid),
        selection    = sel,
        filter_chain = filter_chain,
        matches      = matches,
        cursor       = cursor,
    }

    return write_list_file(data, path)
end

local function save_launcher(winid, path)
    if not winid or not vim.api.nvim_win_is_valid(winid) then
        return false, "Invalid window id"
    end

    local bufnr = vim.api.nvim_win_get_buf(winid)
    ensure_dir(vim.fn.fnamemodify(path, ':h'))

    local data = {
        kind    = "launcher",
        origin  = build_origin_window(winid),
        content = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false),
        obj      = vim.b[bufnr].lc_object,
        cmd      = vim.b[bufnr].lc_command,
        prjroot  = vim.b[bufnr].prjroot_folder,
        status   = vim.b[bufnr].launcher_status,
        matches  = vim.b[bufnr].launcher_matches,
        filetype = vim.bo[bufnr].filetype,
    }

    return write_list_file(data, path)
end

local function save_all_launchers(path, session_prefix)
    ensure_dir(path)
    for _, tabpage in ipairs(vim.api.nvim_list_tabpages()) do
        for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(tabpage)) do
            local bufnr = vim.api.nvim_win_get_buf(winid)
            local ft = vim.bo[bufnr].filetype
            if ft == 'launcher' or ft == 'terminal' then
                save_launcher(winid, string.format("%s/%s%s.%d.lua", path, session_prefix, LIST_EXT_LAUNCHER, winid))
            end
        end
    end
end


local function save_all_loclists(path, session_prefix)
    -- The directory must exist before any write
    ensure_dir(path)
    for _, tabpage in ipairs(vim.api.nvim_list_tabpages()) do
        for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(tabpage)) do
            local bufnr = vim.api.nvim_win_get_buf(winid)
            if vim.bo[bufnr].buftype == 'quickfix' then goto continue end
            local loc = vim.fn.getloclist(winid, { items = 0, winid = 0 })
            if loc and loc.items and #loc.items > 0 and loc.winid ~= 0 then
                save_loclist(winid, string.format("%s/%s%s.%d.lua", path, session_prefix, LIST_EXT_LOC, winid))
            end
            ::continue::
        end
    end
end


local function save_quickfix(path, session_prefix)
    if not path or path == "" then
        return false, "path is required"
    end

    if not session_prefix or session_prefix == "" then
        return false, "session_prefix is required"
    end

    ensure_dir(path)

    local info = vim.fn.getqflist({ title = 1, items = 1, winid = 1 })
    if not info or not info.items or #info.items == 0 then
        return false, "List is empty or invalid"
    end

    if not info.winid or info.winid == 0 then
        return false, "Quickfix window is not open"
    end

    -- Currently selected entry
    local sel = vim.fn.getqflist({ idx = 0 }).idx or 1

    local qf_winid = info.winid
    local filter_chain, matches, cursor
    if qf_winid and qf_winid ~= 0 and vim.api.nvim_win_is_valid(qf_winid) then
        filter_chain = require'grep'.get_filter_chain(qf_winid)
        matches = vim.fn.getmatches(qf_winid)
        local c = vim.api.nvim_win_get_cursor(qf_winid)
        cursor = { row = c[1], col = c[2] }
    end

    local data = {
        kind         = "qf",
        title        = info.title,
        items        = items_with_filename(info.items),
        selection    = sel,
        filter_chain = filter_chain,
        matches      = matches,
        cursor       = cursor,
    }

    return write_list_file(data, string.format("%s/%s%s", path, session_prefix, LIST_EXT_QF))
end


local function clear_session_lists(abs_path, session_prefix)
    -- Only our quickfix/loclist/launcher files; keep the session script
    local qf_pat = string.format("%s/%s%s", abs_path, session_prefix, LIST_EXT_QF)
    local loc_pat = string.format("%s/%s%s.*.lua", abs_path, session_prefix, LIST_EXT_LOC)
    local lc_pat = string.format("%s/%s%s.*.lua", abs_path, session_prefix, LIST_EXT_LAUNCHER)
    for _, file in ipairs(vim.fn.glob(qf_pat, false, true)) do
        vim.fn.delete(file)
    end
    for _, file in ipairs(vim.fn.glob(loc_pat, false, true)) do
        vim.fn.delete(file)
    end
    for _, file in ipairs(vim.fn.glob(lc_pat, false, true)) do
        vim.fn.delete(file)
    end
end


local function find_target_window(origin)
    if not origin then return nil end
    -- Find the window matching the saved origin context, ignoring quickfix windows.
    local tab_matches = {}
    
    -- 1. by buffer name
    if origin.bufname and origin.bufname ~= '' then
        for _, winid in ipairs(vim.api.nvim_list_wins()) do
            local bufnr = vim.api.nvim_win_get_buf(winid)
            if vim.bo[bufnr].buftype ~= 'quickfix' then
                local ctx = ut.get_window_context(winid)
                if ctx and ctx.bufname == origin.bufname then
                    if ctx.tabpage == origin.tabpage then
                        if ctx.winidx == origin.winidx then
                            return winid  -- exact tab+position match
                        end
                        table.insert(tab_matches, winid)
                    end
                end
            end
        end
    end

    if tab_matches[1] then return tab_matches[1] end

    -- 2. by tab number and window index (scratch buffers)
    if origin.tab_nr and origin.winidx then
        for _, tabpage in ipairs(vim.api.nvim_list_tabpages()) do
            if vim.api.nvim_tabpage_get_number(tabpage) == origin.tab_nr then
                local wins = vim.api.nvim_tabpage_list_wins(tabpage)
                if wins[origin.winidx] then
                    return wins[origin.winidx]
                end
            end
        end
    end

    return nil
end

-- Close empty quickfix/loclist windows, which mksession may have created.
local function close_empty_qf_loc_windows()
    for _, winid in ipairs(vim.api.nvim_list_wins()) do
        local bufnr = vim.api.nvim_win_get_buf(winid)
        if vim.api.nvim_buf_get_name(bufnr) == '' and vim.bo[bufnr].buftype == '' then
            pcall(vim.api.nvim_win_close, winid, true)
        end
    end
end


-- Load and set the list data without opening a window.
-- Returns { kind, [target], filter_chain, matches, cursor }, or nil on error.
local function load_qflist_no_open(path)
    local ok, data = pcall(dofile, path)
    if not ok or type(data) ~= "table" or (not data.items and not data.content) then
        return nil
    end

    if data.kind == "qf" then
        vim.fn.setqflist({}, " ", {
            title = data.title or "Restored Quickfix",
            items = data.items,
        })
        if data.selection and data.selection > 0 then
            vim.fn.setqflist({}, "r", { idx = data.selection })
        end
        return { kind = "qf", title = data.title, filter_chain = data.filter_chain, matches = data.matches, cursor = data.cursor }

    elseif data.kind == "loc" then
        local target = find_target_window(data.origin)
        if not target or not vim.api.nvim_win_is_valid(target) then
            target = vim.api.nvim_get_current_win()
        end
        vim.fn.setloclist(target, {}, " ", {
            title = data.title or "Restored Location List",
            items = data.items,
        })
        if data.selection and data.selection > 0 then
            vim.fn.setloclist(target, {}, "r", { idx = data.selection })
        end
        return { kind = "loc", title = data.title, target = target, filter_chain = data.filter_chain, matches = data.matches, cursor = data.cursor }

    elseif data.kind == "launcher" then
        local target = find_target_window(data.origin)
        local buf = require('launcher').Restore(data)
        if target and vim.api.nvim_win_is_valid(target) then
            vim.api.nvim_win_set_buf(target, buf)
        end
        return { kind = "launcher", target = target, bufnr = buf }
    end

    return nil
end


local function get_unsaved_buffers()
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
    local ok, launcher = pcall(require, 'launcher')
    local processes = ok and launcher.GetRunningProcesses() or {}

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


local function save_session(path)
    local prefix = vim.fn.fnamemodify(path, ':t')
    local dir = vim.fn.fnamemodify(path, ':h')
    clear_session_lists(dir, prefix)
    save_all_loclists(dir, prefix)
    save_all_launchers(dir, prefix)
    save_quickfix(dir, prefix)
    ensure_dir(dir)
    vim.cmd('mksession! ' .. path)
end

local function auto_save()
    if vim.v.this_session ~= "" then
        save_session(vim.v.this_session)
    end
end


local function terminate_all_processes(processes)
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
    -- Two passes: set every list first, so the winidx values stay stable, then
    -- open the windows.
    local prefix = vim.fn.fnamemodify(sess_path, ':t')
    local dir = vim.fn.fnamemodify(sess_path, ':h')
    local patterns = {
        string.format('%s/%s%s', dir, prefix, LIST_EXT_QF),
        string.format('%s/%s%s.*.lua', dir, prefix, LIST_EXT_LOC),
        string.format('%s/%s%s.*.lua', dir, prefix, LIST_EXT_LAUNCHER),
    }
    local to_open = {}
    for _, pat in ipairs(patterns) do
        for _, file in ipairs(vim.fn.glob(pat, false, true)) do
            local result = load_qflist_no_open(file)
            if result then table.insert(to_open, result) end
        end
    end
    local grep = require'grep'
    for _, info in ipairs(to_open) do
        if info.kind == "qf" then
            pcall(vim.cmd, 'copen')
            local qf_winid = vim.fn.getqflist({ winid = 0 }).winid
            if qf_winid and qf_winid ~= 0 then
                if info.title then vim.w[qf_winid].grep_title = info.title end
                if info.filter_chain then grep.set_filter_chain(qf_winid, info.filter_chain) end
                if info.matches then pcall(vim.fn.setmatches, info.matches, qf_winid) end
                if info.cursor then pcall(vim.api.nvim_win_set_cursor, qf_winid, { info.cursor.row, info.cursor.col }) end
            end
        else
            local target = info.target
            vim.api.nvim_set_current_win(target)
            pcall(vim.cmd, 'lopen')
            local loc_winid = vim.fn.getloclist(target, { winid = 0 }).winid
            if loc_winid and loc_winid ~= 0 then
                grep.assign_tag(target, loc_winid)
                if info.title then vim.w[loc_winid].grep_title = info.title end
                if info.filter_chain then grep.set_filter_chain(loc_winid, info.filter_chain) end
                if info.matches then pcall(vim.fn.setmatches, info.matches, loc_winid) end
                if info.cursor then pcall(vim.api.nvim_win_set_cursor, loc_winid, { info.cursor.row, info.cursor.col }) end
                grep.update_loclist_sl(loc_winid)
            end
        end
    end
    close_empty_qf_loc_windows()
    -- mksession records no cmdheight and restores window sizes as fractions of
    -- whatever room is left, so an inflated cmdheight would survive the load.
    -- Assigning it hands those rows back to the windows.
    vim.o.cmdheight = 1
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

    vim.go.tabline = require('tabline').TabLine()
end


-- TODO: Should delete qflist files.
function M.RemoveSession(session_name)
    local this_session_name = vim.fn.fnamemodify(vim.v.this_session, ':p:t')
    if session_name and session_name ~= '' and session_name ~= this_session_name then
        local sname = vim.fn.stdpath('data') .. '/sessions/' .. session_name
        sname = ut.normalize_path_separator(sname)
        if vim.fn.filereadable(sname) == 0 then
            vim.notify(string.format("Session %s doesn't exist.", session_name), vim.log.levels.ERROR)
            return
        end
        vim.fn.delete(sname, "rf")
        vim.notify(string.format('Session %s has been removed.', session_name), vim.log.levels.INFO)
    elseif vim.v.this_session ~= '' then
        if vim.fn.filereadable(vim.v.this_session) == 0 then
            vim.notify(string.format("Session %s doesn't exist.", this_session_name), vim.log.levels.ERROR)
            return
        end
        vim.fn.delete(vim.v.this_session, "rf")
        vim.v.this_session = ''
        vim.notify(string.format('Session %s has been removed.', this_session_name), vim.log.levels.INFO)
    else
        vim.notify('No session name to remove.', vim.log.levels.ERROR)
    end
    vim.o.tabline = require('tabline').TabLine()
end


function M.CloseSession()
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
    api.nvim_create_user_command('RemoveSession', function(t) M.RemoveSession(t.args) end, { nargs='?', complete="customlist,v:lua.require'session'.SessionList" })
    api.nvim_create_user_command('CloseSession', M.CloseSession, {})

    vim.api.nvim_create_autocmd("VimLeave", {
        group = vim.api.nvim_create_augroup("SessionAutoSave", { clear = true }),
        callback = auto_save,
    })

    -- 'nvim -S <session>' sources the file during startup, bypassing
    -- M.OpenSession() and its cmdheight fix above.
    local cmdheight_fix_group = vim.api.nvim_create_augroup("SessionCmdheightFix", { clear = true })
    vim.api.nvim_create_autocmd("VimEnter", {
        group = cmdheight_fix_group,
        callback = function()
            if vim.v.this_session ~= "" then
                vim.o.cmdheight = 1
            end
        end,
    })

    -- A resize reflows windows against the new &lines/&columns, and rows that
    -- don't tile evenly get absorbed into cmdheight, as in mksession's restore.
    -- Entering a tab whose layout was sized for another screen does the same.
    vim.api.nvim_create_autocmd({ "VimResized", "TabEnter" }, {
        group = cmdheight_fix_group,
        callback = function()
            vim.o.cmdheight = 1
        end,
    })

    local exit_warned = false
    local skip_quit_guard = false
    local exit_guard_group = vim.api.nvim_create_augroup("ExitGuard", { clear = true })
    local original_cmd = native_cmd

    local quit_all_commands = { qa = true, qall = true, quita = true, quitall = true }
    local write_quit_all_commands = { wqa = true, wqall = true, xa = true, xall = true }
    local function run_forced_quit(command)
        skip_quit_guard = true
        local ok, err = pcall(original_cmd, command)
        skip_quit_guard = false
        if not ok then error(err) end
    end

    -- Programmatic vim.cmd('qa') does not expand command-line abbreviations.
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

    api.nvim_create_autocmd('CmdlineLeavePre', {
        group = exit_guard_group,
        callback = function()
            local name = vim.fn.getcmdline():match('^%s*(%a+)!%s*$')
            if vim.fn.getcmdtype() == ':' and (quit_all_commands[name] or write_quit_all_commands[name]) then
                skip_quit_guard = true
                vim.schedule(function() skip_quit_guard = false end)
            end
        end,
    })

    local function abort_exit()
        print("Aborting exit...")
        -- A modified buffer is what actually stops :qa
        local abort_buf = vim.api.nvim_create_buf(false, true)
        local unique_id = math.random(1000, 9999)
        pcall(vim.api.nvim_buf_set_name, abort_buf, "[CANCELLED EXIT " .. unique_id .. "]")
        vim.api.nvim_set_option_value('modified', true, { buf = abort_buf })
        
        -- Cleaned up on a timer, so it lives long enough for Neovim to see it
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

    local function handle_quit_guard(cancel_mode, force_global)
        if exit_warned or skip_quit_guard then return true end

        local buf = vim.api.nvim_get_current_buf()
        local wins = vim.api.nvim_list_wins()
        local is_last_win = force_global or (#wins <= 1)
        
        local processes = M.get_running_processes()
        local modified_buffers = get_modified_buffers()
        
        -- Individual buffer closure
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

        -- Neither the last window nor a special buffer: stay silent
        if not is_last_win and not is_unsaved_nofile then
            if not current_proc or is_launcher_buffer or vim.bo[buf].filetype == 'qf' then
                return true
            end
        end

        -- Warning message
        local msg = ""
        
        -- Current buffer's warnings, always shown when closing
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

        -- Confirmed.
        if is_last_win then
            exit_warned = true
            terminate_all_processes(processes)
            clear_modified_buffers(modified_buffers)
        else
            -- An individual :q terminates only the current one
            if current_proc then
                terminate_all_processes({current_proc})
            end
            vim.bo[buf].modified = false
        end
        return true
    end

    api.nvim_create_user_command('SessionQuitAll', function(opts)
        if opts.bang then return run_forced_quit('qa!') end
        if handle_quit_guard('return', true) == false then
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
        if handle_quit_guard('return', true) == false then
            return
        end
        original_cmd('qa')
    end, { bang = true })

    vim.cmd([[cnoreabbrev <expr> wqa (getcmdtype() == ':' && getcmdline() ==# 'wqa' ? 'SessionWriteQuitAll' : 'wqa')]])
    vim.cmd([[cnoreabbrev <expr> wqall (getcmdtype() == ':' && getcmdline() ==# 'wqall' ? 'SessionWriteQuitAll' : 'wqall')]])
    vim.cmd([[cnoreabbrev <expr> xa (getcmdtype() == ':' && getcmdline() ==# 'xa' ? 'SessionWriteQuitAll' : 'xa')]])
    vim.cmd([[cnoreabbrev <expr> xall (getcmdtype() == ':' && getcmdline() ==# 'xall' ? 'SessionWriteQuitAll' : 'xall')]])

    -- Buffer closure and global exit
    vim.api.nvim_create_autocmd("QuitPre", {
        group = exit_guard_group,
        callback = function()
            handle_quit_guard('abort', false)
        end
    })
end


return M
