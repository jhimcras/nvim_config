local pickers = require('nvim_config.plugins.tele.pickers')

describe('tele pickers', function()
    local originals, spec, selected, replacement, closed, mappings
    local modules = { 'telescope.pickers', 'telescope.finders', 'telescope.config',
        'telescope.actions', 'telescope.actions.state', 'telescope.make_entry',
        'nvim_config.instance.move' }

    before_each(function()
        originals = {}
        for _, name in ipairs(modules) do originals[name] = package.loaded[name] end
        spec, selected, replacement, closed, mappings = nil, nil, nil, false, {}
        package.loaded['telescope.pickers'] = { new = function(_, opts)
            spec = opts
            return { find = function()
                opts.attach_mappings(42, function(_, key, callback) mappings[key] = callback end)
            end }
        end }
        package.loaded['telescope.finders'] = { new_table = function(opts) return opts end }
        package.loaded['telescope.config'] = { values = {
            generic_sorter = function() end, grep_previewer = function() end,
        } }
        package.loaded['telescope.actions'] = {
            close = function(buf) assert.are.equal(42, buf); closed = true end,
            select_default = { replace = function(_, callback) replacement = callback end },
        }
        package.loaded['telescope.actions.state'] = { get_selected_entry = function() return selected end }
        package.loaded['telescope.make_entry'] = { gen_from_buffer = function() return function(b) return b end end }
    end)

    after_each(function()
        for _, name in ipairs(modules) do package.loaded[name] = originals[name] end
    end)

    it('closes the instance picker before scheduling the injected selection callback', function()
        local target = { display = 'New Instance', new = true }
        package.loaded['nvim_config.instance.move'] = { targets = function() return { target } end }
        selected = { value = target }
        local called = false
        pickers.InstanceTargets(function(value)
            assert.is_true(closed)
            assert.are.equal(target, value)
            called = true
        end)
        assert.are.equal(target, spec.finder.results[1])
        replacement()
        assert.is_true(closed)
        assert.is_false(called)
        assert.is_true(vim.wait(1000, function() return called end))
    end)

    it('passes picker cancellation through after closing', function()
        package.loaded['nvim_config.instance.move'] = { targets = function() return {} end }
        local called = false
        pickers.InstanceTargets(function(value) assert.is_nil(value); called = true end)
        replacement()
        assert.is_true(vim.wait(1000, function() return called end))
    end)

    it('swipes every selected buffer and refreshes the remaining entries', function()
        local first = vim.api.nvim_create_buf(true, false)
        local second = vim.api.nvim_create_buf(true, false)
        local refreshed
        local current_picker = {
            get_multi_selection = function() return { { bufnr = first }, { bufnr = second } } end,
            refresh = function(_, finder) refreshed = finder.results end,
        }
        package.loaded['telescope.actions.state'].get_current_picker = function() return current_picker end
        pickers.Buffers()
        mappings['<C-s>']()
        assert.is_false(vim.api.nvim_buf_is_valid(first))
        assert.is_false(vim.api.nvim_buf_is_valid(second))
        assert.is_table(refreshed)
        for _, entry in ipairs(refreshed) do
            assert.is_not.equal(first, entry.bufnr)
            assert.is_not.equal(second, entry.bufnr)
        end
    end)
end)
