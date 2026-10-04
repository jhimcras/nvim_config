local status = require('status')

describe('status', function()
    it('colors only the window in READ mode without a tag', function()
        require('highlight').setup()
        local read_mode = require('read_mode')
        local read_win = vim.api.nvim_get_current_win()
        vim.cmd('vsplit')
        local other_win = vim.api.nvim_get_current_win()

        read_mode.enter(read_win)
        vim.api.nvim_set_current_win(read_win)
        vim.g.statusline_winid = read_win
        local read_line = status.statusline_entry()
        vim.api.nvim_set_current_win(other_win)
        vim.g.statusline_winid = other_win
        local other_line = status.statusline_entry()

        assert.is_nil(read_line:find('READ', 1, true))
        assert.is_truthy(read_line:find('StatuslineGeneralActive_1_read', 1, true))
        assert.is_nil(other_line:find('READ', 1, true))
        assert.is_nil(other_line:find('StatuslineGeneralActive_1_read', 1, true))

        read_mode.exit(read_win)
        vim.g.statusline_winid = nil
        vim.api.nvim_win_close(read_win, true)
    end)

    it('should have a setup function', function()
        assert.is_function(status.setup)
    end)
    
    it('should setup tabline and statusline', function()
        -- Mock vim.o and vim.go
        local original_o = vim.o
        local original_go = vim.go
        local original_testing = vim.g.is_testing
        
        vim.o = {}
        vim.go = {}
        vim.g.is_testing = nil -- Temporarily allow setup to run
        
        -- Mock util functions to avoid errors
        package.loaded['util'] = {
            set_highlight = function() end,
            nnoremap = function() end,
        }
        
        status.setup()

        assert.is_equal(2, vim.o.laststatus)

        vim.o = original_o
        vim.go = original_go
        vim.g.is_testing = original_testing
    end)
end)

describe('statusline shrinking', function()
    local original_searchcount, original_fnamemodify, original_lsp, original_win, win, buf
    local search_calls, lsp_calls

    before_each(function()
        original_win = vim.api.nvim_get_current_win()
        vim.cmd('botright vnew')
        win = vim.api.nvim_get_current_win()
        buf = vim.api.nvim_get_current_buf()
        vim.api.nvim_win_set_width(win, 12)
        vim.g.statusline_winid = win
        vim.v.hlsearch = 1
        original_searchcount = vim.fn.searchcount
        original_fnamemodify = vim.fn.fnamemodify
        original_lsp = status.lsp
        search_calls, lsp_calls = 0, 0
        vim.fn.searchcount = function()
            search_calls = search_calls + 1
            return { current = 1, total = 123456 }
        end
        status.lsp = function()
            lsp_calls = lsp_calls + 1
            return 'indexing: a very long progress report'
        end
    end)

    after_each(function()
        vim.fn.searchcount = original_searchcount
        vim.fn.fnamemodify = original_fnamemodify
        status.lsp = original_lsp
        vim.g.statusline_winid = nil
        vim.v.hlsearch = 0
        vim.api.nvim_set_current_win(original_win)
        vim.api.nvim_win_close(win, true)
        vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it('evaluates general search and LSP once per render while shrinking', function()
        status.statusline_entry()
        assert.equals(1, search_calls)
        assert.equals(1, lsp_calls)
        -- Results must be refreshed on the next render.
        status.statusline_entry()
        assert.equals(2, search_calls)
        assert.equals(2, lsp_calls)
    end)

    it('caches empty component results too', function()
        status.lsp = function()
            lsp_calls = lsp_calls + 1
            return ''
        end
        status.statusline_entry()
        assert.equals(1, lsp_calls)
    end)

    it('keeps launcher compact text and evaluates unwrapped search once', function()
        vim.bo[buf].filetype = 'launcher'
        vim.b[buf].prjroot_folder = '/a/very/long/project'
        vim.b[buf].lc_command = 'a very long launcher command'
        local compact_calls = 0
        vim.fn.fnamemodify = function(name, mods)
            if name == vim.b[buf].prjroot_folder then
                compact_calls = compact_calls + 1
            end
            return original_fnamemodify(name, mods)
        end
        local line = status.statusline_entry()
        assert.is_truthy(line:find('project', 1, true))
        assert.is_nil(line:find('/a/very/long/', 1, true))
        assert.is_nil(line:find('launcher command', 1, true))
        assert.equals(1, search_calls)
        assert.equals(1, compact_calls)
    end)

    it('evaluates active quickfix search once even when it is removed', function()
        vim.bo[buf].buftype = 'quickfix'
        vim.w[win].quickfix_title = 'Search: a very long search query'
        local line = status.statusline_entry()
        assert.equals(1, search_calls)
        assert.is_nil(line:find('123456', 1, true))
    end)

    it('omits search counts in inactive quickfix windows', function()
        vim.bo[buf].buftype = 'quickfix'
        vim.w[win].quickfix_title = 'Search: needle'
        vim.api.nvim_set_current_win(original_win)
        status.statusline_entry()
        assert.equals(0, search_calls)
    end)
end)
