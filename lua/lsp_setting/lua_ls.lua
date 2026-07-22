local lsp_setting = require('lsp_setting')
local env = require 'env'

local M = {}

local on_attach_lua = lsp_setting.make_on_attach(nil)

function M.setup()
    local lua_lsp_cmd
    -- if vim.env.LUALS == nil then return end
    -- local lua_lsp_cmd = { vim.env.LUALS .. (env.os.win and [[\lua-language-server.exe]] or '/bin/lua-language-server') }
    if env.os.win then
        lua_lsp_cmd = "lua-language-server.exe"
    else
        lua_lsp_cmd = vim.env.LUALS .. '/bin/lua-language-server'
    end
    if not vim.fn.executable(lua_lsp_cmd) then return end

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
            if lsp_setting.on_init(client) == false then
                return
            end
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
