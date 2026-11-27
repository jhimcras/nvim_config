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

describe('file_info copy path', function()
    local original_win, original_setreg, tmpdir

    before_each(function()
        original_win = env.os.win
        original_setreg = vim.fn.setreg
        tmpdir = vim.uv.fs_realpath(vim.fn.tempname():match('^(.*)[/\\]')) .. '/copy_path_spec'
        vim.fn.mkdir(tmpdir, 'p')
        vim.cmd('enew')
    end)

    after_each(function()
        env.os.win = original_win
        vim.fn.setreg = original_setreg
        vim.cmd('silent! %bwipeout!')
        vim.fn.delete(tmpdir, 'rf')
    end)

    local function copied(name)
        if name then vim.api.nvim_buf_set_name(0, name) end
        local reg
        vim.fn.setreg = function(r, v) reg = { r, v } end
        file_info.copy_path()
        return reg
    end

    it('copies the Unix path to the + register elsewhere', function()
        env.os.win = false
        local file = tmpdir .. '/a.txt'
        vim.fn.writefile({}, file)
        assert.are.same({ '+', file }, copied(file))
    end)

    it('copies a Windows path on Windows', function()
        env.os.win = true
        local file = tmpdir .. '/a.txt'
        vim.fn.writefile({}, file)
        assert.are.same({ '+', (file:gsub('/', '\\')) }, copied(file))
    end)

    it('copies the Windows directory for oil buffers on Windows', function()
        env.os.win = true
        assert.are.same({ '+', [[D:\Source\dir\]] }, copied('oil:///D/Source/dir/'))
    end)

    it('copies nothing for unnamed or non-file buffers', function()
        assert.is_nil(copied())
        assert.is_nil(copied('term://~//123:bash'))
    end)

    it('copies the work tree for fugitive buffers', function()
        env.os.win = false
        assert.are.same({ '+', '/repo/dir' }, copied('fugitive:///repo/dir/.git//0/a.txt'))
    end)

    it('copies the Windows work tree for fugitive buffers on Windows', function()
        env.os.win = true
        assert.are.same({ '+', [[D:\repo\dir]] }, copied([[fugitive:\\\D:\repo\dir\.git\\]]))
    end)
end)

describe('file_info copy path keymaps', function()
    local original_setreg

    before_each(function()
        original_setreg = vim.fn.setreg
        vim.cmd('enew')
    end)

    after_each(function()
        vim.fn.setreg = original_setreg
        vim.cmd('silent! %bwipeout!')
    end)

    it('y in the File Information window copies the source path and closes it', function()
        vim.api.nvim_buf_set_name(0, 'oil:///tmp/some/dir/')
        local src_win = vim.api.nvim_get_current_win()
        local reg
        vim.fn.setreg = function(r, v) reg = { r, v } end
        file_info.show()
        local float = vim.api.nvim_get_current_win()
        assert.are_not.equal(src_win, float)
        vim.api.nvim_feedkeys('y', 'x', false)
        assert.is_false(vim.api.nvim_win_is_valid(float))
        assert.are.same({ '+', require('nvim_config.file_info').file_path(vim.api.nvim_win_get_buf(src_win)) }, reg)
    end)

    it('<leader>y is mapped to copy the path', function()
        require('nvim_config.keymap').setup()
        local m = vim.fn.maparg('<leader>y', 'n', false, true)
        assert.is_function(m.callback)
    end)
end)
