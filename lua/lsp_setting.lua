-- local lsp = require 'lspconfig'
local env = require 'env'
local ut = require 'util'
local api = vim.api

local M = {}

function M.has_lsp_attached(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    local clients = vim.lsp.get_clients{ bufnr = bufnr }
    return next(clients) ~= nil
end

-- https://clangd.llvm.org/extensions.html#switch-between-sourceheader
local function switch_source_header(bufnr)
    local method_name = 'textDocument/switchSourceHeader'
    -- bufnr = util.validate_bufnr(bufnr)
    local client = vim.lsp.get_clients({ bufnr = bufnr, name = 'clangd' })[1]
    if not client then
        return vim.notify(('method %s is not supported by any servers active on the current buffer'):format(method_name))
    end
    local params = vim.lsp.util.make_text_document_params(bufnr)
    client:request(method_name, params, function(err, result)
        if err then
            error(tostring(err))
        end
        if not result then
            vim.notify('corresponding file cannot be determined')
            return
        end
        vim.cmd.edit(vim.uri_to_fname(result))
    end, bufnr)
end

-- LSP settings (for overriding per client)
-- local handlers =  {
--   ["textDocument/hover"] =  vim.lsp.with(vim.lsp.handlers.hover, {border = border}),
--   ["textDocument/signatureHelp"] =  vim.lsp.with(vim.lsp.handlers.signature_help, {border = border }),
-- }

local orig_util_open_floating_preview = vim.lsp.util.open_floating_preview
function vim.lsp.util.open_floating_preview(contents, syntax, opts, ...)
    opts = opts or {}
    opts.border = opts.border or 'rounded'
    return orig_util_open_floating_preview(contents, syntax, opts, ...)
end

local function capabilities()
    return require('cmp_nvim_lsp').default_capabilities(vim.lsp.protocol.make_client_capabilities())
end

local function general_mappings()
    ut.nnoremap('gW', vim.lsp.buf.workspace_symbol, {'buffer'})

    -- Diagnostic keymaps
    ut.nnoremap('[d', function() vim.diagnostic.jump{count=-1, float=true} end, {'buffer'})
    ut.nnoremap(']d', function() vim.diagnostic.jump{count=1, float=true} end, {'buffer'})
    ut.nnoremap('<leader>do', vim.diagnostic.setloclist, {'buffer'})
end

local function reference_highlighting()
    api.nvim_create_autocmd('CursorHold', { buffer = 0, callback = function() vim.lsp.buf.document_highlight() end })
    api.nvim_create_autocmd('CursorHoldI', { buffer = 0, callback = function() vim.lsp.buf.document_highlight() end })
    api.nvim_create_autocmd('CursorMoved', { buffer = 0, callback = function() vim.lsp.buf.clear_references() end })
end

local function make_on_attach(extras)
    return function(client, bufnr)
        general_mappings()
        reference_highlighting()
        if extras then extras(client, bufnr) end
    end
end

local on_attach = make_on_attach(nil)

local function on_init(client, initialize_result)
    local bufnr = vim.api.nvim_get_current_buf()
    local name = vim.api.nvim_buf_get_name(bufnr) or ""
    if name:match("^fugitive:") then
        client.stop()
        return false
    end
    return true
end


local function on_attach_clangd(client, bufnr)
    if vim.bo[bufnr].buftype ~= '' then
        vim.lsp.buf_detach_client(bufnr, client.id)
        return
    end
    general_mappings()
    vim.api.nvim_buf_create_user_command(0, 'ClangdSwitchSourceHeader', function() switch_source_header(0) end, { desc = 'Switch between source/header' })
    ut.nnoremap('<m-o>', '<cmd>ClangdSwitchSourceHeader<cr>', { 'buffer' })
    ut.nnoremap('<m-O>', '<cmd>vertical split<cr><cmd>ClangdSwitchSourceHeader<cr>', { 'buffer' })
    reference_highlighting()
    vim.bo.formatexpr = 'v:lua.vim.lsp.formatexpr()'
end

local on_attach_lua = make_on_attach(nil)


local function SetupClangd()
    if vim.fn.executable('clangd') then
        vim.lsp.config.clangd = {
            on_init = on_init,
            on_attach = on_attach_clangd,
            cmd = {
                'clangd',
                '--log=error',
                -- '--background-index',
                -- '--cross-file-rename',
                -- '--clang-tidy',
            },
            root_markers = {
                'compile_commands.json',
                '.git'
                -- './build/compile_commands.json',
                -- 'compile_flags.txt',
            },
            filetypes = { 'c', 'cpp' },
            -- capabilities = capabilities(),
            handlers = {
            --     ['textDocument/publishDiagnostics'] = vim.lsp.with(
            --         vim.lsp.diagnostic.on_publish_diagnostics,
            --         { virtual_text = false }
            --     ),
            --     unpack(require'lsp-status'.extensions.clangd.setup()),
            },
        }
        vim.lsp.enable('clangd')
    end
end

local function SetupLua()
    -- if vim.env.LUALS == nil then return end
    -- local lua_lsp_cmd = { vim.env.LUALS .. (env.os.win and [[\lua-language-server.exe]] or '/bin/lua-language-server') }
    local lua_lsp_cmd = "lua-language-server.exe"
    if not vim.fn.executable(lua_lsp_cmd) then return end
    vim.lsp.config('lua_ls', {
        cmd = { lua_lsp_cmd },
        filetypes = { 'lua' },
        on_attach = on_attach_lua,
        on_init = function(client)
            if on_init(client) == false then
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
                    checkThirdParty = 'Disable',
                    library = {
                        vim.env.VIMRUNTIME
                    }
                }
            })
        end,
        settings = {
            Lua = {}
        }
    })
    vim.lsp.enable('lua_ls')
end

local function SetupRust()
    if vim.fn.executable('rust-analyzer') then
        lsp.rust_analyzer.setup {
            on_attach = on_attach,
            capabilities = capabilities(),
            handlers = {
                ['textDocument/publishDiagnostics'] = vim.lsp.with(
                    vim.lsp.diagnostic.on_publish_diagnostics,
                    { virtual_text = false }
                ),
            },
        }
    end
end

local function SetupVim()
    if env.os.unix and vim.env.VIMLS and vim.env.VIMLS .. '/vim-language-server' then
        lsp.vimls.setup {
            cmd = { vim.env.VIMLS .. '/vim-language-server', '--stdio' },
            on_attach = on_attach,
            capabilities = capabilities(),
            fietypes = { 'vim' },
            suggest = {
                fromVimruntime = true,
                fromRuntimepath = true,
            },
        }
    end
end

local function SetupPython()
    -- vim.lsp.config.jedi_lanuage_server = {
    --     on_init = on_init,
    --     on_attach = on_attach,
    --     cmd = {"jedi-language-server"},
    --     filetypes = { 'python' },
    -- }
    -- vim.lsp.enable('jedi_lanuage_server')
    vim.lsp.config.ty = {
        on_init = on_init,
        on_attach = on_attach,
        cmd = {'ty', 'server'},
        filetypes = { 'python' },
    }
    vim.lsp.enable('ty')
end

M.SymError = ' '
M.SymWarn = ' '
M.SymInfo = ' '
M.SymHint = ' '
-- M.SymError = '█'
-- M.SymWarn = '▆'
-- M.SymInfo = '■'
-- M.SymHint = '▁'

function M.setup()
    vim.lsp.set_log_level('WARN')

    vim.diagnostic.config {
        signs =  {
            text = {
                [vim.diagnostic.severity.ERROR] = M.SymError,
                [vim.diagnostic.severity.WARN] = M.SymWarn,
                [vim.diagnostic.severity.INFO] = M.SymInfo,
                [vim.diagnostic.severity.HINT] = M.SymHint,
            },
        }
    }

    ut.set_highlight('LspReferenceText', { gui='bold' })
    ut.set_highlight('LspReferenceRead', { gui='bold' })
    ut.set_highlight('LspReferenceWrite', { gui='bold' })

    -- require'lsp-status'.register_progress()
    -- require'lsp-status'.config {
    --     mindicator_errors = M.SymError,
    --     indicator_warnings = M.SymWarn,
    --     indicator_info = M.SymInfo,
    --     indicator_hint = M.SymHint,
    --     status_symbol = '',
    --     current_function = true,
    -- }
    SetupClangd()
    SetupLua()
    -- SetupRust()
    -- SetupVim()
    SetupPython()

    local prjroot = require 'prjroot'
    local lsp_server_names = { 'clangd', 'lua_ls', 'ty' }

    api.nvim_create_autocmd('BufReadPre', {
        desc = 'Apply per-project LSP env vars from .prjroot',
        callback = function(ev)
            local fname = vim.api.nvim_buf_get_name(ev.buf)
            if fname == '' then return end
            local cfg = prjroot.GetPrjrootConfig(fname)
            if not cfg or not cfg.lsp_env then return end
            for _, name in ipairs(lsp_server_names) do
                vim.lsp.config(name, { cmd_env = cfg.lsp_env })
            end
        end,
    })

end

return M
