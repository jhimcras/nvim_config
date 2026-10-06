describe('rendermark.image_complete', function()
    local source = require('nvim_config.rendermark.image_complete')
    local dir, buf, original_cmp

    before_each(function()
        original_cmp = package.loaded['cmp']
        package.loaded['cmp'] = { lsp = { CompletionItemKind = { File = 17 } } }
        dir = vim.fn.tempname()
        vim.fn.mkdir(dir .. '/img/deep', 'p')
        vim.fn.mkdir(dir .. '/.hidden', 'p')
        for _, f in ipairs({ 'dog.JPG', 'img/cat.png', 'img/my pic.webp', 'img/deep/x.gif', 'note.md', '.hidden/h.png' }) do
            vim.fn.writefile({}, dir .. '/' .. f)
        end
        buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_name(buf, dir .. '/a.md')
    end)

    after_each(function()
        vim.api.nvim_buf_delete(buf, { force = true })
        vim.fn.delete(dir, 'rf')
        package.loaded['cmp'] = original_cmp
    end)

    local function complete(before)
        local result
        source.new():complete({
            context = {
                bufnr = buf,
                cursor_before_line = before,
                cursor = { row = 3, character = vim.str_utfindex(before, 'utf-16') },
            },
        }, function(r) result = r end)
        return result.items
    end

    it('lists image files recursively, skipping hidden entries and non-images', function()
        assert.are.same({ 'dog.JPG', 'img/cat.png', 'img/deep/x.gif', 'img/my pic.webp' }, source.list_images(dir))
    end)

    it('completes "![" into a full image link replacing from "!"', function()
        local items = complete('text ![ca')
        assert.are.equal(4, #items)
        local cat = items[2]
        assert.are.equal('img/cat.png', cat.label)
        assert.are.equal('![img/cat.png', cat.filterText)
        assert.are.same({
            range = { start = { line = 2, character = 5 }, ['end'] = { line = 2, character = 9 } },
            newText = '![cat](img/cat.png)',
        }, cat.textEdit)
        assert.are.equal('![my pic](img/my%20pic.webp)', items[4].textEdit.newText)
    end)

    it('measures the range in utf-16 units', function()
        local items = complete('한글 ![')
        assert.are.same({ start = { line = 2, character = 3 }, ['end'] = { line = 2, character = 5 } }, items[1].textEdit.range)
    end)

    it('offers nothing outside "![..."', function()
        assert.are.same({}, complete('[ca'))
        assert.are.same({}, complete('![name]('))
        assert.are.same({}, complete('![name](im'))
    end)
end)
