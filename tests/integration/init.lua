-- Exercise the checkout's real init.lua and setup order. Only third-party plugin
-- installation and external LSP processes are excluded from these core features.
-- Keep path/setup changes here; feature tests assert user-visible behavior.
vim.opt.rtp:prepend(vim.env.NVIM_TEST_ROOT)
package.loaded['nvim_config.plugins'] = { setup = function() end }
vim.lsp.enable = function() end

vim.g.integration_errors = {}
local notify = vim.notify
vim.notify = function(message, level, ...)
    if level == vim.log.levels.ERROR then
        local errors = vim.g.integration_errors
        errors[#errors + 1] = tostring(message)
        vim.g.integration_errors = errors
    end
    return notify(message, level, ...)
end

local ok, err = xpcall(function()
    dofile(vim.env.NVIM_TEST_ROOT .. '/init.lua')
end, debug.traceback)
if not ok then vim.notify(err, vim.log.levels.ERROR) end

vim.api.nvim_create_autocmd('VimEnter', { once = true, callback = function()
    vim.schedule(function() vim.g.integration_ready = true end)
end })
