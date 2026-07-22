local M = {}

-- Dim the sub-list nested under a completed ('[x]') checkbox item, since
-- render-markdown's own checkbox.checked.scope_highlight only covers the
-- checked item's own line, not its nested children.
local checked_sublist_query = vim.treesitter.query.parse('markdown', '(list_item) @item')

local function parse_checked_sublists(ctx)
    local marks = {}
    for _, item in checked_sublist_query:iter_captures(ctx.root, ctx.buf) do
        local checked, sublist = false, nil
        for child in item:iter_children() do
            if child:type() == 'task_list_marker_checked' then
                checked = true
            elseif child:type() == 'list' then
                sublist = child
            end
        end
        if checked and sublist then
            local start_row, start_col, end_row, end_col = sublist:range()
            marks[#marks + 1] = {
                conceal = false,
                start_row = start_row,
                start_col = start_col,
                opts = {
                    end_row = end_row,
                    end_col = end_col,
                    hl_group = 'Comment',
                    hl_eol = true,
                },
            }
        end
    end
    return marks
end

function M.setup()
    require'render-markdown'.setup{
        custom_handlers = {
            markdown = { extends = true, parse = parse_checked_sublists },
        },
        overrides = {
            buftype = {
                nofile = { enabled = false },
            },
        },
        indent = {
            enabled = false,
            render_modes = true,
            per_level = 4,
            skip_level = 0,
            skip_heading = true,
        },
        heading = {
            icons = { '  ' },
            signs = { ' ' },
            width = 'block',
            -- border = true,
            -- left_pad = 2,
            -- right_pad = 2,
        },
        checkbox = {
            unchecked = { icon = ' ' },
            checked   = { icon = '', scope_highlight = 'Comment' },
            custom = {
                todo = { raw = '[-]', rendered = ' ', highlight = 'RenderMarkdownTodo', scope_highlight = nil },
            },
        },
        link = {
            image     = '',
            email     = ' ',
            hyperlink = ' ',
            wiki      = { icon = ' ' },
            custom = {
                web       = { pattern = '^http',          icon = ' '  },
                github    = { pattern = 'github%.com',    icon = '  ' },
                google    = { pattern = 'google%.com',    icon = '  ' },
                reddit    = { pattern = 'reddit%.com',    icon = '  ' },
                wikipedia = { pattern = 'wikipedia%.org', icon = '  ' },
                youtube   = { pattern = 'youtube%.com',   icon = '󰗃 '  },
            },
        },
        code = {
            language = true,
            position = 'right',
            width = 'block',
            left_pad = 1,
            right_pad = 1,
            min_width = 50,
            border = 'thin',
            disable = { 'plantuml', 'puml', 'uml' },
        },
        -- Tables are rendered by lua/wrap.lua (wrapped cells + proportional widths).
        pipe_table = { enabled = false },
    }
end

return M
