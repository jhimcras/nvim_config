local M = {}

local defaults = {
    markdown = true,
    table_overlay = true,
    extra_shift = 0,
    min_text_width = 20,
    breakat = " \t",
    showbreak = "  ",
}

local config = vim.deepcopy(defaults)
local group
local saved_showbreak

local markdown_formatlistpat = [[^\s*\%(\d\+[.)]\|[-*+]\)\s\+]]

local function merge_options(opts)
    config = vim.tbl_deep_extend('force', vim.deepcopy(defaults), opts or {})
    if opts and opts.continuation_indent ~= nil and opts.extra_shift == nil then
        config.extra_shift = 0
    end
end

local function breakindentopt()
    local parts = {}
    if config.extra_shift ~= 0 then
        table.insert(parts, 'shift:' .. tostring(config.extra_shift))
    end
    return table.concat(parts, ',')
end

local function is_markdown_buffer(buf)
    local ft = vim.bo[buf or 0].filetype
    return ft == 'markdown' or ft == 'markdown.mdx'
end

local function apply_current_window()
    if vim.g.markdown_visual_wrap_enabled == false then
        return
    end
    if is_markdown_buffer(0) then
        M.apply(0)
    end
end

function M.apply(win)
    win = win or 0
    local actual_win = win == 0 and vim.api.nvim_get_current_win() or win
    local buf = vim.api.nvim_win_get_buf(actual_win)
    saved_showbreak = saved_showbreak or vim.o.showbreak
    vim.w[actual_win].markdown_visual_wrap_breakindentopt = vim.w[actual_win].markdown_visual_wrap_breakindentopt or vim.wo[win].breakindentopt
    vim.b[buf].markdown_visual_wrap_formatlistpat = vim.b[buf].markdown_visual_wrap_formatlistpat or vim.bo[buf].formatlistpat

    vim.wo[win].wrap = true
    vim.wo[win].linebreak = true
    vim.wo[win].breakindent = true
    vim.wo[win].breakindentopt = breakindentopt()
    vim.o.showbreak = config.showbreak
    vim.wo[win].list = false
    vim.bo[buf].formatlistpat = markdown_formatlistpat
    vim.api.nvim_win_call(actual_win, function()
        vim.opt_local.breakat = config.breakat
        vim.opt_local.formatoptions:remove('t')
    end)
end

function M.disable(win)
    win = win or 0
    local actual_win = win == 0 and vim.api.nvim_get_current_win() or win
    local buf = vim.api.nvim_win_get_buf(actual_win)
    vim.wo[win].wrap = false
    vim.wo[win].linebreak = false
    vim.wo[win].breakindent = false
    vim.wo[win].breakindentopt = vim.w[actual_win].markdown_visual_wrap_breakindentopt or ''
    vim.o.showbreak = saved_showbreak or ''
    if vim.b[buf].markdown_visual_wrap_formatlistpat ~= nil then
        vim.bo[buf].formatlistpat = vim.b[buf].markdown_visual_wrap_formatlistpat
    end
    vim.w[actual_win].markdown_visual_wrap_breakindentopt = nil
    vim.b[buf].markdown_visual_wrap_formatlistpat = nil
    saved_showbreak = nil
end

function M.toggle()
    if vim.wo.wrap then
        M.disable(0)
    else
        M.apply(0)
    end
end

function M.setup(opts)
    merge_options(opts)
    saved_showbreak = nil
    vim.g.markdown_visual_wrap_enabled = config.markdown
    vim.g.neopp_markdown_table_wrap = config.table_overlay

    group = vim.api.nvim_create_augroup('markdown_visual_wrap', { clear = true })

    vim.api.nvim_create_user_command('MarkdownWrapToggle', function()
        M.toggle()
    end, {})

    if config.markdown then
        vim.api.nvim_create_autocmd('FileType', {
            group = group,
            pattern = { 'markdown', 'markdown.mdx' },
            callback = apply_current_window,
        })

        vim.api.nvim_create_autocmd({ 'BufWinEnter', 'WinEnter' }, {
            group = group,
            callback = apply_current_window,
        })
    end
end

return M
