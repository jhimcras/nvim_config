local file_info = require('nvim_config.file_info')
local env = require('nvim_config.env')

describe('file_info', function()
    it('should have a setup function', function()
        assert.is_function(file_info.setup)
    end)
end)

describe('file_info oil path', function()
    local original_win

    before_each(function()
        original_win = env.os.win
        vim.cmd('enew')
    end)

    after_each(function()
        env.os.win = original_win
        vim.cmd('silent! %bwipeout!')
    end)

    local function path_line(name)
        vim.api.nvim_buf_set_name(0, name)
        file_info.show()
        local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
        vim.api.nvim_win_close(0, true)
        return lines[1]
    end

    it('shows a Windows path for oil buffers on Windows', function()
        env.os.win = true
        assert.are.equal([[Path       : D:\Source\hi6_main\src\base\dom\]],
            path_line('oil:///D/Source/hi6_main/src/base/dom/'))
    end)

    it('keeps the Unix path for oil buffers elsewhere', function()
        env.os.win = false
        assert.are.equal('Path       : /tmp/some/dir/', path_line('oil:///tmp/some/dir/'))
    end)
end)
