local M = {}

local ut = require 'util'
local env = require 'env'
local ts = vim.treesitter
local tsutil = require'nvim-treesitter.ts_utils'

local function expand_folder(link)
    if link:sub(1, 1) == '.' and link:sub(1, 2) ~= '..' then
        return vim.fn.expand('%:p:h') .. link:sub(2)
    elseif link:sub(1, 1) == '~' then
        return vim.fn.expand('~') .. link:sub(2)
    else --if not link:find(env.dir_sep) then
        return vim.fn.expand('%:p:h') .. env.dir_sep .. link
    end
end

local function append_md_filetype_extension(link)
    if link:sub(link:len()-2) ~= '.md' then
        return link .. '.md'
    else
        return link
    end
end

local function get_rid_of_bracket(link)
    if link:sub(1,1) == '<' and link:sub(link:len()) == '>' then
        return link:sub(2, link:len()-1)
    else
        return link
    end
end

local function make_absolute_link(link)
    link = get_rid_of_bracket(link)
    link = append_md_filetype_extension(link)
    link = expand_folder(link)
    return link
end

local function goto(link)
    link = make_absolute_link(link)
    vim.fn.execute('edit ' .. link)
end

function M.open_cursor_link()
    local node = tsutil.get_node_at_cursor():parent()
    if node and node:type() == 'inline_link' then
        for n in node:iter_children() do
            if n:type() == 'link_destination' then
                goto(ts.query.get_node_text(n, 0))
            end
        end
    end
end

function M.setup()
    vim.g.vim_markdown_folding_disabled = 1
    vim.api.nvim_create_autocmd('FileType', {pattern = 'markdown', callback = function()
        vim.wo.conceallevel = 2
        ut.nnoremap('<cr>', M.open_cursor_link, {'buffer'})
    end})
end

return M
