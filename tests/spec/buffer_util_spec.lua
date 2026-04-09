local ut = require('util')
local env = require('env')

describe('buffer utils', function()
    local bufnr

    before_each(function()
        bufnr = vim.api.nvim_create_buf(false, true)
    end)

    after_each(function()
        vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    describe('GetBufferProtocol', function()
        it('returns nil for normal file paths', function()
            vim.api.nvim_buf_set_name(bufnr, '/home/user/test.txt')
            assert.is_nil(ut.GetBufferProtocol(bufnr))
        end)

        it('returns "oil" for oil buffers', function()
            vim.api.nvim_buf_set_name(bufnr, 'oil:///home/user')
            assert.equals('oil', ut.GetBufferProtocol(bufnr))
        end)

        it('returns "fugitive" for fugitive buffers', function()
            vim.api.nvim_buf_set_name(bufnr, 'fugitive:///repo/.git//commit/file')
            assert.equals('fugitive', ut.GetBufferProtocol(bufnr))
        end)
    end)

    describe('GetBufferName', function()
        it('returns absolute path for normal files', function()
            local path = vim.fn.getcwd() .. '/test_file.txt'
            vim.api.nvim_buf_set_name(bufnr, path)
            assert.equals(path, ut.GetBufferName(bufnr))
        end)

        it('strips fugitive:// protocol and returns it as second value', function()
            local raw = 'fugitive:///repo/.git//commit/file'
            vim.api.nvim_buf_set_name(bufnr, raw)
            local path, protocol = ut.GetBufferName(bufnr)
            assert.equals('/repo/.git//commit/file', path)
            assert.equals('fugitive', protocol)
        end)

        it('returns raw path for oil:/// on Unix', function()
            vim.api.nvim_buf_set_name(bufnr, 'oil:///home/user/dir')
            local path, protocol = ut.GetBufferName(bufnr)
            assert.equals('/home/user/dir', path)
            assert.equals('oil', protocol)
        end)

        it('returns raw path for oil:/// on Windows (with leading slash)', function()
            vim.api.nvim_buf_set_name(bufnr, 'oil:///C:/Users/test')
            local path, protocol = ut.GetBufferName(bufnr)
            assert.equals('/C:/Users/test', path)
            assert.equals('oil', protocol)
        end)
    end)

    describe('GetBufferDir', function()
        it('returns directory for normal files if they exist', function()
            local dir = vim.fn.getcwd()
            local path = dir .. '/lua/util.lua' -- Known to exist
            vim.api.nvim_buf_set_name(bufnr, path)
            assert.equals(ut.normalize_path_separator(dir .. '/lua'), ut.GetBufferDir(bufnr))
        end)
        
        it('returns empty string for non-existent virtual paths (due to fs_stat)', function()
            vim.api.nvim_buf_set_name(bufnr, 'fugitive:///non/existent/path/to/file')
            assert.equals('', ut.GetBufferDir(bufnr))
        end)
    end)
end)
