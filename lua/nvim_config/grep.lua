local registry = require('nvim_config.launcher.registry')
local ut = require('nvim_config.util.buffer')
local util_job = require('nvim_config.util.job')
local util_map = require('nvim_config.util.map')
local api = vim.api
local env = require 'nvim_config.env'
local M = {}
local spinner = require('nvim_config.spinner')

local tag = require('nvim_config.qflist.tag')
local filter = require('nvim_config.qflist.filter')

local function confirm_previous_search(wndidforll)
    local processes = registry.list()
    for _, p in ipairs(processes) do
        if p.type == 'grep' and p.wndidforll == wndidforll then
            local msg = string.format("Search [%s] is still running for this window. Stop it?", p.title or p.cmd)
            if vim.fn.confirm(msg, "&Yes\n&No", 1) == 1 then
                if p.terminate then p.terminate() end
                registry.unregister(p.key)
            else
                -- Parallel runs are confusing, so ask.
            end
        end
    end

end

local function make_reader(state)
    return function(err, data)
        if state.killed then return end

        if err then
            vim.notify("Error reading from process: " .. err, vim.log.levels.ERROR)
            return
        end
        if data then
            data = data:gsub('\r\n', '\n')
            local vals = vim.split(data, "\n")

            state.remain = state.remain or ""
            vals[1] = state.remain .. vals[1]
            if data:sub(-1) ~= "\n" then
                state.remain = table.remove(vals)
            else
                state.remain = nil
            end

            local results = {}
            for _, d in ipairs(vals) do
                if d ~= "" then
                    results[#results+1] = d
                end
            end

            if #results > 0 then
                vim.schedule(function()
                    if not state.killed then
                        vim.fn.setloclist(state.wndidforll, {}, 'a', {nr = state.loclist_nr, lines = results})
                    end
                end)
            end
        end
    end

end

local function make_exit_callback(state)
    return function(code, signal)
        local final_status = (state.killed or signal ~= 0) and 'killed' or 'done'
        state.killed = true
        spinner.stop(state.redraw_timer)
        state.redraw_timer = nil
        if state.qfwinid and vim.api.nvim_win_is_valid(state.qfwinid) then
            vim.w[state.qfwinid].grep_status = final_status
            tag.update_loclist_sl(state.qfwinid)
            vim.cmd 'redrawstatus!'
        end
        if state.qf_buf and vim.api.nvim_buf_is_valid(state.qf_buf) then
            registry.unregister(state.qf_buf)
        end
    end

end

local function open_loclist(state, term, word)
    assert(vim.fn.executable('rg') == 1, 'cannot execute ripgrep')
    state.prjroot = require'nvim_config.prjroot'.GetCurrentProjectRoot() or
                    vim.b.qf_prjroot or
                    ut.GetCurrentBufferDir()
    -- A loclist inherited from a vsplit belongs to another origin; flush it.
    vim.api.nvim_set_current_win(state.wndidforll)
    local inherited = vim.fn.getloclist(state.wndidforll, { winid = 0 }).winid
    if inherited ~= 0 and vim.api.nvim_win_is_valid(inherited) then
        local origin = vim.fn.getloclist(inherited, { filewinid = 0 }).filewinid
        if origin ~= 0 and origin ~= state.wndidforll then
            vim.fn.setloclist(state.wndidforll, {}, 'f')
        end
    end
    state.title = string.format("Search: %s │ %s", term, state.prjroot)
    tag.record_search(state.title, term, word)
    vim.fn.setloclist(state.wndidforll, {}, ' ', {title = state.title, items = {}, nr = '$'})
    state.loclist_nr = vim.fn.getloclist(state.wndidforll, {nr = '$'}).nr
    vim.cmd.lopen()
    state.qfwinid = vim.fn.getloclist(state.wndidforll, { winid = 0 }).winid
    if not state.qfwinid or state.qfwinid == 0 then
        state.qfwinid = vim.fn.win_getid()
    end
    vim.api.nvim_set_current_win(state.qfwinid)
    state.qf_buf = vim.api.nvim_win_get_buf(state.qfwinid)
    -- Clear the window-local statusline so the global one is used.
    vim.api.nvim_set_option_value('statusline', '', { win = state.qfwinid })
    vim.cmd.nohlsearch()
    vim.b.qf_prjroot = state.prjroot
    vim.w[state.qfwinid].grep_title = state.title
    tag.assign_search_tag(state.wndidforll, state.qfwinid)
    vim.w[state.qfwinid].grep_status = 'searching'
    filter.clear_filter_chain(state.qfwinid)
    
    state.redraw_timer = spinner.start({ win = state.qfwinid })

    tag.update_loclist_sl(state.qfwinid)
end

local function install_lifecycle(state)
    -- Close the loclist on QuitPre so quitting the last window exits cleanly.
    local quit_handled = false
    local quitpre_au_id
    quitpre_au_id = api.nvim_create_autocmd('QuitPre', {
        callback = function()
            if vim.api.nvim_get_current_win() ~= state.wndidforll then return end
            pcall(api.nvim_del_autocmd, quitpre_au_id)
            quit_handled = true
            for _, win in ipairs(vim.api.nvim_list_wins()) do
                if vim.api.nvim_win_is_valid(win) then
                    local bt = vim.bo[vim.api.nvim_win_get_buf(win)].buftype
                    if bt == 'quickfix' then
                        local info = vim.fn.getloclist(win, { filewinid = 0 })
                        if info.filewinid == state.wndidforll then
                            vim.api.nvim_win_close(win, true)
                        end
                    end
                end
            end
        end,
    })

    -- Loclist closed: hide the origin's tag (BufWinEnter restores it).
    api.nvim_create_autocmd('WinClosed', {
        pattern = tostring(state.qfwinid),
        once = true,
        callback = function()
            spinner.stop(state.redraw_timer)
            state.redraw_timer = nil
            tag.hide_tag(state.wndidforll, state.qfwinid)
        end,
    })

    -- Fallback for closes without QuitPre (wincmd c, API).
    api.nvim_create_autocmd('WinClosed', {
        pattern = tostring(state.wndidforll),
        once = true,
        callback = function()
            pcall(api.nvim_del_autocmd, quitpre_au_id)
            tag.forget_origin(state.wndidforll)
            if quit_handled then return end  -- QuitPre already cleaned up
            vim.schedule(function()
                for _, win in ipairs(vim.api.nvim_list_wins()) do
                    if vim.api.nvim_win_is_valid(win) then
                        local buftype = vim.bo[vim.api.nvim_win_get_buf(win)].buftype
                        if buftype == 'quickfix' then
                            local info = vim.fn.getloclist(win, { filewinid = 0 })
                            if info.filewinid == state.wndidforll then
                                vim.api.nvim_win_close(win, true)
                            end
                        end
                    end
                end
                -- Only auto-created empty buffers left: quit.
                local has_real_win = false
                for _, win in ipairs(vim.api.nvim_list_wins()) do
                    if vim.api.nvim_win_is_valid(win) then
                        local buf = vim.api.nvim_win_get_buf(win)
                        local bt = vim.bo[buf].buftype
                        if bt ~= 'quickfix' then
                            local name = vim.api.nvim_buf_get_name(buf)
                            if name ~= '' or vim.bo[buf].modified then
                                has_real_win = true
                                break
                            end
                        end
                    end
                end
                if not has_real_win then
                    vim.cmd('qall!')
                end
            end)
        end,
    })
end

local function search_args(state, term, word)
    vim.fn.clearmatches()
    local args = {'--vimgrep', '--smart-case'}
    if word and word == true then
        args[#args+1] = '--word-regexp'
        vim.fn.matchadd('Special', [[\v<]] .. term .. [[>]])
    else
        vim.fn.matchadd('Special', [[\v]] .. term)
    end
    args[#args+1] = term
    args[#args+1] = state.prjroot
    return args
end

local function launch_process(state, args, onread, onexit)
    local wrapped_onexit = function(code, signal)
        onexit(code, signal)
    end

    local pid, term_func, status, handle = util_job.AsyncProcess('rg', args, '.', { onread = onread, onexit = wrapped_onexit })
    registry.register(state.qf_buf, {
        type = 'grep',
        pid = pid,
        handle = handle,
        cmd = 'rg',
        args = args,
        title = state.title,
        onexit = wrapped_onexit,
        terminate = term_func,
        wndidforll = state.wndidforll
    })

    util_map.nnoremap('<C-c>', function()
        state.killed = true
        term_func("sigkill")
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-c>", true, false, true), "n", false)
    end, {buffer = true})
end

function M.asyncGrep(term, word, wndidforll)
    if term == nil or term == '' or term == '\n' then
        print('Cannot grep a blank word')
        return
    end
    confirm_previous_search(wndidforll)
    local state = { killed = false, remain = "", wndidforll = wndidforll }
    local onread = make_reader(state)
    local onexit = make_exit_callback(state)
    open_loclist(state, term, word)
    install_lifecycle(state)
    launch_process(state, search_args(state, term, word), onread, onexit)
end

function M.prompt_grep(word)
    local prompt = word and "GrepWord > " or "Grep > "
    vim.schedule(function()
        vim.ui.input({ prompt = prompt }, function(input) if input then M.asyncGrep(input, word, vim.fn.win_getid()) end end)
    end)
end

function M.setup()
    api.nvim_create_user_command('Grep', function(t) M.asyncGrep(t.args, false, vim.fn.win_getid()) end, { nargs='+', bar=true })
    api.nvim_create_user_command('GrepWord', function(t) M.asyncGrep(t.args, true, vim.fn.win_getid()) end, { nargs='+', bar=true })
end

return M
