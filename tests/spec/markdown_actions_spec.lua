local actions = require('lsp_setting.markdown_actions')

describe('Markdown file creation actions', function()
    local root, buf, client, response, request_error, notifications, calls, notify

    before_each(function()
        root = vim.fn.tempname()
        vim.fn.mkdir(root .. '/docs', 'p')
        buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_name(buf, root .. '/docs/source.md')
        vim.bo[buf].filetype = 'markdown'
        response, notifications, calls = {}, {}, {}
        request_error = nil
        notify = vim.notify
        vim.notify = function() end
        client = {
            offset_encoding = 'utf-16', commands = {},
            request = function(_, method, params, handler, bufnr)
                calls[#calls + 1] = { method = method, params = params, bufnr = bufnr }
                handler(request_error, response, { bufnr = bufnr })
                return true, 17
            end,
            notify = function(_, method, params)
                notifications[#notifications + 1] = { method = method, params = params }
            end,
        }
        actions.attach(client)
    end)

    after_each(function()
        vim.notify = notify
        vim.api.nvim_buf_delete(buf, { force = true })
        vim.fn.delete(root, 'rf')
    end)

    local function request(lines, row, character)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
        local result, err
        local success, id = client:request('textDocument/codeAction', {
            range = { start = { line = row or 0, character = character or 10 } },
        }, function(e, r) err, result = e, r end, buf)
        assert.is_true(success)
        assert.equals(17, id)
        return result, err
    end

    it('preserves server actions and creates relative files with encoded spaces and anchors', function()
        response = { { title = 'Server action', command = 'server.command' } }
        local result = request({ '[text](./sub/new%20note.md#heading "title")' })
        assert.equals(2, #result)
        assert.equals('Server action', result[1].title)
        local action = result[2]
        local path = root .. '/docs/sub/new note.md'
        assert.equals(path, action.arguments[1])
        assert.equals('quickfix', action.kind)
        client.commands[action.command](action)
        assert.equals(1, vim.fn.filereadable(path))
        assert.equals('workspace/didCreateFiles', notifications[1].method)
        assert.equals(vim.uri_from_fname(path), notifications[1].params.files[1].uri)
        assert.equals('workspace/didChangeWatchedFiles', notifications[2].method)
        assert.equals(1, notifications[2].params.changes[1].type)
        response = {}
        assert.equals(0, #request({ '[text](./sub/new%20note.md#heading)' }))
    end)

    it('does not truncate a file created while the menu was open', function()
        local action = request({ '[text](new.md)' })[1]
        vim.fn.writefile({ 'keep this content' }, action.arguments[1])
        client.commands[action.command](action)
        assert.same({ 'keep this content' }, vim.fn.readfile(action.arguments[1]))
        assert.equals(0, #notifications)
    end)

    it('excludes URLs, images, anchors, non-Markdown files, and code', function()
        for _, line in ipairs({
            '[text](https://example.com/new.md)', '[text](mailto:new.md)',
            '![image](new.md)', '[text](#heading)', '[text](new.png)',
            '`[text](new.md)`', '    [text](new.md)', '[[new.md]]',
        }) do
            assert.equals(0, #request({ line }))
        end
        assert.equals(0, #request({ '```markdown', '[text](new.md)', '```' }, 1))
    end)

    it('uses LSP character encoding with Korean text before the link', function()
        local result = request({ '한글 [text](new.md)' }, 0, 12)
        assert.equals(root .. '/docs/new.md', result[1].arguments[1])
    end)

    it('accepts a cursor on the label and angle-bracket destinations', function()
        local result = request({ '[text](<new note.md>)' }, 0, 2)
        assert.equals(root .. '/docs/new note.md', result[1].arguments[1])
    end)

    it('does not duplicate a server CreateFile operation', function()
        response = { { title = 'Server create', edit = { documentChanges = {
            { kind = 'create', uri = vim.uri_from_fname(root .. '/docs/new.md') },
        } } } }
        assert.equals(1, #request({ '[text](new.md)' }))
    end)

    it('preserves server errors and does not wrap twice on a second attachment', function()
        local wrapper = client.request
        actions.attach(client)
        assert.equals(wrapper, client.request)
        request_error = { code = -32800, message = 'cancelled' }
        response = nil
        local result, err = request({ '[text](new.md)' })
        assert.is_nil(result)
        assert.same(request_error, err)
    end)

    it('passes other requests through unchanged', function()
        local params = { textDocument = { uri = 'file:///source.md' } }
        client:request('textDocument/hover', params, function() end, buf)
        assert.equals('textDocument/hover', calls[1].method)
        assert.equals(params, calls[1].params)
    end)
end)

describe('Markdown actions in the native LSP menu', function()
    local root, buf, client, select, previous_buf

    after_each(function()
        if select then vim.ui.select = select end
        if client then client:stop(true) end
        if previous_buf then vim.api.nvim_set_current_buf(previous_buf) end
        if buf then vim.api.nvim_buf_delete(buf, { force = true }) end
        if root then vim.fn.delete(root, 'rf') end
    end)

    it('creates and indexes a file through code_action and preserves wiki actions', function()
        if vim.fn.executable('markdown-oxide') ~= 1 then
            pending('markdown-oxide is not installed')
            return
        end
        root = vim.fn.tempname()
        vim.fn.mkdir(root, 'p')
        vim.fn.writefile({}, root .. '/.moxide.toml')
        local source = root .. '/source.md'
        vim.fn.writefile({ '[text](new.md)', '[[wikimissing]]' }, source)
        previous_buf = vim.api.nvim_get_current_buf()
        vim.cmd.edit(source)
        buf = vim.api.nvim_get_current_buf()
        vim.bo[buf].filetype = 'markdown'
        local id = vim.lsp.start({
            name = 'markdown_actions_test', cmd = { 'markdown-oxide' }, root_dir = root,
            capabilities = { workspace = { fileOperations = { didCreate = true } } },
            on_attach = actions.attach,
        })
        client = vim.lsp.get_client_by_id(id)
        assert.is_true(vim.wait(5000, function()
            return client.initialized and client.commands['nvim.markdown.createFile'] ~= nil
        end))

        select = vim.ui.select
        local choices
        vim.ui.select = function(items, opts, callback)
            assert.equals('codeaction', opts.kind)
            choices = items
            callback(items[1])
        end
        vim.api.nvim_win_set_cursor(0, { 1, 10 })
        vim.lsp.buf.code_action({ context = { only = { 'quickfix' } } })
        assert.is_true(vim.wait(5000, function() return choices ~= nil end))
        assert.equals('Create File: "new.md"', choices[1].action.title)
        local uri = vim.uri_from_fname(root .. '/new.md')
        assert.equals(1, vim.fn.filereadable(root .. '/new.md'))

        local definition
        local function probe()
            client:request('textDocument/definition', {
                textDocument = { uri = vim.uri_from_fname(source) },
                position = { line = 0, character = 10 },
            }, function(_, result) definition = result end, buf)
        end
        probe()
        assert.is_true(vim.wait(5000, function()
            if definition and #definition > 0 then return true end
            if definition then definition = nil; probe() end
            return false
        end, 50))
        assert.equals(uri, definition[1].uri)

        choices = nil
        vim.ui.select = function(items, _, callback) choices = items; callback(nil) end
        vim.api.nvim_win_set_cursor(0, { 2, 5 })
        vim.lsp.buf.code_action()
        assert.is_true(vim.wait(5000, function() return choices ~= nil end))
        assert.equals(1, #choices)
        assert.equals('Create File: "wikimissing.md"', choices[1].action.title)
        assert.is_table(choices[1].action.edit)
    end)
end)
