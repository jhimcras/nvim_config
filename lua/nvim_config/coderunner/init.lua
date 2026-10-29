local M = {}
local config = require('nvim_config.coderunner.config')
local trust = require('nvim_config.coderunner.trust')
local global = config.validate({}, 'global')

local function root()
    local file = vim.api.nvim_buf_get_name(0)
    return require('nvim_config.prjroot').GetProjectRoot(file) or vim.fs.dirname(file) or vim.fn.getcwd()
end

local function report(status)
    vim.notify('coderunner: ' .. status.state .. ' (' .. status.path .. ')')
    for _, d in ipairs(status.diagnostics or {}) do
        vim.notify(d.message, d.level == 'error' and vim.log.levels.ERROR or vim.log.levels.WARN)
    end
    if status.error then vim.notify(status.error, vim.log.levels.ERROR) end
end

-- explicit=true is reserved for commands initiated by the user. Automatic
-- consumers use false and cannot cause a secure.read prompt.
function M.resolve(workspace, explicit)
    local status = trust.status(workspace)
    if explicit and status.state ~= 'loaded' and status.state ~= 'absent' then
        status = trust.load(workspace)
    end
    return config.merge(global, status.config), status
end

function M.setup(opts)
    local diagnostics
    global, diagnostics = config.validate(opts or {}, 'global')
    for _, d in ipairs(diagnostics) do
        vim.notify(d.message, d.level == 'error' and vim.log.levels.ERROR or vim.log.levels.WARN)
    end
    vim.api.nvim_create_user_command('CodeRunnerLoad', function() report(trust.load(root())) end, {})
    vim.api.nvim_create_user_command('CodeRunnerTrust', function() report(trust.status(root())) end, {})
    vim.api.nvim_create_user_command('CodeRunnerUntrust', function()
        local ok, err = trust.untrust(root())
        if not ok then vim.notify('coderunner: ' .. tostring(err), vim.log.levels.ERROR) end
        report(trust.status(root()))
    end, {})
    require('nvim_config.coderunner.run').setup()
    require('nvim_config.coderunner.render').setup()
    require('nvim_config.coderunner.autorender').setup()
    require('nvim_config.coderunner.export').setup()
    require('nvim_config.coderunner.provider').setup()
    require('nvim_config.coderunner.keymap').setup()
    return config.merge(global), diagnostics
end

function M.diagrams(buf) return require('nvim_config.coderunner.provider').diagrams(buf) end
function M.request_live(buf, row) return require('nvim_config.coderunner.provider').request_live(buf, row) end

return M
