local M = {}

local ut = require 'util'
local env = require 'env'
local ts = vim.treesitter
local tsutil = require'nvim-treesitter.ts_utils'
local api = vim.api

local current_buffer = 0
local current_window = 0

-- Args are 0 based and end exclusive index.
local function GetText(row1, col1, row2, col2)
    local lines = api.nvim_buf_get_lines(current_buffer, row1, row2, false)
    if #lines == 1 then
        lines[1] = string.sub(lines[1], col1+1, col2)
    elseif #lines > 1 then
        lines[1] = string.sub(lines[1], col1+1)
        lines[#lines] = string.sub(lines[#lines], 1, col2)
    end
    return lines
end

local function GetMatchNode(match, query)
    local mn = {}
    for id,node in pairs(match) do
        mn[query.captures[id]] = node
    end
    return mn
end

local function IsBetweenRange(cur_row, node)
    local row1, col1, row2, col2 = node:range()
    if cur_row >= row1 and cur_row <= row2 then
        return true
    else
        return false
    end
end

local function ToggleCheckBox()
    local parser = ts.get_parser(current_buffer, 'markdown')
    local tstree = parser:parse()
    if #tstree > 0 then
        local root_node = tstree[1]:root()
        local query = ts.parse_query('markdown', '(task_list_item (list_marker) (paragraph (task_list_item_marker) @marker (text))) @task_item')
        local cur_row = api.nvim_win_get_cursor(current_window)[1]-1
        for pattern, match in query:iter_matches(root_node, current_buffer, 0, vim.fn.line('$')) do
            local mn = GetMatchNode(match, query)
            if IsBetweenRange(cur_row, mn.task_item) then
                local row1, col1, row2, col2 = mn.marker:range()
                local task_list_item_marker = GetText(row1, col1, row2+1, col2)[1]
                if task_list_item_marker == '[ ]' then
                    local cline = api.nvim_buf_get_lines(current_buffer, row1, row1+1, false)
                    cline[1] = vim.fn.substitute(cline[1], '\\[ \\]', '[x]', '')
                    api.nvim_buf_set_lines(current_buffer, row1, row1+1, false, cline)
                elseif task_list_item_marker == '[x]' then
                    local cline = api.nvim_buf_get_lines(current_buffer, row1, row1+1, false)
                    cline[1] = vim.fn.substitute(cline[1], '\\[x\\]', '[ ]', '')
                    api.nvim_buf_set_lines(current_buffer, row1, row1+1, false, cline)
                end
            end
        end
    end
end

local function on_end_of_line()
    if vim.fn.virtcol('.') > vim.fn.virtcol('$')-1 then
        return true
    else
        return false
    end
end

local function get_node_on(row, col)
    local tstree = ts.get_parser(current_buffer, 'markdown'):parse()
    if #tstree > 0 then
        local root_node = tstree[1]:root()
        local n = root_node:descendant_for_range(row, col, row, col)
        return n
    end
end

local function on_list()
    local cur = api.nvim_win_get_cursor(current_window)
    if on_end_of_line() then
        cur = { cur[1]-1,  cur[2]-1 }
    else
        cur = { cur[1]-1, cur[2] }
    end
    local cur_node = get_node_on(cur[1], cur[2])
    while cur_node do
        local node_type = cur_node:type()
        if node_type == 'task_list_item' or node_type == 'list_item' then
            return cur_node
        end
        cur_node = cur_node:parent()
    end
end

local function separate_line_with(prefix)
    local cur = api.nvim_win_get_cursor(current_window)
    local line_text = api.nvim_buf_get_lines(current_buffer, cur[1]-1, cur[1], false)[1]
    local head_text = line_text:sub(0, cur[2]+0)
    local tails_text = line_text:sub(cur[2]+1)
    api.nvim_buf_set_lines(current_buffer, cur[1]-1, cur[1], false, { head_text, (prefix and prefix or '') .. tails_text })
    api.nvim_win_set_cursor(current_window, { cur[1]+1, prefix and prefix:len() or 0 })
end

local function add_new_line_original_method(mode)
    if mode == 'i' then
        separate_line_with()
    elseif mode == 'n' then
        local row = api.nvim_win_get_cursor(current_window)[1]
        vim.fn.append(row, '')
        api.nvim_win_set_cursor(current_window, { row+1, 0 })
    end
end

local function find_node(node, type)
    if not node then
        return
    end
    if node:type() == type then
        return node
    end
    for n in node:iter_children() do
        local found = find_node(n, type)
        if found then
            return found
        end
    end
end

local function get_list_prefix(node)
    local _, indent = node:start()
    local prefix = tsutil.get_node_text(find_node(node, 'list_marker'), current_buffer)[1]
    local task_list_item_marker_node = find_node(node, 'task_list_item_marker')
    if task_list_item_marker_node then
        prefix = prefix .. ' [ ]'
    end
    return string.rep(' ', indent) .. prefix
end

local function is_allowed_to_add_prefix()
    local cur_node = tsutil.get_node_at_cursor(current_window)
    local allow_prefix = false
    if cur_node then
        local type = cur_node:type()
        if type == 'list_marker' or type == 'task_list_item' or type == 'task_list_item_marker' then
            allow_prefix = true
        end
    end
    return allow_prefix
end

local function add_new_list_line(n)
    local row = api.nvim_win_get_cursor(current_window)[1]
    local pr = get_list_prefix(n) .. ' '
    api.nvim_buf_set_lines(current_buffer, row, row, false, { pr })
    api.nvim_win_set_cursor(current_window, { row+1, #pr })
end

local function separate_list_line(n)
    local pr = get_list_prefix(n) .. ' '
    separate_line_with(pr)
end

local function AddNewLine()
    local mode = vim.fn.mode()
    local node = on_list()
    if node then
        if mode == 'n' then
            add_new_list_line(node)
            api.nvim_input('A')
        else
            separate_list_line(node)
        end
    else
        add_new_line_original_method(mode)
    end
end

function M.Test()
    --separate_line_with()
    get_node_on()
end

function M.Test_eol()
    on_list()
end

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
    Dump(link)
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
        -- vim.bo.shiftwidth = 2
        vim.wo.conceallevel = 2
        ut.nnoremap('<cr>', M.open_cursor_link, {'buffer'})
        -- ut.nnoremap('o', AddNewLine, {'buffer'})
        -- ut.inoremap('<cr>', AddNewLine, {'buffer'})
    end})
    -- vim.api.nvim_create_autocmd('BufRead', {pattern = {'*.md', '*.markdown'}, command = "syntax region markdownCodeBlock matchgroup=markdown_code_block start=/`/ end=/`/ concealends" })
    -- vim.cmd('hi link mkdLineBreak Underlined')
end

return M
