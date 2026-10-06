local M = {}

local function on_link(bufnr, position, encoding)
    local line = vim.api.nvim_buf_get_lines(bufnr, position.line, position.line + 1, false)[1]
    if not line then return false end
    local col = vim.str_byteindex(line, encoding, position.character, false)
    local ok, parser = pcall(vim.treesitter.get_parser, bufnr, 'markdown')
    if not ok or not parser then return false end
    parser:parse(true)
    local block = vim.treesitter.get_node({ bufnr = bufnr, pos = { position.line, col }, ignore_injections = true })
    while block do
        if block:type() == 'fenced_code_block' or block:type() == 'indented_code_block' then return false end
        block = block:parent()
    end
    local node = vim.treesitter.get_node({ bufnr = bufnr, pos = { position.line, col }, ignore_injections = false })
    local link
    while node do
        local kind = node:type()
        if kind == 'image' or kind == 'code_span' or kind == 'fenced_code_block'
            or kind == 'indented_code_block' then return false end
        if kind == 'inline_link' then link = node end
        node = node:parent()
    end
    if link then
        for child in link:iter_children() do
            if child:type() == 'link_destination' then
                local raw = vim.treesitter.get_node_text(child, bufnr):gsub('^<', ''):gsub('>$', '')
                if raw:match('^%a[%w+.-]*:') then return false end
                local path = raw:match('^[^#]*'):gsub('%%(%x%x)', function(hex)
                    return string.char(tonumber(hex, 16))
                end)
                if path == '' then path = vim.api.nvim_buf_get_name(bufnr)
                elseif not path:match('^[/\\]') then
                    path = vim.fs.dirname(vim.api.nvim_buf_get_name(bufnr)) .. '/' .. path
                end
                return vim.uri_from_fname(vim.fs.normalize(path))
            end
        end
        return false
    end
    local start = 1
    while true do
        local first, last = line:find('%[%[.-%]%]', start)
        if not first then return false end
        if col >= first - 1 and col < last then return true end
        start = last + 1
    end
end

-- Oxide 0.25.12 corrupts Markdown labels and omits .md in rename edits.
local function repair_markdown_edits(edit, encoding)
    for _, change in ipairs(edit and edit.documentChanges or {}) do
        if change.textDocument then
            local buf = vim.uri_to_bufnr(change.textDocument.uri)
            vim.fn.bufload(buf)
            for _, text_edit in ipairs(change.edits) do
                if text_edit.newText:match('^%[') and not text_edit.newText:match('^%[%[') then
                    local range = text_edit.range
                    local lines = vim.api.nvim_buf_get_lines(buf, range.start.line, range['end'].line + 1, false)
                    local first = vim.str_byteindex(lines[1], encoding, range.start.character, false)
                    local last = vim.str_byteindex(lines[#lines], encoding, range['end'].character, false)
                    local original = table.concat(vim.api.nvim_buf_get_text(buf,
                        range.start.line, first, range['end'].line, last, {}), '\n')
                    local prefix, destination, suffix = original:match('^(%[.-%]%(%s*<?)([^%s>)]+)(.*)$')
                    local renamed = text_edit.newText:match('%]%(([^)#]+)')
                    if prefix and renamed then
                        local path, anchor = destination:match('^([^#]*)(.*)$')
                        local directory = path:match('^(.*[/])') or ''
                        local name = renamed:gsub('%.md$', '') .. '.md'
                        text_edit.newText = prefix .. directory .. vim.uri_encode(name, 'rfc3986') .. anchor .. suffix
                    end
                end
            end
        end
    end
end

function M.request(request, client, params, handler, bufnr)
    local link = on_link(bufnr, params.position, client.offset_encoding)
    if not link then
        return request(client, 'textDocument/rename', params, handler, bufnr)
    end
    local function resolve(err, locations, ctx, config)
        if err then handler(err, nil, ctx, config); return end
        if not locations or #locations ~= 1 then
            handler({ code = -32602, message = 'Rename requires one resolved Markdown link target' }, nil, ctx, config)
            return
        end
        local uri = locations[1].uri or locations[1].targetUri
        if not uri or not uri:match('^file:') or not vim.uri_to_fname(uri):lower():match('%.md$') then
            handler({ code = -32602, message = 'Rename requires a Markdown file target' }, nil, ctx, config)
            return
        end
        local target = vim.uri_to_bufnr(uri)
        vim.fn.bufload(target)
        local redirected = vim.deepcopy(params)
        redirected.textDocument = { uri = uri }
        -- Oxide falls back to the file outside heading/tag ranges. The line
        -- after EOF avoids renaming a heading even in a heading-only file.
        redirected.position = { line = vim.api.nvim_buf_line_count(target), character = 0 }
        return request(client, 'textDocument/rename', redirected, function(rename_err, result, rename_ctx, rename_config)
            if not rename_err then repair_markdown_edits(result, client.offset_encoding) end
            handler(rename_err, result, rename_ctx, rename_config)
        end, bufnr)
    end
    if type(link) == 'string' then
        local path = vim.uri_to_fname(link)
        if vim.fn.filereadable(path) ~= 1 then
            return resolve(nil, {}, { bufnr = bufnr })
        end
        return resolve(nil, { { uri = link } }, { bufnr = bufnr })
    end
    return request(client, 'textDocument/definition', {
        textDocument = params.textDocument, position = params.position,
    }, resolve, bufnr)
end

function M.add_action(client, result, params, bufnr)
    local link = on_link(bufnr, params.range.start, client.offset_encoding)
    if not link then return end
    if type(link) == 'string' and vim.fn.filereadable(vim.uri_to_fname(link)) ~= 1 then return end
    for _, action in ipairs(result) do
        for _, change in ipairs(action.edit and action.edit.documentChanges or {}) do
            if change.kind == 'create' then return end
        end
    end
    local command = 'nvim.markdown.renameLinkedFile'
    client.commands[command] = function(cmd)
        local args = cmd.arguments[1]
        if not vim.api.nvim_buf_is_valid(args.bufnr) then return end
        vim.ui.input({ prompt = 'New file name: ' }, function(name)
            if not name or name == '' then return end
            client:request('textDocument/rename', {
                textDocument = { uri = vim.uri_from_bufnr(args.bufnr) },
                position = args.position, newName = name,
            }, function(err, edit)
                if err then vim.notify(err.message, vim.log.levels.ERROR); return end
                if edit then vim.lsp.util.apply_workspace_edit(edit, client.offset_encoding) end
            end, args.bufnr)
        end)
    end
    result[#result + 1] = { title = 'Rename Linked File', kind = 'refactor.rename',
        command = command, arguments = { { bufnr = bufnr, position = params.range.start } } }
end

return M
