local M = {}

-- Constants for file extensions
local LIST_EXT_QF = ".qf.lua"
local LIST_EXT_LOC = ".loc"

-- Ensure a directory exists (create if missing)
local function ensure_dir(path)
    if vim.fn.isdirectory(path) == 0 then
        vim.fn.mkdir(path, "p")
    end
end
local env = require 'env'
local api = vim.api
local ut = require 'util'

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

    -- Capture selection index for location list
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

local function save_all_loclists(path, session_prefix)
    -- Ensure the directory exists before writing any files
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

    -- Capture the current selected entry (index)
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
    -- Remove only our quickfix and location list files, keep the main session script
    local qf_pat = string.format("%s/%s%s", abs_path, session_prefix, LIST_EXT_QF)
    local loc_pat = string.format("%s/%s%s.*.lua", abs_path, session_prefix, LIST_EXT_LOC)
    for _, file in ipairs(vim.fn.glob(qf_pat, false, true)) do
        vim.fn.delete(file)
    end
    for _, file in ipairs(vim.fn.glob(loc_pat, false, true)) do
        vim.fn.delete(file)
    end
end


local function find_target_window(origin)
    if not origin then return nil end
    -- Try to find a window that matches the saved origin context, ignoring quickfix windows.
    local tab_matches = {}
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
    -- Fallback: first same-tab window with matching buffer name.
    return tab_matches[1]
end

-- Close any empty quickfix or location list windows (they may be created by mksession)
local function close_empty_qf_loc_windows()
    for _, winid in ipairs(vim.api.nvim_list_wins()) do
        local bufnr = vim.api.nvim_win_get_buf(winid)
        if vim.api.nvim_buf_get_name(bufnr) == '' and vim.bo[bufnr].buftype == '' then
            pcall(vim.api.nvim_win_close, winid, true)
        end
    end
end


-- Load list data and set it, but do not open any window.
-- Returns a table { kind, [target], filter_chain, matches, cursor } or nil on error.
local function load_qflist_no_open(path)
    local ok, data = pcall(dofile, path)
    if not ok or type(data) ~= "table" or not data.items then
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
    end

    return nil
end


local function save_session(path)
    local prefix = vim.fn.fnamemodify(path, ':t')
    local dir = vim.fn.fnamemodify(path, ':h')
    clear_session_lists(dir, prefix)
    save_all_loclists(dir, prefix)
    save_quickfix(dir, prefix)
    ensure_dir(dir)
    vim.cmd('mksession! ' .. path)
end

local function auto_save()
    if vim.v.this_session ~= "" then
        save_session(vim.v.this_session)
    end
end


function M.OpenSession(session)
    auto_save()
    vim.cmd('%bwipeout!')
    local sess_path = string.format('%s/sessions/%s', vim.fn.stdpath('data'), session)
    vim.cmd.source(sess_path)
    -- Load any saved quickfix or location list files for this session.
    -- Two-pass: set all lists first (so winidx values stay stable), then open windows.
    local prefix = vim.fn.fnamemodify(sess_path, ':t')
    local dir = vim.fn.fnamemodify(sess_path, ':h')
    local patterns = {
        string.format('%s/%s%s', dir, prefix, LIST_EXT_QF),
        string.format('%s/%s%s.*.lua', dir, prefix, LIST_EXT_LOC),
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

    vim.go.tabline = require('status').TabLine()
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
    vim.o.tabline = require'status'.TabLine()
end


function M.CloseSession()
    auto_save()
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
    api.nvim_create_user_command('SaveSession', function(t) M.SaveSession(t.args) end, { nargs='?', complete="customlist,v:lua.require'session'.SessionList" })
    api.nvim_create_user_command('RemoveSession', function(t) M.RemoveSession(t.args) end, { nargs='?', complete="customlist,v:lua.require'session'.SessionList" })
    api.nvim_create_user_command('CloseSession', M.CloseSession, {})

    -- Session mapping
    ut.nnoremap('<F12>', M.SaveSession)

    vim.api.nvim_create_autocmd("VimLeave", {
        group = vim.api.nvim_create_augroup("SessionAutoSave", { clear = true }),
        callback = auto_save,
    })
end


return M
