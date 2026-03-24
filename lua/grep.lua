local ut = require 'util'
local api = vim.api
local env = require 'env'
local M = {}

local tag_counter = 0
local filter_chains = {}  -- keyed by loclist window ID

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
    if vim.api.nvim_win_is_valid(loclist_winid) then
        vim.api.nvim_win_call(loclist_winid, function() vim.cmd 'redrawstatus' end)
    end
end

function M.get_filter_chain(loclist_winid)
    if loclist_winid == 0 then
        loclist_winid = vim.api.nvim_get_current_win()
    end
    return filter_chains[loclist_winid]
end

function M.asyncGrep(term, word, wndidforll)
    if term == nil or term == '' or term == '\n' then
        print('Cannot grep a blank word')
        return
    end

    local killed = false
    local remain = ""
    local qfwinid
    local redraw_timer

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
                        vim.fn.setloclist(wndidforll, {}, 'a', {lines = results})
                    end
                end)
            end
        end
    end

    local onexit = function()
        local final_status = killed and 'killed' or 'done'
        killed = true
        if redraw_timer then
            redraw_timer:stop()
            redraw_timer:close()
            redraw_timer = nil
        end
        if qfwinid and vim.api.nvim_win_is_valid(qfwinid) then
            vim.w[qfwinid].grep_status = final_status
            vim.api.nvim_win_call(qfwinid, function() vim.cmd 'redrawstatus' end)
        end
    end

    killed = false
    assert(vim.fn.executable('rg') == 1, 'cannot execute ripgrep')
    local prjroot = require'prjroot'.GetCurrentProjectRoot() or
                    vim.b.qf_prjroot or
                    ut.GetCurrentBufferDir()
    vim.fn.setloclist(wndidforll, {}, ' ', {title = string.format("Search: %s │ %s", term, prjroot), items = {}, nr = '$'})
    vim.cmd.lopen()
    vim.cmd.nohlsearch()
    vim.b.qf_prjroot = prjroot
    qfwinid = vim.fn.win_getid()
    tag_counter = (tag_counter % 5) + 1
    local tag = tag_counter
    vim.w[wndidforll].loclist_tag = tag
    vim.w[qfwinid].loclist_tag = tag
    api.nvim_create_autocmd('WinClosed', {
        pattern = tostring(wndidforll),
        once = true,
        callback = function()
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
    vim.w[qfwinid].grep_status = 'searching'
    filter_chains[qfwinid] = nil
    redraw_timer = vim.uv.new_timer()
    redraw_timer:start(0, 120, vim.schedule_wrap(function()
        if qfwinid and vim.api.nvim_win_is_valid(qfwinid) then
            vim.api.nvim_win_call(qfwinid, function() vim.cmd 'redrawstatus' end)
        end
    end))
    local pid, term_func, status = ut.AsyncProcess('rg', args, '.', { onread = onread, onexit = onexit })

    ut.nnoremap('<C-c>', function()
        killed = true
        term_func("sigkill")
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-c>", true, false, true), "n", false)
    end, {buffer = true})
end

local function prompt_grep(word)
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
        callback = function()
            local winid = vim.fn.win_getid()
            if vim.bo.buftype ~= 'quickfix' then return end
            local info = vim.fn.getloclist(winid, { filewinid = 0 })
            if not info.filewinid or info.filewinid == 0 then return end
            local tag = vim.w[info.filewinid] and vim.w[info.filewinid].loclist_tag
            if tag then
                vim.w[winid].loclist_tag = tag
            end
        end,
    })

    api.nvim_create_user_command('Grep', function(t) M.asyncGrep(t.args, false, vim.fn.win_getid()) end, { nargs='+', bar=true })
    api.nvim_create_user_command('GrepWord', function(t) M.asyncGrep(t.args, true, vim.fn.win_getid()) end, { nargs='+', bar=true })

    ut.nnoremap('<leader>gg', function() prompt_grep(false) end)
    ut.nnoremap('<leader>gw', function() prompt_grep(true) end)

    ut.vnoremap('<leader>s', function() M.asyncGrep(ut.GetSelectWord(), false, vim.fn.win_getid()) end)
    ut.nnoremap('<leader>s', function() M.asyncGrep(vim.fn.expand('<cword>'), true, vim.fn.win_getid()) end)

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

    local function strip_pat(raw) return raw:gsub('^/', ''):gsub('/$', ''):gsub('^\\v', '') end

    local function handle_lfilter(opts)
        local winid = vim.api.nvim_get_current_win()
        local term = strip_pat(opts.args)
        filter_list(
            function() return vim.fn.getloclist(0) end,
            function(items) vim.fn.setloclist(0, {}, 'r', { items = items }) end,
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

            local filter_cword = function()
                local word = vim.fn.expand('<cword>')
                if word == '' then return end
                local winfo = vim.fn.getwininfo(vim.api.nvim_get_current_win())[1]
                local is_loclist = winfo.loclist == 1
                local cur = vim.fn.line('.')
                local pat = '\\v' .. word
                -- Find new index of the first non-matching item at or after cursor
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

            local del_visual = function()
                delete_lines(vim.fn.line("'<"), vim.fn.line("'>"))
            end
            vim.keymap.set('v', 'd', del_visual, { buffer = true, silent = true })
            vim.keymap.set('v', 'x', del_visual, { buffer = true, silent = true })
        end,
    })

end

return M
