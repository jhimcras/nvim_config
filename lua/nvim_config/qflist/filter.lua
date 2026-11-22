local M = {}
local api = vim.api
local tag = require('nvim_config.qflist.tag')
local filter_chains = {}  -- list id -> chain (window ids change on lclose/lopen)

-- Id of the list shown in winid: the quickfix list for the quickfix window,
-- else the window's location list.
local function list_id(winid)
    if winid == 0 then winid = vim.api.nvim_get_current_win() end
    local info = vim.fn.getwininfo(winid)[1]
    if info and info.quickfix == 1 and info.loclist == 0 then
        return vim.fn.getqflist({ id = 0 }).id
    end
    return vim.fn.getloclist(winid, { id = 0 }).id
end

local function record_filter(id, term, bang)
    local label = bang and ('!' .. term) or term
    filter_chains[id] = filter_chains[id] or {}
    table.insert(filter_chains[id], label)
    vim.cmd 'redrawstatus!'
end

function M.get_filter_chain(loclist_winid)
    return filter_chains[list_id(loclist_winid)]
end

function M.set_filter_chain(loclist_winid, chain)
    filter_chains[list_id(loclist_winid)] = chain
    tag.update_loclist_sl(loclist_winid)
    vim.cmd 'redrawstatus!'
end

function M.clear_filter_chain(winid)
    filter_chains[list_id(winid)] = nil
end

function M.setup()
    -- hits: 0-based indices of items whose text matches; bufs: each item's
    -- bufnr (empty when no buffer name matches); named: bufnrs whose name
    -- matches. Returns the 0-based indices of the items to keep, in order.
    M._keep_indices = function(n, hits, bufs, named, bang)
        local hit = {}
        for _, i in ipairs(hits) do hit[i] = true end
        local by_name = {}
        for _, b in ipairs(named) do by_name[b] = true end
        local keep = {}
        for i = 0, n - 1 do
            local matches = hit[i] or (bufs[i + 1] ~= nil and by_name[bufs[i + 1]]) or false
            if matches ~= bang then keep[#keep + 1] = i end
        end
        return keep
    end

    -- Items stay in Vim's native list: converting 100k quickfix dicts to Lua
    -- and back costs far more than the filtering. match() over the list of
    -- texts compiles the pattern once, and buffer names are matched once per
    -- buffer instead of once per item.
    local function filter_list(get, set, pat, bang)
        local p = vim.fn.string(pat)
        vim.api.nvim_exec2(table.concat({
            'let s:flt_items = ' .. get,
            "let s:flt_texts = map(copy(s:flt_items), 'v:val.text')",
            'let s:flt_hits = []',
            'let s:flt_i = match(s:flt_texts, ' .. p .. ')',
            'while s:flt_i >= 0',
            '  call add(s:flt_hits, s:flt_i)',
            '  let s:flt_i = match(s:flt_texts, ' .. p .. ', s:flt_i + 1)',
            'endwhile',
            -- Candidate buffers: every existing one plus 0 (bufname(0) is the
            -- alternate buffer, as before). A pattern that matches an empty
            -- name also matches items whose buffer no longer exists, so then
            -- take the candidates from the items themselves.
            'let s:flt_named = match("", ' .. p .. ") >= 0 ? uniq(sort(map(copy(s:flt_items), 'v:val.bufnr'), 'n')) : [0] + map(getbufinfo(), 'v:val.bufnr')",
            "call filter(s:flt_named, 'match(bufname(v:val), " .. p:gsub("'", "''") .. ") >= 0')",
            "let s:flt_bufs = empty(s:flt_named) ? [] : map(copy(s:flt_items), 'v:val.bufnr')",
            "let s:flt_keep = luaeval('require\"nvim_config.qflist.filter\"._keep_indices(_A[1], _A[2], _A[3], _A[4], _A[5])', [len(s:flt_items), s:flt_hits, s:flt_bufs, s:flt_named, " .. (bang and 'v:true' or 'v:false') .. '])',
            -- List indexing walks the linked list, so index through 256-item chunks.
            "let s:flt_chunks = map(range(0, len(s:flt_items) - 1, 256), 's:flt_items[v:val : v:val + 255]')",
            'call ' .. set .. "'r', {'items': map(s:flt_keep, 's:flt_chunks[v:val / 256][v:val % 256]')})",
            'unlet s:flt_items s:flt_texts s:flt_hits s:flt_i s:flt_named s:flt_bufs s:flt_keep s:flt_chunks',
        }, '\n'), {})
    end

    local function strip_pat(raw) return raw:gsub('^/', ''):gsub('/$', '') end

    local function handle_lfilter(opts)
        local winid = vim.api.nvim_get_current_win()
        local term = strip_pat(opts.args)
        -- Items belong to the file window (filewinid).
        local info = vim.fn.getloclist(winid, { filewinid = 0 })
        local owner = (info.filewinid and info.filewinid ~= 0) and info.filewinid or winid
        filter_list('getloclist(' .. owner .. ')', 'setloclist(' .. owner .. ', [], ', term, opts.bang)
        record_filter(list_id(winid), term, opts.bang)
    end

    local function handle_cfilter(opts)
        local term = strip_pat(opts.args)
        filter_list('getqflist()', 'setqflist([], ', term, opts.bang)
        record_filter(vim.fn.getqflist({ id = 0 }).id, term, opts.bang)
    end

    api.nvim_create_user_command('Lfilter', handle_lfilter, { nargs = '+', bang = true, force = true })
    api.nvim_create_user_command('Cfilter', handle_cfilter, { nargs = '+', bang = true, force = true })

end

return M
