local ut = require 'util'
local api = vim.api
local env = require 'env'
local M = {}

local tag_counter = 0
local filter_chains = {}   -- keyed by loclist window ID
local origin_tags = {}     -- origin_winid -> last assigned tag (persists across loclist close)
local active_loclist = {}  -- origin_winid -> current loclist winid
local search_info = {}     -- loclist title -> {term=str, word=bool}

function M.update_loclist_sl(winid)
    -- Do NOT set a window-local statusline here: on this Neovim build, setting one
    -- for a qf/loclist buffer silently overwrites the GLOBAL vim.o.statusline.
    -- The global %!statusline_entry() already handles loclist windows (evaluated
    -- per-window with statusline_winid set), so only a redraw is needed.
    if not winid or not vim.api.nvim_win_is_valid(winid) then return end
    vim.cmd 'redrawstatus!'
end

function M.restore_highlight(loclist_winid)
    local filewinid = vim.fn.getloclist(loclist_winid, { filewinid = 0 }).filewinid
    if not filewinid or filewinid == 0 then return end
    local title = vim.fn.getloclist(filewinid, { title = 0 }).title
    local info = title and search_info[title]
    vim.api.nvim_win_call(loclist_winid, function()
        vim.fn.clearmatches()
        if info then
            if info.word then
                vim.fn.matchadd('Special', [[\v<]] .. info.term .. [[>]])
            else
                vim.fn.matchadd('Special', [[\v]] .. info.term)
            end
        end
    end)
end

function M.assign_tag(origin_winid, loc_winid)
    tag_counter = (tag_counter % 5) + 1
    vim.w[origin_winid].loclist_tag = tag_counter
    vim.w[loc_winid].loclist_tag = tag_counter
end

function M.record_filter(loclist_winid, term, bang)
    if loclist_winid == 0 then
        loclist_winid = vim.api.nvim_get_current_win()
    end
    local label = bang and ('!' .. term) or term
    filter_chains[loclist_winid] = filter_chains[loclist_winid] or {}
    table.insert(filter_chains[loclist_winid], label)
    M.update_loclist_sl(loclist_winid)
    vim.cmd 'redrawstatus!'
end

function M.get_filter_chain(loclist_winid)
    if loclist_winid == 0 then
        loclist_winid = vim.api.nvim_get_current_win()
    end
    return filter_chains[loclist_winid]
end

function M.set_filter_chain(loclist_winid, chain)
    filter_chains[loclist_winid] = chain
    M.update_loclist_sl(loclist_winid)
    vim.cmd 'redrawstatus!'
end

function M.asyncGrep(term, word, wndidforll)
    if term == nil or term == '' or term == '\n' then
        print('Cannot grep a blank word')
        return
    end

    -- Existing grep process for this window?
    local launcher = require'launcher'
    local processes = launcher.GetRunningProcesses()
    for _, p in ipairs(processes) do
        if p.type == 'grep' and p.wndidforll == wndidforll then
            local msg = string.format("Search [%s] is still running for this window. Stop it?", p.title or p.cmd)
            if vim.fn.confirm(msg, "&Yes\n&No", 1) == 1 then
                if p.terminate then p.terminate() end
                launcher.UnregisterProcess(p.key)
            else
                -- Parallel runs would be safe with loclist_nr but confusing, so ask.
            end
        end
    end

    local killed = false
    local remain = ""
    local qfwinid
    local redraw_timer
    local loclist_nr

    local onread = function(err, data)
        if killed then return end

        if err then
            vim.notify("Error reading from process: " .. err, vim.log.levels.ERROR)
            return
        end
        if data then
            data = data:gsub('\r\n', '\n')
            local vals = vim.split(data, "\n")

            remain = remain or ""
            vals[1] = remain .. vals[1]
            if data:sub(-1) ~= "\n" then
                remain = table.remove(vals)
            else
                remain = nil
            end

            local results = {}
            for _, d in ipairs(vals) do
                if d ~= "" then
                    results[#results+1] = d
                end
            end

            if #results > 0 then
                vim.schedule(function()
                    if not killed then
                        -- loclist_nr keeps the results on the right list
                        vim.fn.setloclist(wndidforll, {}, 'a', {nr = loclist_nr, lines = results})
                    end
                end)
            end
        end
    end

    local qf_buf
    local onexit = function(code, signal)
        local final_status = (killed or signal ~= 0) and 'killed' or 'done'
        killed = true
        if redraw_timer then
            redraw_timer:stop()
            redraw_timer:close()
            redraw_timer = nil
        end
        if qfwinid and vim.api.nvim_win_is_valid(qfwinid) then
            vim.w[qfwinid].grep_status = final_status
            M.update_loclist_sl(qfwinid)
            vim.cmd 'redrawstatus!'
        end
        if qf_buf and vim.api.nvim_buf_is_valid(qf_buf) then
            require'launcher'.UnregisterProcess(qf_buf)
        end
    end

    killed = false
    assert(vim.fn.executable('rg') == 1, 'cannot execute ripgrep')
    local prjroot = require'prjroot'.GetCurrentProjectRoot() or
                    vim.b.qf_prjroot or
                    ut.GetCurrentBufferDir()
    -- A loclist window inherited from a vsplit points at a different origin; flush
    -- it so lopen creates a fresh one instead of stealing it.
    vim.api.nvim_set_current_win(wndidforll)
    local inherited = vim.fn.getloclist(wndidforll, { winid = 0 }).winid
    if inherited ~= 0 and vim.api.nvim_win_is_valid(inherited) then
        local origin = vim.fn.getloclist(inherited, { filewinid = 0 }).filewinid
        if origin ~= 0 and origin ~= wndidforll then
            vim.fn.setloclist(wndidforll, {}, 'f')
        end
    end
    local title = string.format("Search: %s │ %s", term, prjroot)
    search_info[title] = {term = term, word = word == true}
    vim.fn.setloclist(wndidforll, {}, ' ', {title = title, items = {}, nr = '$'})
    loclist_nr = vim.fn.getloclist(wndidforll, {nr = '$'}).nr
    vim.cmd.lopen()
    qfwinid = vim.fn.getloclist(wndidforll, { winid = 0 }).winid
    if not qfwinid or qfwinid == 0 then
        qfwinid = vim.fn.win_getid()
    end
    vim.api.nvim_set_current_win(qfwinid)
    qf_buf = vim.api.nvim_win_get_buf(qfwinid)
    -- Clear the window-local statusline so the global one is used.
    vim.api.nvim_set_option_value('statusline', '', { win = qfwinid })
    vim.cmd.nohlsearch()
    vim.b.qf_prjroot = prjroot
    tag_counter = (tag_counter % 5) + 1
    local tag = tag_counter
    vim.w[qfwinid].grep_title = title
    vim.w[wndidforll].loclist_tag = tag
    vim.w[qfwinid].loclist_tag = tag
    origin_tags[wndidforll] = tag
    active_loclist[wndidforll] = qfwinid
    vim.w[qfwinid].grep_status = 'searching'
    filter_chains[qfwinid] = nil
    
    -- Redraw timer for the animation
    redraw_timer = vim.uv.new_timer()
    redraw_timer:start(0, 120, vim.schedule_wrap(function()
        if qfwinid and vim.api.nvim_win_is_valid(qfwinid) then
            vim.cmd('redrawstatus!')
        else
            if redraw_timer then
                redraw_timer:stop()
                redraw_timer:close()
                redraw_timer = nil
            end
        end
    end))
    
    M.update_loclist_sl(qfwinid)
    -- QuitPre fires before Neovim creates the auto-buffer window it would add when
    -- the last normal window quits with a loclist open. Closing the loclist here
    -- leaves the origin as the true last window, so Neovim exits cleanly.
    local quit_handled = false
    local quitpre_au_id
    quitpre_au_id = api.nvim_create_autocmd('QuitPre', {
        callback = function()
            if vim.api.nvim_get_current_win() ~= wndidforll then return end
            pcall(api.nvim_del_autocmd, quitpre_au_id)
            quit_handled = true
            for _, win in ipairs(vim.api.nvim_list_wins()) do
                if vim.api.nvim_win_is_valid(win) then
                    local bt = vim.bo[vim.api.nvim_win_get_buf(win)].buftype
                    if bt == 'quickfix' then
                        local info = vim.fn.getloclist(win, { filewinid = 0 })
                        if info.filewinid == wndidforll then
                            vim.api.nvim_win_close(win, true)
                        end
                    end
                end
            end
        end,
    })

    -- Loclist closed: hide the origin's color tag. BufWinEnter restores it from
    -- origin_tags when lopen reopens the list.
    api.nvim_create_autocmd('WinClosed', {
        pattern = tostring(qfwinid),
        once = true,
        callback = function()
            if active_loclist[wndidforll] == qfwinid then
                active_loclist[wndidforll] = nil
                if vim.api.nvim_win_is_valid(wndidforll) then
                    vim.w[wndidforll].loclist_tag = nil
                    vim.cmd 'redrawstatus!'
                end
            end
        end,
    })

    -- Fallback for non-:q closes (wincmd c, API calls), where QuitPre never fires.
    api.nvim_create_autocmd('WinClosed', {
        pattern = tostring(wndidforll),
        once = true,
        callback = function()
            pcall(api.nvim_del_autocmd, quitpre_au_id)
            origin_tags[wndidforll] = nil
            active_loclist[wndidforll] = nil
            if quit_handled then return end  -- QuitPre already cleaned up
            vim.schedule(function()
                -- Close this origin's loclist windows
                for _, win in ipairs(vim.api.nvim_list_wins()) do
                    if vim.api.nvim_win_is_valid(win) then
                        local buftype = vim.bo[vim.api.nvim_win_get_buf(win)].buftype
                        if buftype == 'quickfix' then
                            local info = vim.fn.getloclist(win, { filewinid = 0 })
                            if info.filewinid == wndidforll then
                                vim.api.nvim_win_close(win, true)
                            end
                        end
                    end
                end
                -- Only Neovim's auto-created empty buffers left: quit cleanly.
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
    vim.fn.clearmatches()
    local args = {'--vimgrep', '--smart-case'}
    if word and word == true then
        args[#args+1] = '--word-regexp'
        vim.fn.matchadd('Special', [[\v<]] .. term .. [[>]])
    else
        vim.fn.matchadd('Special', [[\v]] .. term)
    end
    args[#args+1] = term
    args[#args+1] = prjroot
    redraw_timer = vim.uv.new_timer()
    redraw_timer:start(0, 120, vim.schedule_wrap(function()
        if qfwinid and vim.api.nvim_win_is_valid(qfwinid) then
            M.update_loclist_sl(qfwinid)
        end
    end))
    local wrapped_onexit = function(code, signal)
        onexit(code, signal)
    end

    local pid, term_func, status, handle = ut.AsyncProcess('rg', args, '.', { onread = onread, onexit = wrapped_onexit })
    require'launcher'.RegisterProcess(qf_buf, {
        type = 'grep',
        pid = pid,
        handle = handle,
        cmd = 'rg',
        args = args,
        title = title,
        onexit = wrapped_onexit,
        terminate = term_func,
        wndidforll = wndidforll
    })

    ut.nnoremap('<C-c>', function()
        killed = true
        term_func("sigkill")
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-c>", true, false, true), "n", false)
    end, {buffer = true})
end

function M.prompt_grep(word)
    local prompt = word and "GrepWord > " or "Grep > "
    vim.schedule(function()
        -- local input = vim.fn.input(prompt)
        -- if input ~= nil and input ~= '' then
        --     M.asyncGrep(input, word, vim.fn.win_getid())
        -- end
        vim.ui.input({ prompt = prompt }, function(input) if input then M.asyncGrep(input, word, vim.fn.win_getid()) end end)
    end)
end

function M.setup()
    api.nvim_create_autocmd('BufWinEnter', {
        callback = function(ev)
            local winid = vim.fn.bufwinid(ev.buf)
            if winid == -1 then return end
            if vim.bo[ev.buf].buftype ~= 'quickfix' then return end
            local winfo = vim.fn.getwininfo(winid)[1]
            if not winfo then return end
            -- Take the tag from the origin window, restoring it from origin_tags
            -- when the loclist is reopened after an lclose.
            local info = vim.fn.getloclist(winid, { filewinid = 0 })
            if info.filewinid and info.filewinid ~= 0 then
                local filewinid = info.filewinid
                local tag = vim.w[filewinid] and vim.w[filewinid].loclist_tag
                if not tag then
                    -- Cleared when the previous loclist window closed.
                    tag = origin_tags[filewinid]
                    if tag and vim.api.nvim_win_is_valid(filewinid) then
                        vim.w[filewinid].loclist_tag = tag
                    end
                end
                if tag and not (vim.w[winid] and vim.w[winid].loclist_tag) then
                    vim.w[winid].loclist_tag = tag
                end
                -- New active loclist window for the origin; the WinClosed hides the
                -- tag on an lclose (asyncGrep only covers the first open).
                if active_loclist[filewinid] ~= winid then
                    active_loclist[filewinid] = winid
                    api.nvim_create_autocmd('WinClosed', {
                        pattern = tostring(winid),
                        once = true,
                        callback = function()
                            if active_loclist[filewinid] == winid then
                                active_loclist[filewinid] = nil
                                if vim.api.nvim_win_is_valid(filewinid) then
                                    vim.w[filewinid].loclist_tag = nil
                                    vim.cmd 'redrawstatus!'
                                end
                            end
                        end,
                    })
                end
            end
            -- '' means "use global" for this global-local option, so
            -- %!statusline_entry() renders filter chains, tags and grep status.
            -- Only {win=winid}, NOT scope='local': combining them silently corrupts
            -- vim.o.statusline.
            vim.api.nvim_set_option_value('statusline', '', { win = winid })
            M.update_loclist_sl(winid)
            M.restore_highlight(winid)
        end,
    })

    local function filter_list(get_items, set_items, pat, bang)
        local items = get_items()
        local filtered = {}
        for _, item in ipairs(items) do
            local text = item.text or ''
            local fname = item.bufnr and vim.fn.bufname(item.bufnr) or ''
            local matches = vim.fn.match(text, pat) >= 0 or vim.fn.match(fname, pat) >= 0
            if (bang and not matches) or (not bang and matches) then
                table.insert(filtered, item)
            end
        end
        set_items(filtered)
    end

    local function strip_pat(raw) return raw:gsub('^/', ''):gsub('/$', '') end

    local function handle_lfilter(opts)
        local winid = vim.api.nvim_get_current_win()
        local term = strip_pat(opts.args)
        -- From inside a loclist window getloclist(0) owns it, but the items belong
        -- to the file window (filewinid).
        local info = vim.fn.getloclist(winid, { filewinid = 0 })
        local owner = (info.filewinid and info.filewinid ~= 0) and info.filewinid or winid
        filter_list(
            function() return vim.fn.getloclist(owner) end,
            function(items) vim.fn.setloclist(owner, {}, 'r', { items = items }) end,
            term, opts.bang
        )
        M.record_filter(winid, term, opts.bang)
    end

    local function handle_cfilter(opts)
        local winid = vim.api.nvim_get_current_win()
        local term = strip_pat(opts.args)
        filter_list(
            function() return vim.fn.getqflist() end,
            function(items) vim.fn.setqflist({}, 'r', { items = items }) end,
            term, opts.bang
        )
        M.record_filter(winid, term, opts.bang)
    end

    api.nvim_create_user_command('Lfilter', handle_lfilter, { nargs = '+', bang = true, force = true })
    api.nvim_create_user_command('Cfilter', handle_cfilter, { nargs = '+', bang = true, force = true })

    local function delete_lines(start_line, end_line)
        if start_line < 1 or end_line < start_line then return end
        local info = vim.fn.getwininfo(vim.api.nvim_get_current_win())[1]
        local new_items = {}
        if info.loclist == 1 then
            for i, item in ipairs(vim.fn.getloclist(0)) do
                if i < start_line or i > end_line then
                    table.insert(new_items, item)
                end
            end
            vim.fn.setloclist(0, {}, 'r', { items = new_items })
        else
            for i, item in ipairs(vim.fn.getqflist()) do
                if i < start_line or i > end_line then
                    table.insert(new_items, item)
                end
            end
            vim.fn.setqflist({}, 'r', { items = new_items })
        end
        local new_line = math.min(start_line, #new_items)
        if new_line > 0 then
            vim.api.nvim_win_set_cursor(0, { new_line, 0 })
        end
    end

    M.sort_list = function()
        local winid = vim.api.nvim_get_current_win()
        if vim.w[winid].grep_status == 'searching' or vim.w[winid].sorting then
            vim.notify("List is being updated. Please wait.", vim.log.levels.WARN)
            return
        end

        local info = vim.fn.getwininfo(winid)[1]
        local is_loclist = info.loclist == 1
        local get_items = is_loclist and function() return vim.fn.getloclist(0) end or function() return vim.fn.getqflist() end
        local set_items = is_loclist and function(items) vim.fn.setloclist(0, {}, 'r', { items = items }) end or function(items) vim.fn.setqflist({}, 'r', { items = items }) end

        local items = get_items()
        if #items == 0 then return end

        vim.w[winid].sorting = true
        local current_order = vim.w[winid].sort_order or 'desc' -- toggle logic below will make first press 'asc'
        local new_order = current_order == 'asc' and 'desc' or 'asc'
        vim.w[winid].sort_order = new_order

        table.sort(items, function(a, b)
            local a_name = vim.fn.bufname(a.bufnr)
            local b_name = vim.fn.bufname(b.bufnr)
            if a_name ~= b_name then
                if new_order == 'asc' then
                    return a_name < b_name
                else
                    return a_name > b_name
                end
            end
            if new_order == 'asc' then
                return a.lnum < b.lnum
            else
                return a.lnum > b.lnum
            end
        end)

        set_items(items)
        vim.w[winid].sorting = false
        vim.notify(string.format("Sorted by name (%s)", new_order))
    end

    M.delete_operator = function(_type)
        delete_lines(vim.fn.line("'["), vim.fn.line("']"))
    end

    api.nvim_create_autocmd('FileType', {
        pattern = 'qf',
        callback = function()
            vim.keymap.set('n', 'dd', function()
                delete_lines(vim.fn.line('.'), vim.fn.line('.'))
            end, { buffer = true, silent = true })

            vim.keymap.set('n', 'd', function()
                vim.o.operatorfunc = "v:lua.require'grep'.delete_operator"
                return 'g@'
            end, { buffer = true, expr = true, silent = true })

            -- 'gh'/'gH' enter Select mode, where the next key replaces the selection
            -- before any mapping runs -- E21 on this nomodifiable buffer. Redirect to
            -- Visual mode, where the d/x mappings below already work.
            vim.keymap.set('n', 'gh', 'v', { buffer = true, silent = true })
            vim.keymap.set('n', 'gH', 'V', { buffer = true, silent = true })

            vim.keymap.set('n', 'sn', function()
                require'grep'.sort_list()
            end, { buffer = true, silent = true })

            local filter_cword = function()
                local word = vim.fn.expand('<cword>')
                if word == '' then return end
                local winfo = vim.fn.getwininfo(vim.api.nvim_get_current_win())[1]
                local is_loclist = winfo.loclist == 1
                local cur = vim.fn.line('.')
                local pat = '\\v' .. word
                -- New index of the first non-matching item at or after the cursor
                local new_idx, target_new_idx = 0, nil
                local items = is_loclist and vim.fn.getloclist(0) or vim.fn.getqflist()
                for i, item in ipairs(items) do
                    local text = item.text or ''
                    local fname = item.bufnr and vim.fn.bufname(item.bufnr) or ''
                    local matches = vim.fn.match(text, pat) >= 0 or vim.fn.match(fname, pat) >= 0
                    if not matches then
                        new_idx = new_idx + 1
                        if i >= cur and target_new_idx == nil then
                            target_new_idx = new_idx
                        end
                    end
                end
                target_new_idx = target_new_idx or new_idx  -- fallback: last non-matching
                local cmd = is_loclist and 'Lfilter!' or 'Cfilter!'
                vim.cmd(cmd .. ' /\\v' .. word .. '/')
                if target_new_idx > 0 then
                    local new_items = is_loclist and vim.fn.getloclist(0) or vim.fn.getqflist()
                    vim.api.nvim_win_set_cursor(0, { math.min(target_new_idx, #new_items), 0 })
                end
            end
            vim.keymap.set('n', 'diw', filter_cword, { buffer = true, silent = true })
            vim.keymap.set('n', 'daw', filter_cword, { buffer = true, silent = true })

            local visual_delete = function()
                vim.o.operatorfunc = "v:lua.require'grep'.delete_operator"
                return 'g@'
            end
            vim.keymap.set('x', 'd', visual_delete, { buffer = true, expr = true, silent = true })
            vim.keymap.set('x', 'x', visual_delete, { buffer = true, expr = true, silent = true })
        end,
    })

end

return M
