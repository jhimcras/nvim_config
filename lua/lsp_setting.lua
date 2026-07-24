local env = require 'env'
local ut = require 'util'
local api = vim.api

local M = {}

function M.has_lsp_attached(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    local clients = vim.lsp.get_clients{ bufnr = bufnr }
    return next(clients) ~= nil
end

-- LSP settings (for overriding per client)
-- local handlers =  {
--   ["textDocument/hover"] =  vim.lsp.with(vim.lsp.handlers.hover, {border = border}),
--   ["textDocument/signatureHelp"] =  vim.lsp.with(vim.lsp.handlers.signature_help, {border = border }),
-- }

local orig_util_open_floating_preview = vim.lsp.util.open_floating_preview
local fence_conceal_ns = api.nvim_create_namespace('lsp_hover_fence_conceal')
function vim.lsp.util.open_floating_preview(contents, syntax, opts, ...)
    opts = opts or {}
    local fbuf, fwin = orig_util_open_floating_preview(contents, syntax, opts, ...)
    -- Hide the markdown code-fence delimiter lines (```lang / ```) in hover/signature
    -- floats. Neovim stylizes the float as markdown + treesitter, so the fenced code
    -- itself is syntax-highlighted, but the fence markers stay visible: render-markdown
    -- doesn't attach to floats and core treesitter's query-conceal doesn't fire for them.
    -- Conceal the whole delimiter line via extmark, then shrink the float to reclaim the
    -- now-blank rows.
    if fbuf and fwin and vim.bo[fbuf].filetype == 'markdown' then
        local lines = api.nvim_buf_get_lines(fbuf, 0, -1, false)
        local hidden = 0
        for i, line in ipairs(lines) do
            if line:match('^%s*[`~][`~][`~]') then
                api.nvim_buf_set_extmark(fbuf, fence_conceal_ns, i - 1, 0, { conceal_lines = '' })
                hidden = hidden + 1
            end
        end
        if hidden > 0 then
            local h = api.nvim_win_get_height(fwin)
            if h - hidden >= 1 then
                api.nvim_win_set_height(fwin, h - hidden)
            end
        end
    end
    return fbuf, fwin
end

local function general_mappings()
    ut.nnoremap('gW', vim.lsp.buf.workspace_symbol, {'buffer'})

    -- Diagnostic keymaps
    ut.nnoremap('[d', function() vim.diagnostic.jump{count=-1, float=true} end, {'buffer'})
    ut.nnoremap(']d', function() vim.diagnostic.jump{count=1, float=true} end, {'buffer'})
    ut.nnoremap('<leader>do', vim.diagnostic.setloclist, {'buffer'})
end

local function reference_highlighting(client, bufnr)
    if not client:supports_method('textDocument/documentHighlight', bufnr) then return end
    local group = api.nvim_create_augroup('lsp_reference_highlight_' .. bufnr, { clear = true })
    api.nvim_create_autocmd('CursorHold', { group = group, buffer = bufnr, callback = function() vim.lsp.buf.document_highlight() end })
    api.nvim_create_autocmd('CursorHoldI', { group = group, buffer = bufnr, callback = function() vim.lsp.buf.document_highlight() end })
    api.nvim_create_autocmd('CursorMoved', { group = group, buffer = bufnr, callback = function() vim.lsp.buf.clear_references() end })
end

-- Fugitive names its blob buffers with the OS path separator, so on Windows
-- they look like `fugitive:\\\D:\...` rather than `fugitive://...`. Normalize
-- backslashes before probing for a URI scheme (see commit 7bbc710), otherwise
-- these buffers slip past the guard and clangd errors on their non-file URIs.
local function has_uri_scheme(bufnr)
    local name = vim.api.nvim_buf_get_name(bufnr):gsub('\\', '/')
    return name:match('^%a[%w+.-]*://') ~= nil
end

function M.make_on_attach(extras)
    return function(client, bufnr)
        if vim.bo[bufnr].buftype ~= '' or has_uri_scheme(bufnr) then
            vim.lsp.buf_detach_client(bufnr, client.id)
            return
        end
        general_mappings()
        reference_highlighting(client, bufnr)
        if extras then extras(client, bufnr) end
    end
end

function M.on_init(client, initialize_result)
    local bufnr = vim.api.nvim_get_current_buf()
    local name = vim.api.nvim_buf_get_name(bufnr) or ""
    if name:match("^fugitive:") then
        client.stop()
        return false
    end
    return true
end

M.SymError = ' '
M.SymWarn = ' '
M.SymInfo = ' '
M.SymHint = ' '
-- M.SymError = '█'
-- M.SymWarn = '▆'
-- M.SymInfo = '■'
-- M.SymHint = '▁'

-- [client_id] = 'running' | 'done', tracks whether each client's progress
-- sequences (e.g. indexing) are still in flight or have all completed.
M.progress_state = {}

local function update_progress_state(ev)
    local kind = ev.data.params.value.kind
    local client_id = ev.data.client_id
    if kind == 'begin' then
        M.progress_state[client_id] = 'running'
    elseif kind == 'end' then
        local client = vim.lsp.get_client_by_id(client_id)
        if client and next(client.progress.pending) == nil then
            M.progress_state[client_id] = 'done'
        end
    end
end

function M.setup()
    vim.lsp.log.set_level('WARN')

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

    local redrawstatus_throttled = ut.throttle(function() vim.cmd.redrawstatus() end, 80)
    api.nvim_create_autocmd({'LspProgress', 'DiagnosticChanged'}, {
        callback = function(ev)
            if ev.event == 'LspProgress' then
                update_progress_state(ev)
            end
            redrawstatus_throttled()
        end,
    })

    require('lsp_setting.clangd').setup()
    require('lsp_setting.lua_ls').setup()
    require('lsp_setting.python').setup()
    require('lsp_setting.markdown').setup()

    local prjroot = require 'prjroot'
    local lsp_server_names = { 'clangd', 'lua_ls', 'ty' }

    api.nvim_create_autocmd('BufReadPre', {
        desc = 'Apply per-project LSP settings from .prjroot',
        callback = function(ev)
            local fname = vim.api.nvim_buf_get_name(ev.buf)
            if fname == '' then return end
            local cfg = prjroot.GetPrjrootConfig(fname)
            if not cfg then return end
            if cfg.lsp_env then
                for _, name in ipairs(lsp_server_names) do
                    vim.lsp.config(name, { cmd_env = cfg.lsp_env })
                end
            end
            if cfg.clangd_args then
                vim.lsp.config('clangd', { cmd = require('lsp_setting.clangd').cmd(cfg.clangd_args) })
            end
        end,
    })

end

return M
