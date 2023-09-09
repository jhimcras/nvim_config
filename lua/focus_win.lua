--[[
# TODO
- Floating window background has been chagned because of this features
]]--

local M = {}

-- Background colors for active vs inactive windows
function M.setup(bg)
    local ut = require 'util'
    ut.set_highlight('Folded', { guibg='NONE' })       -- For inactivewin background
    ut.set_highlight('ActiveWindow', { guibg=bg.active })
    ut.set_highlight('InactiveWindow',  { guibg=bg.inactive })
    ut.set_highlight('NormalNC', 'InactiveWindow')
    --     {{ events={'WinEnter'}, cmds='set winhighlight=Normal:ActiveWindow,NormalNC:InactiveWindow' }})
    vim.api.nvim_create_autocmd('WinEnter', {callback = function()
        vim.opt.winhighlight = {Normal = 'ActiveWindow', NormalNC = 'InactiveWindow'}
    end})
end

return M
