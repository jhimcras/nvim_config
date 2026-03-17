local ut = require 'util'
local api = vim.api
local env = require 'env'
local M = {}

function M.asyncGrep(term, word, wndidforll)
    if term == nil or term == '' or term == '\n' then
        print('Cannot grep a blank word')
        return
    end

    local killed = false
    local remain = ""
    local qfwinid

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
        -- !!!!!! different results occured when the tab has chagned
        vim.schedule(function() vim.api.nvim_win_call(qfwinid, function() vim.cmd 'redrawstatus!' end) end)
    end

    local onexit = function()
        killed = true
        if qfwinid then
            vim.api.nvim_win_call(qfwinid, function() vim.cmd 'redrawstatus!' end)
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
    api.nvim_create_user_command('Grep', function(t) M.asyncGrep(t.args, false, vim.fn.win_getid()) end, { nargs='+', bar=true })
    api.nvim_create_user_command('GrepWord', function(t) M.asyncGrep(t.args, true, vim.fn.win_getid()) end, { nargs='+', bar=true })

    ut.nnoremap('<leader>gg', function() prompt_grep(false) end)
    ut.nnoremap('<leader>gw', function() prompt_grep(true) end)

    ut.vnoremap('<leader>s', function() M.asyncGrep(ut.GetSelectWord(), false, vim.fn.win_getid()) end)
    ut.nnoremap('<leader>s', function() M.asyncGrep(vim.fn.expand('<cword>'), true, vim.fn.win_getid()) end)

end

return M
