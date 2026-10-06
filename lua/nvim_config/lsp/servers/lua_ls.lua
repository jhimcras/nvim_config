local attach = require('nvim_config.lsp.attach')
local env = require 'nvim_config.env'

local M = {}

local on_attach_lua = attach.make_on_attach(nil)

function M.setup()
    local lua_lsp_cmd
    if env.os.win then
        lua_lsp_cmd = 'lua-language-server.exe'
    elseif vim.env.LUALS and vim.env.LUALS ~= '' then
        lua_lsp_cmd = vim.env.LUALS .. '/bin/lua-language-server'
    end
    if not lua_lsp_cmd or vim.fn.executable(lua_lsp_cmd) ~= 1 then
        lua_lsp_cmd = env.os.win and 'lua-language-server.exe' or 'lua-language-server'
        if vim.fn.executable(lua_lsp_cmd) ~= 1 then return end
    end

    local function lua_workspace_library()
        local library = { vim.env.VIMRUNTIME }
        local candidates = {}

        if vim.env.LUALS then
            table.insert(candidates, vim.env.LUALS .. '/meta/3rd/luv/library')
        end

        local exe = vim.fn.exepath(lua_lsp_cmd)
        if exe ~= '' then
            local exe_dir = vim.fn.fnamemodify(exe, ':h')
            table.insert(candidates, exe_dir .. '/../meta/3rd/luv/library')
            table.insert(candidates, exe_dir .. '/meta/3rd/luv/library')
        end

        for _, path in ipairs(candidates) do
            if vim.uv.fs_stat(path) then
                table.insert(library, '${3rd}/luv/library')
                break
            end
        end

        return library
    end

    vim.lsp.config('lua_ls', {
        cmd = { lua_lsp_cmd },
        filetypes = { 'lua' },
        on_attach = on_attach_lua,
        on_init = function(client)
            if client.workspace_folders then
                local path = client.workspace_folders[1].name
                if path ~= vim.fn.stdpath('config') and (vim.uv.fs_stat(path .. '/.luarc.json') or vim.uv.fs_stat(path .. '/.luarc.jsonc')) then
                    return
                end
            end

            client.config.settings.Lua = vim.tbl_deep_extend('force', client.config.settings.Lua, {
                runtime = {
                    version = 'LuaJIT',
                    path = {
                        'lua/?.lua',
                        'lua/?/init.lua',
                    },
                },
                workspace = {
                    checkThirdParty = false,
                    library = lua_workspace_library(),
                }
            })
        end,
        settings = {
            Lua = {
                workspace = {
                    checkThirdParty = false,
                    library = lua_workspace_library(),
                },
            }
        }
    })
    vim.lsp.enable('lua_ls')
end

return M
