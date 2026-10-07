local wrap = require('nvim_config.rendermark.wrap')
local html = require('nvim_config.rendermark.html')
local read_mode = require('nvim_config.read_mode')
local table_state = require('nvim_config.rendermark.table_state')

describe('rendermark event contracts', function()
    local win, buf, group, original_refresh

    before_each(function()
        vim.cmd('enew!')
        win = vim.api.nvim_get_current_win()
        buf = vim.api.nvim_get_current_buf()
        vim.bo.filetype = 'markdown'
        -- Disable automatic window refreshes so event delivery can be counted.
        wrap.setup({ markdown = false })
        read_mode.setup()
        group = vim.api.nvim_create_augroup('test_rendermark_events', { clear = true })
        original_refresh = wrap.refresh
    end)

    after_each(function()
        read_mode.exit(win)
        wrap.refresh = original_refresh
        vim.api.nvim_del_augroup_by_id(group)
        vim.api.nvim_del_augroup_by_name('markdown_visual_wrap')
        vim.api.nvim_del_augroup_by_name('read_mode')
        vim.bo[buf].modifiable = true
    end)

    it('emits ReadModeChanged synchronously after enter and exit state is applied', function()
        local events, refreshes = {}, {}
        wrap.refresh = function(target) refreshes[#refreshes + 1] = target end
        vim.api.nvim_create_autocmd('User', {
            group = group, pattern = 'ReadModeChanged',
            callback = function(event)
                events[#events + 1] = event.data
                assert.equals(event.data.active, read_mode.is_active(win))
                assert.equals(not event.data.active, vim.bo[buf].modifiable)
                assert.equals(event.data.active and 'nvic' or '', vim.wo[win].concealcursor)
            end,
        })
        vim.wo[win].concealcursor = ''

        read_mode.enter(win)
        assert.same({ { win = win, buf = buf, active = true } }, events)
        read_mode.enter(win) -- Already active: no duplicate notification.
        read_mode.exit(win)
        read_mode.exit(win)
        assert.same({
            { win = win, buf = buf, active = true },
            { win = win, buf = buf, active = false },
        }, events)
        assert.same({ win, win }, refreshes)
    end)

    it('routes both events to the specified window and rejects stale targets', function()
        local targets = {}
        wrap.refresh = function(target) targets[#targets + 1] = target end
        local other = vim.api.nvim_open_win(buf, false, {
            relative = 'editor', row = 0, col = 0, width = 20, height = 5,
        })
        for _, pattern in ipairs({ 'ReadModeChanged', 'MarkdownDetailsChanged' }) do
            vim.api.nvim_exec_autocmds('User', {
                pattern = pattern, data = { win = other, buf = buf, active = true },
            })
            vim.api.nvim_exec_autocmds('User', {
                pattern = pattern, data = { win = other, buf = buf + 1000 },
            })
        end
        vim.api.nvim_win_close(other, true)
        for _, pattern in ipairs({ 'ReadModeChanged', 'MarkdownDetailsChanged' }) do
            vim.api.nvim_exec_autocmds('User', {
                pattern = pattern, data = { win = other, buf = buf },
            })
        end
        assert.same({ other, other }, targets)
        assert.equals(win, vim.api.nvim_get_current_win())
    end)

    it('notifies details changes after repainting and refreshes wrap exactly once per toggle', function()
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
            '<details>', '<summary>Notes</summary>', 'body', '</details>', 'after',
        })
        vim.api.nvim_win_set_cursor(win, { 1, 0 })
        local events, refreshes = {}, {}
        local ns = vim.api.nvim_create_namespace('rendermark_html')
        local function hidden()
            for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, { 2, 0 }, { 2, -1 },
                { details = true })) do
                if mark[4].conceal_lines == '' then return true end
            end
            return false
        end
        wrap.refresh = function(target)
            refreshes[#refreshes + 1] = { target, hidden() }
        end
        vim.api.nvim_create_autocmd('User', {
            group = group, pattern = 'MarkdownDetailsChanged',
            callback = function(event) events[#events + 1] = event.data end,
        })

        assert.is_true(html.toggle())
        assert.same({ { win, false } }, refreshes)
        assert.is_true(html.toggle())
        assert.same({ { win, false }, { win, true } }, refreshes)
        assert.same({ { win = win, buf = buf }, { win = win, buf = buf } }, events)
        vim.api.nvim_win_set_cursor(win, { 5, 0 })
        assert.is_false(html.toggle())
        vim.wait(20, function() return false end)
        assert.equals(2, #refreshes)
        assert.equals(2, #events)
    end)

    it('shares table placement state through the facade and clears it on disable and wipeout', function()
        assert.equals(table_state.table_row, wrap.table_row)
        assert.equals(table_state.table_source_rows, wrap.table_source_rows)
        local placements = { { table_layout = { row = 2, col = 3, width = 4, height = 5 } } }
        table_state.rows[buf] = { [0] = placements }
        assert.equals(placements, wrap.table_row(buf, 0))
        wrap.disable(win)
        assert.is_nil(table_state.rows[buf])
        table_state.rows[buf] = { [0] = placements }
        vim.api.nvim_exec_autocmds('BufWipeout', { buffer = buf })
        assert.is_nil(table_state.rows[buf])
        assert.is_nil(wrap.table_row(buf, 0))
    end)
end)
