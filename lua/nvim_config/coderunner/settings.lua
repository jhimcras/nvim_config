-- Global coderunner settings plus per-workspace resolution. Submodules use
-- this instead of the coderunner facade so they never require their parent.
local M = {}
local config = require('nvim_config.coderunner.config')
local trust = require('nvim_config.coderunner.trust')
local global = config.validate({}, 'global')

function M.set_global(opts)
    local diagnostics
    global, diagnostics = config.validate(opts or {}, 'global')
    return global, diagnostics
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

return M
