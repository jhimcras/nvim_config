local ut = require 'util'
local api = vim.api
local env = require 'env'
local M = {}

local function onread(err, data)
    assert(not err, err)
    if data then
        local vals = vim.split(data, env.new_line_char)
        local results = {}
        for _, d in ipairs(vals) do
            if d ~= "" then
                results[#results+1] = d
            end
        end
        vim.schedule_wrap(function() vim.fn.setqflist({}, 'a', {lines = results}) end)()
    end
end

-- TODO: searching needs to be canceled and make sure processing previous searching terminated
-- The information quickfix buffer has cleared after `cclose`.
function M.asyncGrep(term, word)
    assert(vim.fn.executable('rg') == 1, 'cannot execute ripgrep')
    local prjroot = require'prjroot'.GetCurrentProjectRoot() or
                    vim.b.qf_prjroot or
                    vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ':p:h')
    vim.fn.setqflist({}, 'r', {title = string.format([[%s │ %s]], term, prjroot), lines = {}})
    vim.cmd.copen()
    vim.cmd.nohlsearch()
    vim.b.qf_prjroot = prjroot
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
    ut.AsyncProcess('rg', args, '.', nil, onread)
end

function M.setup()
    api.nvim_create_user_command('Grep', function(t) M.asyncGrep(t.args, false) end, { nargs='+', bar=true })
    api.nvim_create_user_command('GrepWord', function(t) M.asyncGrep(t.args, true) end, { nargs='+', bar=true })

    ut.vnoremap('<leader>s', function() M.asyncGrep(ut.GetSelectWord(), false) end)
    ut.nnoremap('<leader>s', function() M.asyncGrep(vim.fn.expand('<cword>'), true) end)

end

return M
