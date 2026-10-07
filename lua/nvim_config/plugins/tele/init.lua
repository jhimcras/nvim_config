local M = {}

function M.setup()
    require 'telescope'.setup {
        defaults = {
            mappings = {
                i = {
                    ["<esc>"] = require('telescope.actions').close,
                },
            },
            preview = false,
        }
    }
end

return M
