local M = {}
local api = vim.api
M.namespace = api.nvim_create_namespace('coderunner')
function M.refresh(buf)
    if not api.nvim_buf_is_valid(buf) or not api.nvim_buf_is_loaded(buf) then return end
    local runner = require('nvim_config.coderunner.run')
    local root = runner.root(buf)
    local cfg = require('nvim_config.coderunner').resolve(root, false)
    if not cfg.diagnostics then vim.diagnostic.reset(M.namespace, buf); return end
    local list = require('nvim_config.coderunner.blocks').get(buf, root)
    if not list then vim.diagnostic.reset(M.namespace, buf); return end
    local diagnostics = {}
    for _, block in ipairs(list) do
        local code, message, severity
        if block.duplicate then
            code, message, severity = 'duplicate-code-id', 'duplicate code id: ' .. block.id, vim.diagnostic.severity.ERROR
        elseif block.lang ~= 'output' then
            local result = require('nvim_config.coderunner.render').lookup(block)
            if result.status == 'failed' then
                code, message, severity = 'render-failed', (result.error or 'render failed'):match('[^\r\n]+'), vim.diagnostic.severity.WARN
            end
        end
        if not block.duplicate and block.lang ~= 'output' then
            local image = require('nvim_config.coderunner.export').stale(block, cfg)
            if image then diagnostics[#diagnostics + 1] = { lnum = image.row, col = image.col,
                severity = vim.diagnostic.severity.INFO, source = 'coderunner', code = 'stale-export',
                message = 'exported image is stale; use :CodeExport to update' } end
        end
        if code then diagnostics[#diagnostics + 1] = { lnum = block.start_row, col = 0,
            severity = severity, source = 'coderunner', code = code, message = message } end
    end
    vim.diagnostic.set(M.namespace, buf, diagnostics)
end
function M.setup()
    local group = api.nvim_create_augroup('CodeRunnerDiagnostics', { clear = true })
    api.nvim_create_autocmd({ 'BufReadPost', 'TextChanged', 'TextChangedI', 'BufWritePost' }, {
        group = group, pattern = { '*.md', '*.markdown' }, callback = function(args) M.refresh(args.buf) end,
    })
    for _, buf in ipairs(api.nvim_list_bufs()) do
        if api.nvim_buf_is_loaded(buf) and api.nvim_buf_get_name(buf):match('%.md$') then M.refresh(buf) end
    end
end
return M
