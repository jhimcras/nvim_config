local lsp_setting = require('lsp_setting')

describe('lsp_setting', function()
    it('should have a setup function', function()
        assert.is_function(lsp_setting.setup)
    end)
    
    it('should have basic diagnostic symbols', function()
        assert.is_string(lsp_setting.SymError)
        assert.is_string(lsp_setting.SymWarn)
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

            lsp_setting.setup()

            assert.is_table(lua_config)
            return lua_config
        end

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
end)
