local lsp_setting = require('lsp_setting')
local ut = require 'util'

local M = {}

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

local on_attach_clangd = lsp_setting.make_on_attach(function(client, bufnr)
    vim.api.nvim_buf_create_user_command(0, 'ClangdSwitchSourceHeader', function() switch_source_header(0) end, { desc = 'Switch between source/header' })
    ut.nnoremap('<m-o>', '<cmd>ClangdSwitchSourceHeader<cr>', { 'buffer' })
    ut.nnoremap('<m-O>', '<cmd>vertical split<cr><cmd>ClangdSwitchSourceHeader<cr>', { 'buffer' })
    vim.bo.formatexpr = 'v:lua.vim.lsp.formatexpr()'
end)

-- clangd defaults to one async worker per CPU core, and the background index draws
-- from that same pool, so indexing a large project saturates the machine. Halve the
-- workers and drop the index threads to the lowest priority tier -- the default is
-- `low`, not `background`. On Windows `background` also lowers disk I/O priority,
-- which is where the indexing stall hurts most.
-- `extra` comes from a project's `.prjroot`; clangd takes the last occurrence of a
-- repeated flag, so appending is enough to override any default below.
function M.cmd(extra)
    local cmd = {
        'clangd',
        '--log=error',
        '-j=' .. math.max(2, math.floor(vim.uv.available_parallelism() / 2)),
        '--background-index-priority=background',
        -- '--background-index',
        -- '--cross-file-rename',
        -- '--clang-tidy',
    }
    return vim.list_extend(cmd, extra or {})
end

function M.setup()
    if vim.fn.executable('clangd') then
        vim.lsp.config.clangd = {
            on_init = lsp_setting.on_init,
            on_attach = on_attach_clangd,
            cmd = M.cmd(),
            root_markers = {
                'compile_commands.json',
                '.git'
                -- './build/compile_commands.json',
                -- 'compile_flags.txt',
            },
            filetypes = { 'c', 'cpp' },
            -- capabilities = capabilities(),
            handlers = {
            },
        }
        vim.lsp.enable('clangd')
    end
end

return M
