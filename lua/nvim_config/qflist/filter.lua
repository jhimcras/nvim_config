local M = {}
local api = vim.api
local tag = require('nvim_config.qflist.tag')
local filter_chains = {}

function M.record_filter(loclist_winid, term, bang)
    if loclist_winid == 0 then
        loclist_winid = vim.api.nvim_get_current_win()
    end
    local label = bang and ('!' .. term) or term
    filter_chains[loclist_winid] = filter_chains[loclist_winid] or {}
    table.insert(filter_chains[loclist_winid], label)
    tag.update_loclist_sl(loclist_winid)
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
    tag.update_loclist_sl(loclist_winid)
    vim.cmd 'redrawstatus!'
end

function M.clear_filter_chain(winid)
    filter_chains[winid] = nil
end

function M.setup()
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
        -- Items belong to the file window (filewinid).
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

end

return M
