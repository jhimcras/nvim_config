local lsp = require('nvim_config.lsp')

describe('lsp', function()
    it('should have a setup function', function()
        assert.is_function(lsp.setup)
    end)
    
    it('should have basic diagnostic symbols', function()
        assert.is_string(lsp.SymError)
        assert.is_string(lsp.SymWarn)
        assert.are.equal(require('nvim_config.lsp.progress').progress_state, lsp.progress_state)
    end)

    it('loads without patching floats and installs one wrapper during setup', function()
        local original_preview = vim.lsp.util.open_floating_preview
        local original_lsp = package.loaded['nvim_config.lsp']
        local captured_opts, calls = nil, 0
        local preview = function(_, _, opts)
            calls = calls + 1
            captured_opts = opts
            return nil, nil
        end
        vim.lsp.util.open_floating_preview = preview
        package.loaded['nvim_config.lsp'] = nil
        require('nvim_config.lsp')
        assert.are.equal(preview, vim.lsp.util.open_floating_preview)

        local float = require('nvim_config.lsp.float')
        float.setup()
        local wrapper = vim.lsp.util.open_floating_preview
        float.setup()
        assert.are.equal(wrapper, vim.lsp.util.open_floating_preview)
        vim.lsp.util.open_floating_preview({ 'hover' }, 'markdown', {})
        assert.are.equal(1, calls)
        assert.is_table(captured_opts)
        assert.is_nil(captured_opts.border)

        vim.lsp.util.open_floating_preview = original_preview
        package.loaded['nvim_config.lsp'] = original_lsp
    end)

    describe('lua_ls settings', function()
        local original_executable
        local original_exepath
        local original_fs_stat
        local original_lsp_config
        local original_lsp_enable
        local original_lsp_log_set_level
        local original_diagnostic_config
        local original_vimruntime
        local original_luals

        before_each(function()
            original_executable = vim.fn.executable
            original_exepath = vim.fn.exepath
            original_fs_stat = vim.uv.fs_stat
            original_lsp_config = vim.lsp.config
            original_lsp_enable = vim.lsp.enable
            original_lsp_log_set_level = vim.lsp.log.set_level
            original_diagnostic_config = vim.diagnostic.config
            original_vimruntime = vim.env.VIMRUNTIME
            original_luals = vim.env.LUALS

            vim.env.VIMRUNTIME = '/tmp/vimruntime'
            vim.env.LUALS = '/opt/lua-language-server'
            vim.fn.executable = function(cmd)
                return cmd == '/opt/lua-language-server/bin/lua-language-server' and 1 or 0
            end
            vim.fn.exepath = function(cmd)
                if cmd == '/opt/lua-language-server/bin/lua-language-server' then
                    return '/opt/lua-language-server/bin/lua-language-server'
                end
                return ''
            end
            vim.lsp.enable = function() end
            vim.lsp.log.set_level = function() end
            vim.diagnostic.config = function() end
        end)

        after_each(function()
            vim.fn.executable = original_executable
            vim.fn.exepath = original_exepath
            vim.uv.fs_stat = original_fs_stat
            vim.lsp.config = original_lsp_config
            vim.lsp.enable = original_lsp_enable
            vim.lsp.log.set_level = original_lsp_log_set_level
            vim.diagnostic.config = original_diagnostic_config
            vim.env.VIMRUNTIME = original_vimruntime
            vim.env.LUALS = original_luals
        end)

        local function setup_lua_with_luv_stat(luv_exists)
            local lua_config
            vim.lsp.config = setmetatable({}, {
                __call = function(_, name, config)
                    if name == 'lua_ls' then
                        lua_config = config
                    end
                end,
            })
            vim.uv.fs_stat = function(path)
                if path == '/opt/lua-language-server/meta/3rd/luv/library' then
                    return luv_exists and { type = 'directory' } or nil
                end
                return nil
            end

            lsp.setup()

            assert.is_table(lua_config)
            return lua_config
        end

        it('does not crash when LUALS is absent and no server is installed', function()
            vim.env.LUALS = nil
            vim.fn.executable = function() return 0 end
            vim.lsp.config = setmetatable({}, { __call = function()
                error('lua_ls should not be configured without an executable')
            end })
            assert.has_no.errors(function() require('nvim_config.lsp.servers.lua_ls').setup() end)
        end)

        it('uses a server on PATH when LUALS is absent', function()
            vim.env.LUALS = nil
            vim.fn.executable = function(cmd)
                return cmd == 'lua-language-server' and 1 or 0
            end
            local lua_config
            vim.lsp.config = setmetatable({}, { __call = function(_, name, config)
                if name == 'lua_ls' then lua_config = config end
            end })
            require('nvim_config.lsp.servers.lua_ls').setup()
            assert.are.same({ 'lua-language-server' }, lua_config.cmd)
        end)

        it('adds luv metadata when the local LuaLS installation provides it', function()
            local lua_config = setup_lua_with_luv_stat(true)
            assert.are.same({
                '/tmp/vimruntime',
                '${3rd}/luv/library',
            }, lua_config.settings.Lua.workspace.library)
            assert.is_false(lua_config.settings.Lua.workspace.checkThirdParty)

            local client = { config = { settings = vim.deepcopy(lua_config.settings) } }
            lua_config.on_init(client)

            assert.are.same({
                '/tmp/vimruntime',
                '${3rd}/luv/library',
            }, client.config.settings.Lua.workspace.library)
            assert.is_false(client.config.settings.Lua.workspace.checkThirdParty)
        end)

        it('does not add luv metadata when the local LuaLS installation does not provide it', function()
            local lua_config = setup_lua_with_luv_stat(false)
            assert.are.same({
                '/tmp/vimruntime',
            }, lua_config.settings.Lua.workspace.library)
            assert.is_false(lua_config.settings.Lua.workspace.checkThirdParty)
        end)
    end)

    describe('clangd on_attach guard', function()
        local original_executable
        local original_lsp_config
        local original_lsp_enable
        local original_lsp_log_set_level
        local original_diagnostic_config
        local original_luals
        local original_buf_detach_client

        before_each(function()
            original_executable = vim.fn.executable
            original_lsp_config = vim.lsp.config
            original_lsp_enable = vim.lsp.enable
            original_lsp_log_set_level = vim.lsp.log.set_level
            original_diagnostic_config = vim.diagnostic.config
            original_luals = vim.env.LUALS
            original_buf_detach_client = vim.lsp.buf_detach_client

            vim.env.LUALS = '/opt/lua-language-server'
            vim.fn.executable = function(cmd) return cmd == 'clangd' and 1 or 0 end
            vim.lsp.config = setmetatable({}, { __call = function() end })
            vim.lsp.enable = function() end
            vim.lsp.log.set_level = function() end
            vim.diagnostic.config = function() end
        end)

        after_each(function()
            vim.fn.executable = original_executable
            vim.lsp.config = original_lsp_config
            vim.lsp.enable = original_lsp_enable
            vim.lsp.log.set_level = original_lsp_log_set_level
            vim.diagnostic.config = original_diagnostic_config
            vim.env.LUALS = original_luals
            vim.lsp.buf_detach_client = original_buf_detach_client
        end)

        local function on_attach_with_buffer(bufname)
            lsp.setup()
            local clangd_config = vim.lsp.config.clangd
            assert.is_table(clangd_config)

            local bufnr = vim.api.nvim_create_buf(false, true)
            vim.api.nvim_buf_set_name(bufnr, bufname)
            vim.bo[bufnr].buftype = ''
            vim.api.nvim_set_current_buf(bufnr)

            local detached = false
            vim.lsp.buf_detach_client = function() detached = true end

            clangd_config.on_attach({ id = 1, supports_method = function() return true end }, bufnr)

            vim.api.nvim_buf_delete(bufnr, { force = true })
            return detached
        end

        it('detaches from a fugitive blob buffer despite its empty buftype', function()
            assert.is_true(on_attach_with_buffer('fugitive:///repo/.git//0/main.cpp'))
        end)

        it('detaches from a Windows fugitive blob buffer with backslash separators', function()
            assert.is_true(on_attach_with_buffer([[fugitive:\\\D:\Source\proj\.git\\0\main.cpp]]))
        end)

        it('does not detach from a normal file buffer', function()
            assert.is_false(on_attach_with_buffer('/repo/main.cpp'))
        end)
    end)

    describe('clangd command line', function()
        local clangd = require('nvim_config.lsp.servers.clangd')

        local function index_of(cmd, pattern)
            for i, arg in ipairs(cmd) do
                if arg:match(pattern) then return i end
            end
        end

        it('caps the async workers and lowers the background index priority', function()
            local cmd = clangd.cmd()
            local j = index_of(cmd, '^%-j=')
            assert.is_number(j)
            assert.is_true(tonumber(cmd[j]:match('^%-j=(%d+)$')) >= 2)
            assert.is_number(index_of(cmd, '^%-%-background%-index%-priority=background$'))
        end)

        it('appends project arguments after the defaults so they win', function()
            local cmd = clangd.cmd({ '-j=2' })
            assert.are.equal('-j=2', cmd[#cmd])
            assert.is_true(index_of(cmd, '^%-j=') < #cmd)
        end)
    end)
end)
