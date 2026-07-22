local M = {}

function M.setup()
    local oil = require('oil')

    local sort_state = { key = nil, order = 'asc' }

    local function toggle_sort(key)
        if sort_state.key == key then
            sort_state.order = (sort_state.order == 'asc') and 'desc' or 'asc'
        else
            sort_state.key = key
            sort_state.order = 'asc'
        end
        oil.set_sort { { 'type', 'asc' }, { sort_state.key, sort_state.order } }
    end

    oil.setup {
        columns = { {"mtime", format = "%Y%m%d %T"}, "size", },
        view_options = {
            show_hidden = true,
            case_insensitive = true,
        },
        confirmation = {
            border = "rounded",
        },
        keymaps = {
            ["<C-h>"] = false,
            ["<C-l>"] = false,
            ["gs"] = false,
            ['ss'] = { callback = function() toggle_sort('size')  end },
            ['st'] = { callback = function() toggle_sort('mtime') end },
            ['sn'] = { callback = function() toggle_sort('name')  end },
            ['_'] = { callback = function() vim.cmd.vsplit(); end },
        },
    }
end

return M
