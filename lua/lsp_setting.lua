local lsp = require 'lspconfig'
local env = require 'env'
local ut = require 'util'
local api = vim.api

local M = {}

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
    ut.nnoremap('gd', vim.lsp.buf.declaration, {'buffer'})
    ut.nnoremap('<c-]>', vim.lsp.buf.definition, {'buffer'})
    ut.nnoremap('<c-m-]>', '<cmd>vs<cr><cmd>lua vim.lsp.buf.definition()<CR>', {'buffer'})
    ut.nnoremap('<2-LeftMouse>', vim.lsp.buf.definition, {'buffer'})
    ut.nnoremap('<2-RightMouse>', '<c-o>', {'buffer'})
    ut.nnoremap('K', vim.lsp.buf.hover, {'buffer'})
    ut.nnoremap('gD', vim.lsp.buf.implementation, {'buffer'}) -- clangd doesn't support this
    ut.nnoremap('1gD', vim.lsp.buf.type_definition, {'buffer'}) -- clangd doesn't support this
    ut.nnoremap('gr', vim.lsp.buf.references, {'buffer'})
    ut.nnoremap('g0', vim.lsp.buf.document_symbol, {'buffer'})
    ut.nnoremap('gW', vim.lsp.buf.workspace_symbol, {'buffer'})
    --ut.inoremap('<c-k>', vim.lsp.buf.signature_help, {'buffer'})
    ut.nnoremap('<F2>', vim.lsp.buf.rename, {'buffer'})
    ut.nnoremap('ga', vim.lsp.buf.code_action, {'buffer'})

    -- Diagnostic keymaps
    ut.nnoremap('[d', vim.diagnostic.goto_prev, {'buffer'})
    ut.nnoremap(']d', vim.diagnostic.goto_next, {'buffer'})
    ut.nnoremap('<leader>do', vim.diagnostic.setloclist, {'buffer'})
end

local function reference_highliting()
    api.nvim_create_autocmd('CursorHold', { buffer = 0, callback = function() vim.lsp.buf.document_highlight() end })
    api.nvim_create_autocmd('CursorHoldI', { buffer = 0, callback = function() vim.lsp.buf.document_highlight() end })
    api.nvim_create_autocmd('CursorMoved', { buffer = 0, callback = function() vim.lsp.buf.clear_references() end })
end

local function on_attach(client)
    --require'lsp-status'.on_attach(client)
    -- This came from https://github.com/tjdevries/config_manager/blob/master/xdg_config/nvim/lua/lsp_config.lua
    --require'illuminate'.on_attach(client)
    general_mappings()
    reference_highliting()
end

local function on_attatch_clangd(args)
    general_mappings()
    ut.nnoremap('<m-o>', '<cmd>ClangdSwitchSourceHeader<cr>', { 'buffer' })
    ut.nnoremap('<m-O>', '<cmd>vertical split<cr><cmd>ClangdSwitchSourceHeader<cr>', { 'buffer' })
    reference_highliting()
    vim.bo.formatexpr = 'v:lua.vim.lsp.formatexpr()'
end

local function on_attatch_lua(args)
    general_mappings()
    reference_highliting()
    vim.bo.formatexpr = 'v:lua.vim.lsp.formatexpr()'
end

local function SetupClangd()
    if vim.fn.executable('clangd') then
        lsp.clangd.setup {
            on_attach = on_attatch_clangd,
            cmd = {
                'clangd',
                '--cross-file-rename',
                '--background-index',
                '--clang-tidy',
                --'--log=verbose',
            },
            capabilities = capabilities(),
            -- init_options = {
            --     usePlaceholders = false,
            --     completeUnimported = false,
            --     clangdFileStatus = true,
            -- },
            -- root_dir = lsp.util.root_pattern(
            --     './build/compile_commands.json',
            --     'compile_commands.json',
            --     'compile_flags.txt',
            --     '.git'
            -- ),
            handlers = {
                ['textDocument/publishDiagnostics'] = vim.lsp.with(
                    vim.lsp.diagnostic.on_publish_diagnostics,
                    { virtual_text = false }
                ),
                unpack(require'lsp-status'.extensions.clangd.setup()),
            },
        }
    end
end

local function SetupLua()
    if vim.env.LUALS == nil then return end
    local lua_lsp_cmd = { vim.env.LUALS .. (env.os.win and [[\lua-language-server.exe]] or '/bin/lua-language-server') }
    if vim.fn.executable(lua_lsp_cmd[1]) then
        lsp.lua_ls.setup {
            cmd = lua_lsp_cmd,
            on_attach = on_attatch_lua,
            capabilities = capabilities(),
            settings = {
                Lua = {
                    completion = {
                        -- keywordSnippet = "Disable";
                    },
                    runtime = {
                        version = 'LuaJIT',
                    },
                    diagnostics = {
                        enable = true,
                        globals = { 'vim', 'unpack', 'ffi' },
                    },
                    workspace = {
                        library = {
                            --[vim.fn.expand("~/packages/neovim/runtime/lua")] = true,
                            --[vim.fn.expand("~/packages/neovim/src/nvim/lua")] = true,
                        },
                    },
                },
            },
            handlers = {
                ['textDocument/publishDiagnostics'] = vim.lsp.with(
                    vim.lsp.diagnostic.on_publish_diagnostics,
                    { virtual_text = false }
                ),
            },
            -- handlers = handlers,
        }
    end
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
    lsp.jedi_language_server.setup {
        on_attach = on_attach,
        capabilities = capabilities(),
        cmd = { 'py', '-m', 'jedi_language_server' },
    }
end

function M.setup()
    vim.fn.sign_define('DiagnosticSignError', { text = '█', texthl = 'DiagnosticSignError' })
    vim.fn.sign_define('DiagnosticSignWarn', { text = '▆', texthl = 'DiagnosticSignWarn' })
    vim.fn.sign_define('DiagnosticSignInfo', { text = '■', texthl = 'DiagnosticSignInfo' })
    vim.fn.sign_define('DiagnosticSignHint', { text = '▁', texthl = 'DiagnosticSignHint' })
    -- vim.fn.sign_define('DiagnosticSignError', {text = ' ', texthl = 'DiagnosticSignError'})
    -- vim.fn.sign_define('DiagnosticSignWarn', {text = ' ', texthl = 'DiagnosticSignWarn'})
    -- vim.fn.sign_define('DiagnosticSignInfo', {text = ' ', texthl = 'DiagnosticSignInfo'})
    -- vim.fn.sign_define('DiagnosticSignHint', {text = '𥉉', texthl = 'DiagnosticSignHint'})

    ut.set_highlight('LspReferenceText', { gui='bold' })
    ut.set_highlight('LspReferenceRead', { gui='bold' })
    ut.set_highlight('LspReferenceWrite', { gui='bold' })

    require'lsp-status'.register_progress()
    require'lsp-status'.config {
        indicator_errors = 'E',
        indicator_warnings = 'W',
        indicator_info = 'I',
        indicator_hint = '!',
        status_symbol = '',
    }
    SetupClangd()
    SetupLua()
    SetupRust()
    SetupVim()
    SetupPython()
end

return M
