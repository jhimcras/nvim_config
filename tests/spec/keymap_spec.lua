local keymap = require('nvim_config.keymap')

describe('keymap', function()
    it('should have a setup function', function()
        assert.is_function(keymap.setup)
    end)

    it('should register global mappings and commands without error', function()
        assert.has_no.errors(function() keymap.setup() end)

        -- representative mappings from each source file
        assert.is_not.equal('', vim.fn.maparg('<leader>gg', 'n'))
        assert.is_not.equal('', vim.fn.maparg('<leader>r', 'n'))
        assert.is_not.equal('', vim.fn.maparg('<leader>tv', 'n'))
        assert.is_not.equal('', vim.fn.maparg('<C-g>', 'n'))
        assert.is_not.equal('', vim.fn.maparg('<F12>', 'n'))
        assert.is_not.equal('', vim.fn.maparg('<Leader>ff', 'n'))
        assert.is_not.equal('', vim.fn.maparg('<c-right>', 'n'))
        assert.is_not.equal('', vim.fn.maparg('<c-h>', 'n'))
        assert.is_not.equal('', vim.fn.maparg('-', 'n'))

        assert.is_true(vim.fn.exists(':FileInfo') == 2)
        assert.is_true(vim.fn.exists(':GclogBack') == 2)
        assert.is_true(vim.fn.exists(':PrjRootConfig') == 2)
        assert.is_true(vim.fn.exists(':Config') == 2)
    end)
    it('loads Telescope before invoking a picker and injects selection into instance moves', function()
        local names = { 'nvim_config.plugins', 'nvim_config.plugins.tele.pickers', 'nvim_config.instance.move' }
        local originals = {}
        for _, name in ipairs(names) do originals[name] = package.loaded[name] end
        local calls = {}
        package.loaded['nvim_config.plugins'] = { load_telescope = function() calls[#calls + 1] = 'load' end }
        package.loaded['nvim_config.plugins.tele.pickers'] = {
            Files = function() calls[#calls + 1] = 'Files' end,
            ConfigFiles = function(query) calls[#calls + 1] = query end,
            InstanceTargets = function(cb) calls[#calls + 1] = 'InstanceTargets'; cb({ new = true }) end,
        }
        package.loaded['nvim_config.instance.move'] = { move = function(kind, select_target)
            calls[#calls + 1] = kind
            select_target(function(target) assert.is_true(target.new) end)
        end }
        local ok, err = pcall(function()
            keymap.setup()
            vim.fn.maparg('<Leader>ff', 'n', false, true).callback()
            vim.cmd('Config init')
            vim.cmd('MoveBufferToInstance')
            vim.cmd('MoveTabToInstance')
        end)
        for _, name in ipairs(names) do package.loaded[name] = originals[name] end
        assert.is_true(ok, err)
        assert.are.same({ 'load', 'Files', 'load', 'init', 'buffer', 'load', 'InstanceTargets',
            'tab', 'load', 'InstanceTargets' }, calls)
    end)

end)
