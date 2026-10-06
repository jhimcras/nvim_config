local M = {}
local command = 'nvim.markdown.createFile'

local function link_path(bufnr, position, encoding)
    local line = vim.api.nvim_buf_get_lines(bufnr, position.line, position.line + 1, false)[1]
    if not line then return end
    local col = vim.str_byteindex(line, encoding, position.character, false)
    local ok, parser = pcall(vim.treesitter.get_parser, bufnr, 'markdown')
    if not ok or not parser then return end
    parser:parse(true)
    local block = vim.treesitter.get_node({
        bufnr = bufnr, pos = { position.line, col }, ignore_injections = true,
    })
    while block do
        if block:type() == 'fenced_code_block' or block:type() == 'indented_code_block' then return end
        block = block:parent()
    end
    local node = vim.treesitter.get_node({
        bufnr = bufnr, pos = { position.line, col }, ignore_injections = false,
    })
    while node and node:type() ~= 'inline_link' do
        if node:type() == 'image' or node:type() == 'code_span' then return end
        node = node:parent()
    end
    if not node then return end

    local raw
    for child in node:iter_children() do
        if child:type() == 'link_destination' then
            raw = vim.treesitter.get_node_text(child, bufnr)
            break
        end
    end
    if not raw then return end
    raw = raw:gsub('^<', ''):gsub('>$', '')
    if raw:match('^%a[%w+.-]*:') or raw:match('^[/\\]') then return end
    local path = raw:match('^[^#]*'):gsub('%%(%x%x)', function(hex)
        return string.char(tonumber(hex, 16))
    end)
    if path:find('\0', 1, true) or not path:lower():match('%.md$') then return end
    local name = vim.api.nvim_buf_get_name(bufnr)
    if name == '' then return end
    path = vim.fs.normalize(vim.fs.dirname(name) .. '/' .. path)
    if vim.uv.fs_lstat(path) then return end
    return path
end

local function create_file(client, cmd)
    local path = cmd.arguments[1]
    local ok, err = pcall(vim.fn.mkdir, vim.fs.dirname(path), 'p')
    if not ok then
        vim.notify(tostring(err), vim.log.levels.ERROR)
        return
    end
    -- The file may have appeared while the menu was open.
    local fd, open_err = vim.uv.fs_open(path, 'wx', 420)
    if not fd then
        vim.notify(open_err, vim.log.levels.ERROR)
        return
    end
    vim.uv.fs_close(fd)
    local uri = vim.uri_from_fname(path)
    client:notify('workspace/didCreateFiles', { files = { { uri = uri } } })
    -- Oxide 0.25.12 indexes new files on watched-file events, not didCreateFiles alone.
    client:notify('workspace/didChangeWatchedFiles', {
        changes = { { uri = uri, type = vim.lsp.protocol.FileChangeType.Created } },
    })
end

function M.attach(client)
    -- Wrap the client's request once, not per buffer.
    if client.commands[command] then return end
    client.commands[command] = function(cmd) create_file(client, cmd) end
    local request = client.request
    client.request = function(self, method, params, handler, bufnr)
        if method == 'textDocument/rename' and handler then
            return require('lsp_setting.markdown_rename').request(
                request, self, params, handler, bufnr or vim.api.nvim_get_current_buf())
        end
        if method ~= 'textDocument/codeAction' or not handler then
            return request(self, method, params, handler, bufnr)
        end
        bufnr = bufnr or vim.api.nvim_get_current_buf()
        local path = link_path(bufnr, params.range.start, self.offset_encoding)
        return request(self, method, params, function(err, result, ctx, config)
            if not err then
                result = result or {}
                local uri = path and vim.uri_from_fname(path)
                local duplicate = false
                for _, action in ipairs(result) do
                    for _, change in ipairs(action.edit and action.edit.documentChanges or {}) do
                        if change.kind == 'create' and change.uri == uri then duplicate = true end
                    end
                end
                if path and not duplicate then
                    -- A Command executes natively, without server resolve.
                    result[#result + 1] = {
                        title = 'Create File: "' .. vim.fs.basename(path) .. '"',
                        kind = 'quickfix', command = command, arguments = { path },
                    }
                end
                require('lsp_setting.markdown_rename').add_action(self, result, params, bufnr)
            end
            handler(err, result, ctx, config)
        end, bufnr)
    end
end

return M
