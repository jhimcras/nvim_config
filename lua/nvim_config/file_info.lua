local ut = require('nvim_config.util.buffer')
local env = require('nvim_config.env')

local M = {}

local function format_size(bytes)
    local units = { 'B', 'KB', 'MB', 'GB', 'TB' }
    if bytes < 0 then return 'Unknown' end
    if bytes == 0 then return '0 B' end
    local i = 1
    while bytes >= 1024 and i < #units do
        bytes = bytes / 1024
        i = i + 1
    end
    return string.format('%.2f %s', bytes, units[i])
end

-- oil:///D/dir/ -> D:\dir\ on Windows
local function oil_to_windows(path)
    return (path:gsub('^/(%a)/', '%1:/'):gsub('/', '\\'))
end

-- Work tree of a fugitive buffer (`fugitive:///repo/.git//...`; `fugitive:\\\D:\...` on Windows).
local function fugitive_work_tree(bufnr)
    local raw = vim.api.nvim_buf_get_name(bufnr):gsub('\\', '/')
    if not raw:match('^fugitive://') then return nil end
    if vim.fn.exists('*FugitiveWorkTree') == 1 then
        local tree = vim.fn.FugitiveWorkTree(bufnr)
        if tree ~= '' then return tree end
    end
    local tree = raw:match('^fugitive://(.-)/%.git//')
    return tree and (tree:gsub('^/(%a:)', '%1'))
end

-- Path of the buffer's file (or oil directory, or fugitive work tree) in the OS's
-- native form; nil if none.
function M.file_path(bufnr)
    bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
    local tree = fugitive_work_tree(bufnr)
    if tree then
        return env.os.win and (tree:gsub('/', '\\')) or tree
    end
    local name = ut.GetBufferName(bufnr)
    local protocol = ut.GetBufferProtocol(bufnr)
    if name == '' or (protocol and protocol ~= 'oil') then return nil end
    if not env.os.win then return name end
    if protocol == 'oil' then return oil_to_windows(name) end
    return (name:gsub('/', '\\'))
end

function M.copy_path(bufnr)
    local path = M.file_path(bufnr or 0)
    if not path then
        vim.notify('No file path for this buffer', vim.log.levels.WARN)
        return
    end
    vim.fn.setreg('+', path)
    vim.notify('Copied: ' .. path)
end

function M.show()
    local bufnr = vim.api.nvim_get_current_buf()
    local winid = vim.api.nvim_get_current_win()
    local lines = {}

    local function add_line(label, value)
        if value and value ~= "" then
            table.insert(lines, string.format("%-11s: %s", label, value))
        end
    end

    local bufname = ut.GetBufferName(bufnr)
    local protocol = ut.GetBufferProtocol(bufnr)
    if protocol == 'oil' and env.os.win then
        bufname = oil_to_windows(bufname)
    end
    add_line("Path", bufname ~= "" and bufname or "[No Name]")

    if protocol and protocol ~= '' then
        add_line("Protocol", protocol)
    end

    local pr = require'nvim_config.prjroot'.GetProjectRoot(bufname)
    if pr then
        add_line("Project", vim.fn.fnamemodify(pr, ':t'))
        local branch, commit = require'nvim_config.git'.git_branch_commit(pr)
        if branch then
            add_line("Branch", branch)
        elseif commit then
            add_line("Commit", commit:sub(1, 10))
        end
    end

    add_line("Filetype", vim.bo[bufnr].filetype)
    add_line("Encoding", (vim.bo[bufnr].fileencoding ~= "" and vim.bo[bufnr].fileencoding or "utf-8") .. (vim.bo[bufnr].bomb and " (BOM)" or ""))

    if bufname ~= "" then
        local fsize = vim.fn.getfsize(bufname)
        if fsize ~= -1 then
            add_line("Size", format_size(fsize))
        end

        local ftime = vim.fn.getftime(bufname)
        if ftime ~= -1 then
            add_line("Modified", os.date("%Y-%m-%d %H:%M:%S", ftime))
        end
    end

    local cursor = vim.api.nvim_win_get_cursor(winid)
    local total_lines = vim.api.nvim_buf_line_count(bufnr)
    add_line("Cursor", string.format("Line %d, Col %d (%d%%)", cursor[1], cursor[2] + 1, math.floor(cursor[1] / (total_lines > 0 and total_lines or 1) * 100)))

    local symbol = require 'nvim_config.symbol'
    local cur_func = symbol.current_function()
    if cur_func and cur_func ~= "" then
        add_line("Function", cur_func)
    end

    if next(vim.lsp.get_clients{bufnr = bufnr}) ~= nil then
        local lsp = require('nvim_config.lsp.status').summary(bufnr)
        if lsp ~= '' then
            add_line("LSP", lsp)
        end
    end

    -- Floating window
    local width = 0
    for _, line in ipairs(lines) do
        width = math.max(width, vim.fn.strdisplaywidth(line))
    end
    width = width + 4

    -- Clamp to the editor width
    if width > vim.o.columns - 2 then
        width = vim.o.columns - 2
    end

    -- Long lines (e.g. Path) wrap instead of scrolling horizontally.
    local height = 0
    for _, line in ipairs(lines) do
        height = height + math.max(1, math.ceil(vim.fn.strdisplaywidth(line) / width))
    end
    height = math.min(height, vim.o.lines - 4)

    local win_pos = vim.api.nvim_win_get_position(winid)
    local win_width = vim.api.nvim_win_get_width(winid)
    local win_height = vim.api.nvim_win_get_height(winid)

    local row = math.floor(win_pos[1] + (win_height - height) / 2)
    local col = math.floor(win_pos[2] + (win_width - width) / 2)

    -- Keep the window and its border inside the editor.
    row = math.max(1, math.min(row, vim.o.lines - height - 1))
    col = math.max(1, math.min(col, vim.o.columns - width - 1))

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

    local opts = {
        relative = 'editor',
        width = width,
        height = height,
        row = row,
        col = col,
        style = 'minimal',
        border = 'rounded',
        title = ' File Information ',
        title_pos = 'center',
    }
    local win = vim.api.nvim_open_win(buf, true, opts)
    vim.wo[win].wrap = true

    local function close()
        if vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_win_close(win, true)
        end
    end

    vim.keymap.set('n', 'q', close, { buffer = buf, silent = true })
    vim.keymap.set('n', '<Esc>', close, { buffer = buf, silent = true })
    vim.keymap.set('n', '<C-g>', close, { buffer = buf, silent = true })
    vim.keymap.set('n', 'y', function()
        close()
        M.copy_path(bufnr)
    end, { buffer = buf, silent = true })
end

function M.setup()
end

return M
