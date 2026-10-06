local M = {}
local api = vim.api

function M.setup()
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
        local current_order = vim.w[winid].sort_order or 'desc' -- first press toggles to 'asc'
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
                vim.o.operatorfunc = "v:lua.require'nvim_config.qflist.edit'.delete_operator"
                return 'g@'
            end, { buffer = true, expr = true, silent = true })

            -- Select mode would edit this nomodifiable buffer (E21); use Visual instead.
            vim.keymap.set('n', 'gh', 'v', { buffer = true, silent = true })
            vim.keymap.set('n', 'gH', 'V', { buffer = true, silent = true })

            vim.keymap.set('n', 'sn', function()
                require'nvim_config.qflist.edit'.sort_list()
            end, { buffer = true, silent = true })

            local filter_cword = function()
                local word = vim.fn.expand('<cword>')
                if word == '' then return end
                local winfo = vim.fn.getwininfo(vim.api.nvim_get_current_win())[1]
                local is_loclist = winfo.loclist == 1
                local cur = vim.fn.line('.')
                local pat = '\\v' .. word
                -- First non-matching item at or after the cursor
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
                vim.o.operatorfunc = "v:lua.require'nvim_config.qflist.edit'.delete_operator"
                return 'g@'
            end
            vim.keymap.set('x', 'd', visual_delete, { buffer = true, expr = true, silent = true })
            vim.keymap.set('x', 'x', visual_delete, { buffer = true, expr = true, silent = true })
        end,
    })

end

return M
