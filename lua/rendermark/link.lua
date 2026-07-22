-- rendermark link navigation: tag-jump style follow for markdown [text](link).
--
-- <C-]> follows the link under the cursor; <C-}> follows it into a vertical
-- split. http(s):// links open in the system browser; #anchor links jump to
-- a matching heading (in the current buffer, or in the target file for
-- path.md#anchor). Jumps push a jumplist entry so <C-o>/<C-i> navigate back
-- and forth, same as Neovim's own go-to-definition.

local ut = require 'util'
local scan = require 'rendermark.image.scan'
local tsutil = require 'nvim-treesitter.ts_utils'

local M = {}

local function get_link_node_at_cursor()
    local ok, node = pcall(tsutil.get_node_at_cursor)
    if not ok or not node then return nil end
    while node do
        if node:type() == 'inline_link' then return node end
        node = node:parent()
    end
    return nil
end

local function link_destination_text(node, buf)
    for child in node:iter_children() do
        if child:type() == 'link_destination' then
            local text = vim.treesitter.get_node_text(child, buf)
            if text:sub(1, 1) == '<' and text:sub(-1) == '>' then
                text = text:sub(2, -2)
            end
            return text
        end
    end
    return nil
end

local function get_wikilink_at_cursor()
    local _, col = unpack(vim.api.nvim_win_get_cursor(0))
    local line = vim.api.nvim_get_current_line()
    local search_start = 1
    while true do
        local s, e, inner = line:find('%[%[(.-)%]%]', search_start)
        if not s then return nil end
        if col + 1 >= s and col + 1 <= e then return inner end
        search_start = e + 1
    end
end

local function is_url(raw)
    return raw:match('^%a[%w+.-]*://') ~= nil
end

local function parse_destination(raw)
    if is_url(raw) then
        return { kind = 'url', raw = raw }
    end
    local path, anchor = raw:match('^([^#]*)#?(.*)$')
    if path == '' then
        return { kind = 'anchor', anchor = anchor }
    end
    return { kind = 'file', path = path, anchor = anchor }
end

local function slugify(text)
    text = text:gsub('^%s+', ''):gsub('%s+$', ''):lower()
    text = text:gsub('%s+', '-')
    text = text:gsub('[^%w%-_]', '')
    return text
end

local function find_heading_line(buf, anchor)
    local target = slugify(anchor)
    if target == '' then return nil end
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    for row, line in ipairs(lines) do
        local heading = line:match('^#+%s+(.+)')
        if heading and slugify(heading) == target then
            return row - 1
        end
    end
    return nil
end

local function jump_to_anchor(buf, anchor)
    if anchor == '' then return end
    local row = find_heading_line(buf, anchor)
    if row then
        vim.api.nvim_win_set_cursor(0, { row + 1, 0 })
    else
        vim.notify('rendermark: heading not found: #' .. anchor, vim.log.levels.WARN)
    end
end

local function open_target(dest, split, buf)
    if dest.kind == 'url' then
        vim.ui.open(dest.raw)
        return
    end
    if dest.kind == 'anchor' then
        if split then vim.cmd.vsplit() end
        jump_to_anchor(buf, dest.anchor)
        return
    end
    local resolved = scan.resolve_image_path(buf, dest.path)
    if not resolved or vim.fn.filereadable(resolved) ~= 1 then
        vim.notify('rendermark: file not found: ' .. dest.path, vim.log.levels.WARN)
        return
    end
    if split then
        vim.cmd.vsplit { args = { resolved } }
    else
        vim.cmd.edit { args = { resolved } }
    end
    if dest.anchor ~= '' then
        jump_to_anchor(vim.api.nvim_get_current_buf(), dest.anchor)
    end
end

local function follow_link(split)
    local buf = vim.api.nvim_get_current_buf()
    local dest
    local node = get_link_node_at_cursor()
    if node then
        local raw = link_destination_text(node, buf)
        if raw and raw ~= '' then dest = parse_destination(raw) end
    end
    if not dest then
        local wiki = get_wikilink_at_cursor()
        if wiki then
            local name, anchor = wiki:match('^([^#]*)#?(.*)$')
            if not name:match('%.%w+$') then name = name .. '.md' end
            dest = { kind = 'file', path = name, anchor = anchor or '' }
        end
    end
    if not dest then return false end
    vim.cmd("normal! m'")
    open_target(dest, split, buf)
    return true
end

local function location_target_exists(loc)
    local uri = loc.uri or loc.targetUri
    if not uri then return false end
    return vim.fn.filereadable(vim.uri_to_fname(uri)) == 1
end

local function lsp_definition_found(buf)
    local win = vim.api.nvim_get_current_win()
    local clients = vim.tbl_filter(function(c)
        return c:supports_method('textDocument/definition')
    end, vim.lsp.get_clients({ bufnr = buf }))
    if #clients == 0 then return false end
    local params = vim.lsp.util.make_position_params(win, clients[1].offset_encoding)
    local responses = vim.lsp.buf_request_sync(buf, 'textDocument/definition', params, 1000)
    if not responses then return false end
    for _, resp in pairs(responses) do
        local result = resp and resp.result
        if result then
            local locations = vim.islist(result) and result or { result }
            for _, loc in ipairs(locations) do
                if location_target_exists(loc) then return true end
            end
        end
    end
    return false
end

local function feed_tagjump()
    vim.cmd('normal! ' .. vim.api.nvim_replace_termcodes('<C-]>', true, false, true))
end

function M.setup(_)
    local group = vim.api.nvim_create_augroup('rendermark_link', { clear = true })
    vim.api.nvim_create_autocmd('FileType', {
        group = group,
        pattern = { 'markdown', 'markdown.mdx' },
        callback = function(args)
            local buf = args.buf
            ut.nnoremap('<C-]>', function()
                if lsp_definition_found(buf) then
                    feed_tagjump()
                elseif not follow_link(false) then
                    feed_tagjump()
                end
            end, { buffer = buf })
            ut.nnoremap('<C-}>', function()
                if lsp_definition_found(buf) then
                    vim.cmd('vsplit')
                    feed_tagjump()
                elseif not follow_link(true) then
                    feed_tagjump()
                end
            end, { buffer = buf })
        end,
    })
end

M.is_url = is_url
M.parse_destination = parse_destination
M.slugify = slugify

return M
