local M = {}

function M.color(mode)
    local mode_color = {
        Normal = { bg = { '#334155', '#1F2937' }, fg = { '#D1D5DB', '#9CA3AF'} };
        Insert = { bg = { '#98BC99', '#1F2937' }, fg = { '#111827', '#98BC99' } };
        Visual = { bg = { '#FBC19D', '#1F2937' }, fg = { '#111827', '#FBC19D' } };
        None = { bg = { '#b7bdc0', '#494C4D' }, fg = { '#212121', '#b7bdc0' } };
        Command = { bg = { '#99BBBD', '#1F2937' }, fg = { '#111827', '#99BBBD' } };
        Replace = { bg = { '#E8D4B0', '#1F2937' }, fg = { '#111827', '#E8D4B0' } };
    }
    mode_color.Terminal = mode_color.Insert
    return mode_color[mode] or mode_color.None
end

function M.current(buftype)
    local leading_charater_of_current_mode = string.sub(vim.fn.mode(), 1, 1)
    local mode = {
        n = 'Normal',
        c = 'Command',
        i = 'Insert',
        R = 'Replace',
        v = 'Visual', V = 'Visual', ['^V'] = 'Visual',
        s = 'Select', S = 'Select', ['^S'] = 'Select',
        t = 'Terminal',
        r = 'None', ['!'] = 'None',
    }
    local buf_mode = {
        quickfix = 'Quickfix',
    }
    return buf_mode[buftype] or mode[leading_charater_of_current_mode] or ''
end

return M
