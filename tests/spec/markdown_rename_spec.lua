local actions = require('nvim_config.lsp_setting.markdown_actions')

describe('Markdown linked file rename', function()
    local root, client, previous_buf, buffers, select, input

    before_each(function()
        if vim.fn.executable('markdown-oxide') ~= 1 then return end
        root = vim.fn.tempname()
        vim.fn.mkdir(root, 'p')
        vim.fn.writefile({}, root .. '/.moxide.toml')
        vim.fn.writefile({ '한글 [[target|별칭]]', '[label](target.md#Target "title")',
            '[[missing]]', 'plain text' }, root .. '/source.md')
        vim.fn.writefile({ '# Target' }, root .. '/target.md')
        vim.fn.writefile({ '[[target#Target|alias]]', '[other](./target.md)' }, root .. '/other.md')
        previous_buf = vim.api.nvim_get_current_buf()
        vim.cmd.edit(root .. '/source.md')
        vim.bo.filetype = 'markdown'
        buffers = { vim.api.nvim_get_current_buf() }
        local id = vim.lsp.start({ name = 'markdown_rename_test', cmd = { 'markdown-oxide' },
            root_dir = root, on_attach = actions.attach })
        client = vim.lsp.get_client_by_id(id)
        assert.is_true(vim.wait(5000, function()
            return client.initialized and client.commands['nvim.markdown.createFile'] ~= nil
        end))
    end)

    after_each(function()
        if select then vim.ui.select = select end
        if input then vim.ui.input = input end
        if client then client:stop(true) end
        if previous_buf then vim.api.nvim_set_current_buf(previous_buf) end
        if root then
            for _, buf in ipairs(vim.api.nvim_list_bufs()) do
                if vim.api.nvim_buf_get_name(buf):sub(1, #root) == root then
                    vim.api.nvim_buf_delete(buf, { force = true })
                end
            end
            vim.fn.delete(root, 'rf')
        end
    end)

    local function rename(line, character)
        local done, result, err
        client:request('textDocument/rename', {
            textDocument = { uri = vim.uri_from_fname(root .. '/source.md') },
            position = { line = line, character = character }, newName = 'renamed',
        }, function(e, r) err, result, done = e, r, true end, buffers[1])
        assert.is_true(vim.wait(5000, function() return done end))
        return result, err
    end

    for _, position in ipairs({ { 0, 7 }, { 1, 12 } }) do
        it('renames the link target and preserves references at line ' .. position[1], function()
            if not client then pending('markdown-oxide is not installed'); return end
            local result, err = rename(position[1], position[2])
            assert.is_nil(err)
            local operation = result.documentChanges[#result.documentChanges]
            assert.equals('rename', operation.kind)
            assert.equals(vim.uri_from_fname(root .. '/target.md'), operation.oldUri)
            vim.lsp.util.apply_workspace_edit(result, client.offset_encoding)
            assert.equals(1, vim.fn.filereadable(root .. '/source.md'))
            assert.equals(0, vim.fn.filereadable(root .. '/target.md'))
            assert.equals(1, vim.fn.filereadable(root .. '/renamed.md'))
            assert.same({ '# Target' }, vim.fn.readfile(root .. '/renamed.md'))
            assert.same({ '한글 [[renamed|별칭]]', '[label](renamed.md#Target "title")',
                '[[missing]]', 'plain text' }, vim.api.nvim_buf_get_lines(buffers[1], 0, -1, false))
            local other = vim.fn.bufnr(root .. '/other.md')
            assert.same({ '[[renamed#Target|alias]]', '[other](./renamed.md)' },
                vim.api.nvim_buf_get_lines(other, 0, -1, false))
        end)
    end

    it('renames through the native code action menu', function()
        if not client then pending('markdown-oxide is not installed'); return end
        select, input = vim.ui.select, vim.ui.input
        local selected
        vim.ui.select = function(items, _, callback)
            for _, item in ipairs(items) do
                if item.action.title == 'Rename Linked File' then
                    selected = true
                    callback(item)
                    return
                end
            end
            callback(nil)
        end
        vim.ui.input = function(_, callback) callback('renamed') end
        vim.api.nvim_win_set_cursor(0, { 1, 9 })
        vim.lsp.buf.code_action()
        assert.is_true(vim.wait(5000, function()
            return vim.fn.filereadable(root .. '/renamed.md') == 1
        end))
        assert.is_true(selected)
        assert.equals(1, vim.fn.filereadable(root .. '/source.md'))
    end)

    it('rejects unresolved links without renaming the source', function()
        if not client then pending('markdown-oxide is not installed'); return end
        local result, err = rename(2, 4)
        assert.is_nil(result)
        assert.equals(-32602, err.code)
        assert.equals(1, vim.fn.filereadable(root .. '/source.md'))
    end)

    it('preserves rename of the current file away from links', function()
        if not client then pending('markdown-oxide is not installed'); return end
        local result, err = rename(3, 4)
        assert.is_nil(err)
        local operation = result.documentChanges[#result.documentChanges]
        assert.equals(vim.uri_from_fname(root .. '/source.md'), operation.oldUri)
    end)
end)
