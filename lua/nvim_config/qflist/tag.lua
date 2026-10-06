local M = {}
local api = vim.api

local tag_counter = 0
local origin_tags = {}     -- origin_winid -> last tag (survives loclist close)
local active_loclist = {}  -- origin_winid -> current loclist winid
local search_info = {}     -- loclist title -> {term=str, word=bool}

function M.update_loclist_sl(winid)
    -- No window-local statusline: for qf buffers it overwrites the global one.
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

function M.record_search(title, term, word)
    search_info[title] = { term = term, word = word == true }
end

function M.assign_search_tag(origin_winid, loc_winid)
    M.assign_tag(origin_winid, loc_winid)
    origin_tags[origin_winid] = tag_counter
    active_loclist[origin_winid] = loc_winid
end

function M.hide_tag(origin_winid, loc_winid)
    if active_loclist[origin_winid] == loc_winid then
        active_loclist[origin_winid] = nil
        if vim.api.nvim_win_is_valid(origin_winid) then
            vim.w[origin_winid].loclist_tag = nil
            vim.cmd 'redrawstatus!'
        end
    end
end

function M.forget_origin(origin_winid)
    origin_tags[origin_winid] = nil
    active_loclist[origin_winid] = nil
end

function M.setup()
    api.nvim_create_autocmd('BufWinEnter', {
        callback = function(ev)
            local winid = vim.fn.bufwinid(ev.buf)
            if winid == -1 then return end
            if vim.bo[ev.buf].buftype ~= 'quickfix' then return end
            local winfo = vim.fn.getwininfo(winid)[1]
            if not winfo then return end
            -- Tag from the origin window, or origin_tags after an lclose.
            local info = vim.fn.getloclist(winid, { filewinid = 0 })
            if info.filewinid and info.filewinid ~= 0 then
                local filewinid = info.filewinid
                local tag = vim.w[filewinid] and vim.w[filewinid].loclist_tag
                if not tag then
                    tag = origin_tags[filewinid]
                    if tag and vim.api.nvim_win_is_valid(filewinid) then
                        vim.w[filewinid].loclist_tag = tag
                    end
                end
                if tag and not (vim.w[winid] and vim.w[winid].loclist_tag) then
                    vim.w[winid].loclist_tag = tag
                end
                -- Track the active loclist so WinClosed can hide the tag.
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
            -- '' = use global. Only {win=winid}; scope='local' corrupts vim.o.statusline.
            vim.api.nvim_set_option_value('statusline', '', { win = winid })
            M.update_loclist_sl(winid)
            M.restore_highlight(winid)
        end,
    })

end

return M
