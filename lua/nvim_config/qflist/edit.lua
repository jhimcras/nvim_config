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

    -- keys[i] = bufnr * 2^32 + lnum of item i. Returns 0-based item indices
    -- ordered by buffer name, then lnum; ties keep input order ('asc').
    M._sort_perm = function(keys, order)
        -- Group by name (buffers sharing a name sort together, as before);
        -- grep output is usually already in lnum order inside each group.
        local names, groups, group_names, lnums = {}, {}, {}, {}
        for i, key in ipairs(keys) do
            local bufnr = math.floor(key / 4294967296)
            lnums[i] = key - bufnr * 4294967296
            local name = names[bufnr]
            if not name then
                name = vim.fn.bufname(bufnr)
                names[bufnr] = name
            end
            local group = groups[name]
            if not group then
                group = {}
                groups[name] = group
                table.insert(group_names, name)
            end
            group[#group + 1] = i
        end
        table.sort(group_names)

        local perm = {}
        local asc = order == 'asc'
        local first, last, step = 1, #group_names, 1
        if not asc then first, last, step = last, first, -1 end
        for g = first, last, step do
            local group = groups[group_names[g]]
            for i = 2, #group do
                if lnums[group[i - 1]] > lnums[group[i]] then
                    table.sort(group, function(a, b)
                        if lnums[a] ~= lnums[b] then return lnums[a] < lnums[b] end
                        return a < b
                    end)
                    break
                end
            end
            local from, to = 1, #group
            if not asc then from, to = to, from end
            for i = from, to, step do
                perm[#perm + 1] = group[i] - 1
            end
        end
        return perm
    end

    M.sort_list = function()
        local winid = vim.api.nvim_get_current_win()
        if vim.w[winid].grep_status == 'searching' or vim.w[winid].sorting then
            vim.notify("List is being updated. Please wait.", vim.log.levels.WARN)
            return
        end

        local info = vim.fn.getwininfo(winid)[1]
        local is_loclist = info.loclist == 1
        local get_info = function()
            local what = { id = 0, changedtick = 0, size = 0 }
            return is_loclist and vim.fn.getloclist(0, what) or vim.fn.getqflist(what)
        end
        local list = get_info()
        if list.size == 0 then return end

        vim.w[winid].sorting = true
        local current_order = vim.w[winid].sort_order or 'desc' -- first press toggles to 'asc'
        local new_order = current_order == 'asc' and 'desc' or 'asc'
        vim.w[winid].sort_order = new_order

        -- Items stay in Vim's native list: converting 100k quickfix dicts to Lua
        -- and back costs far more than the sort. Lua only orders the
        -- (bufnr, lnum) keys and hands back a permutation.
        local get = is_loclist and 'getloclist(0)' or 'getqflist()'
        local set = is_loclist and 'setloclist(0, [], ' or 'setqflist([], '
        local sorted = vim.w[winid].sorted_list
        if sorted and sorted.id == list.id and sorted.changedtick == list.changedtick then
            -- Unchanged since our last sort: the other direction is its reverse.
            vim.api.nvim_exec2('call ' .. set .. "'r', {'items': reverse(" .. get .. ')})', {})
        else
            vim.api.nvim_exec2(table.concat({
                'let s:sort_items = ' .. get,
                "let s:sort_keys = map(copy(s:sort_items), 'v:val.bufnr * 4294967296 + v:val.lnum')",
                "let s:sort_perm = luaeval('require\"nvim_config.qflist.edit\"._sort_perm(_A[1], _A[2])', [s:sort_keys, '" .. new_order .. "'])",
                -- List indexing walks the linked list, so index through 256-item chunks.
                "let s:sort_chunks = map(range(0, len(s:sort_items) - 1, 256), 's:sort_items[v:val : v:val + 255]')",
                'call ' .. set .. "'r', {'items': map(s:sort_perm, 's:sort_chunks[v:val / 256][v:val % 256]')})",
                'unlet s:sort_items s:sort_keys s:sort_perm s:sort_chunks',
            }, '\n'), {})
        end
        list = get_info()
        vim.w[winid].sorted_list = { id = list.id, changedtick = list.changedtick }

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
                delete_lines(vim.fn.line('.'), vim.fn.line('.') + vim.v.count1 - 1)
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
