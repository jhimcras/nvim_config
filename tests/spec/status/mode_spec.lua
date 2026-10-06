local mode = require('nvim_config.status.mode')

describe('status/mode.lua buffer and editor mode dispatch', function()
    local original_mode

    before_each(function() original_mode = vim.fn.mode end)
    after_each(function() vim.fn.mode = original_mode end)

    it('maps normal, insert, replace, visual, command and terminal modes', function()
        for input, expected in pairs({ n = 'Normal', no = 'Normal', i = 'Insert',
            R = 'Replace', v = 'Visual', V = 'Visual', c = 'Command', t = 'Terminal' }) do
            vim.fn.mode = function() return input end
            assert.are.equal(expected, mode.current(''), input)
        end
    end)

    it('lets quickfix override the editor mode and falls back for unknown modes', function()
        vim.fn.mode = function() return 'i' end
        assert.are.equal('Quickfix', mode.current('quickfix'))
        vim.fn.mode = function() return '?' end
        assert.are.equal('', mode.current(''))
        assert.are.same(mode.color('None'), mode.color('unknown'))
        assert.are.same(mode.color('Insert'), mode.color('Terminal'))
    end)
end)
