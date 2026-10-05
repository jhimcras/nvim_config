local wrap = require('rendermark.wrap')
local image = require('rendermark.image')

describe('images inside rendered tables', function()
    local path, old_img, old_screenpos
    local payload

    local function refresh(lines, width)
        wrap.setup({ left_pad = 0, right_pad = 0, max_width = width or 70 })
        vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
        vim.bo.filetype = 'markdown'
        wrap.apply(0)
        vim.api.nvim_win_set_cursor(0, { 1, 0 })
        wrap.refresh(0)
    end

    local function grid(row)
        local marks = vim.api.nvim_buf_get_extmarks(0,
            vim.api.nvim_create_namespace('markdown_visual_wrap'), { row, 0 }, { row, -1 },
            { details = true })
        local out, first = {}, nil
        for _, mark in ipairs(marks) do
            local d = mark[4]
            if d.virt_text then first = image.virt_text_to_plain(d.virt_text) end
            for _, line in ipairs(d.virt_lines or {}) do
                out[#out + 1] = image.virt_text_to_plain(line)
            end
        end
        if first then table.insert(out, 1, first) end
        return out
    end

    before_each(function()
        vim.cmd('enew!')
        old_img, old_screenpos = vim.ui.img, image.safe_screenpos
        payload = {}
        vim.ui.img = {
            set = function(id, p, opts) payload[id] = { path = p, opts = opts } end,
            del = function(id) payload[id] = nil end,
        }
        image.safe_screenpos = function(_, lnum) return { row = lnum, col = 1 } end
        path = vim.fn.tempname() .. '.png'
        local file = assert(io.open(path, 'wb'))
        -- A 400x180 header is enough for the geometry reader.
        file:write(string.char(137,80,78,71,13,10,26,10,0,0,0,13,73,72,68,82,
            0,0,1,144,0,0,0,180))
        file:close()
        vim.g.neopp_images_enabled = true
        vim.g.neopp_cell_width_px = 10
        vim.g.neopp_cell_height_px = 18
    end)

    after_each(function()
        wrap.disable(0)
        image.safe_screenpos = old_screenpos
        vim.ui.img = old_img
        vim.g.neopp_images_enabled = nil
        vim.g.neopp_cell_width_px = nil
        vim.g.neopp_cell_height_px = nil
        vim.fn.delete(path)
        vim.cmd('bwipeout!')
    end)

    it('sizes the grid from images in both columns and sends each only once', function()
        refresh({ 'prose', '| a | b |', '|--|--|',
            '|![](' .. path .. ')|text<br>more|',
            '|text|![](' .. path .. ')|' })
        local first, second = wrap.table_row(vim.api.nvim_get_current_buf(), 3)[1],
            wrap.table_row(vim.api.nvim_get_current_buf(), 4)[1]
        assert.is_truthy(first)
        assert.is_truthy(second)
        assert.is_true(second.table_layout.col > first.table_layout.col)
        assert.is_true(first.table_layout.width > 0)
        local rows = grid(3)
        assert.are.equal(math.ceil(first.table_layout.height / 18) + 1, #rows)
        for _, row in ipairs(rows) do
            assert.are.equal(vim.fn.strdisplaywidth(rows[1]), vim.fn.strdisplaywidth(row))
            assert.is_nil(row:find(path, 1, true))
        end
        local images = image.collect_markdown_images(vim.api.nvim_get_current_buf(), 0, 5)
        assert.are.equal(2, #images)
        image.send_images()
        local count = 0
        for _, entry in pairs(payload) do
            count = count + 1
            assert.are.equal(path, entry.path)
            assert.is_false(entry.opts.virtual)
            assert.are.equal(-1, entry.opts.text_col)
            assert.are.equal(0, #vim.api.nvim_buf_get_extmarks(0,
                image.ensure_image_namespace(), 0, -1, {}))
        end
        assert.are.equal(2, count)
    end)

    it('shrinks to the cell, honors alignment, and positions text and multiple images', function()
        refresh({ 'prose', '| a | b |', '|:--:|--:|',
            '|한글 ![](' .. path .. ') after<br>![](' .. path .. ')|![](' .. path .. ')|' }, 35)
        local images = wrap.table_row(vim.api.nvim_get_current_buf(), 3)
        assert.are.equal(3, #images)
        for _, img in ipairs(images) do
            assert.is_true(img.table_layout.width < 400)
            assert.is_true(math.abs(img.table_layout.width / img.table_layout.height - 400 / 180) < 0.1)
            assert.is_true(img.table_layout.col * 10 + img.table_layout.width < 350)
        end
        assert.is_true(images[2].table_layout.row > images[1].table_layout.row)
        for _, row in ipairs(grid(3)) do assert.is_true(vim.fn.strdisplaywidth(row) <= 35) end
    end)

    it('keeps the grid and image on a normal-mode cursor row and covers the raw text', function()
        local long = string.rep('word ', 30)
        refresh({ 'prose', '|a|b|', '|--|--|', '|![](' .. path .. ')|' .. long .. '|' })
        vim.api.nvim_win_set_cursor(0, { 4, 0 })
        wrap.refresh(0)
        assert.are.equal(1, #wrap.table_row(vim.api.nvim_get_current_buf(), 3))
        assert.are.equal(1, #image.collect_markdown_images(vim.api.nvim_get_current_buf(), 0, 4))
        local raw = vim.api.nvim_buf_get_lines(0, 3, 4, false)[1]
        assert.is_true(vim.fn.strdisplaywidth(grid(3)[1]) >= vim.fn.strdisplaywidth(raw))
    end)

    it('reveals the insert-mode cursor row and drops table geometry when disabled', function()
        refresh({ 'prose', '|a|b|', '|--|--|', '|![](' .. path .. ')|text|' })
        vim.api.nvim_win_set_cursor(0, { 4, 0 })
        local get_mode = vim.api.nvim_get_mode
        vim.api.nvim_get_mode = function() return { mode = 'i', blocking = false } end
        local ok, err = pcall(wrap.refresh, 0)
        vim.api.nvim_get_mode = get_mode
        assert(ok, err)
        assert.are.same({}, wrap.table_row(vim.api.nvim_get_current_buf(), 3))
        assert.are.equal(0, #image.collect_markdown_images(vim.api.nvim_get_current_buf(), 0, 4))
        wrap.disable(0)
        assert.is_nil(wrap.table_row(vim.api.nvim_get_current_buf(), 3))
        assert.are.equal(1, #image.collect_markdown_images(vim.api.nvim_get_current_buf(), 0, 4))
    end)

    it('sends the table image on every scroll step while its row is in view', function()
        local lines = { 'prose', '|a|b|', '|--|--|', '|![](' .. path .. ')|text|', '' }
        for i = 1, 60 do lines[#lines + 1] = 'line ' .. i end
        refresh(lines)
        local buf = vim.api.nvim_get_current_buf()
        for top = 1, 5 do
            -- C-e drags the cursor along with topline.
            vim.fn.winrestview({ topline = top, lnum = top, col = 0 })
            wrap.refresh(0)
            assert.are.equal(1, #(wrap.table_row(buf, 3) or {}), 'topline ' .. top)
            -- Unchanged images are not resent, so count the live set.
            image.send_images()
            assert.are.equal(1, vim.tbl_count(payload), 'topline ' .. top)
        end
    end)

    it('ignores image links of table rows the wrap has not drawn', function()
        local lines = { 'prose', '|a|b|', '|--|--|', '|![](' .. path .. ')|text|', '' }
        for i = 1, 60 do lines[#lines + 1] = 'line ' .. i end
        refresh(lines)
        vim.fn.winrestview({ topline = 20, lnum = 20, col = 0 })
        wrap.refresh(0)
        local buf = vim.api.nvim_get_current_buf()
        assert.is_nil(wrap.table_row(buf, 3))
        assert.are.equal(0, #image.collect_markdown_images(buf, 0, 20))
        image.send_images()
        assert.are.equal(0, #vim.api.nvim_buf_get_extmarks(0, image.ensure_image_namespace(), 0, -1, {}))
    end)

    it('recomputes image space when GUI cell metrics change and removes edited images', function()
        refresh({ 'prose', '|a|b|', '|--|--|', '|![](' .. path .. ')|text|' })
        local height = #grid(3)
        vim.g.neopp_cell_width_px = 20
        vim.g.neopp_cell_height_px = 36
        vim.api.nvim_exec_autocmds('User', { pattern = 'NeoppMetrics' })
        vim.wait(100, function() return #grid(3) < height end)
        assert.is_true(#grid(3) < height)
        vim.api.nvim_buf_set_lines(0, 3, 4, false, { '|plain|text|' })
        wrap.refresh(0)
        assert.are.same({}, wrap.table_row(vim.api.nvim_get_current_buf(), 3))
        assert.are.equal(0, #image.collect_markdown_images(vim.api.nvim_get_current_buf(), 0, 4))
    end)
end)
