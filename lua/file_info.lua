local ut = require 'util'

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
    add_line("Path", bufname ~= "" and bufname or "[No Name]")

    local protocol = ut.GetBufferProtocol(bufnr)
    if protocol and protocol ~= '' then
        add_line("Protocol", protocol)
    end

    local pr = require'prjroot'.GetProjectRoot(bufname)
    if pr then
        add_line("Project", vim.fn.fnamemodify(pr, ':t'))
        local branch, commit = require'git'.git_branch_commit(pr)
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
    add_line("Cursor", string.format("Line %d, Col %d (%d%%)", cursor[1], cursor[2], math.floor(cursor[1] / (total_lines > 0 and total_lines or 1) * 100)))

    local status = require 'status'
    local cur_func = status.current_function()
    if cur_func and cur_func ~= "" then
        add_line("Function", cur_func)
    end

    if next(vim.lsp.get_clients{bufnr = bufnr}) ~= nil then
        add_line("LSP", vim.trim(require'lsp-status'.status()))
    end

    -- Create floating window
    local width = 0
    for _, line in ipairs(lines) do
        width = math.max(width, vim.fn.strdisplaywidth(line))
    end
    width = width + 4
    local height = #lines

    -- Resize width if it exceeds editor width
    if width > vim.o.columns - 2 then
        width = vim.o.columns - 2
    end

    local win_pos = vim.api.nvim_win_get_position(winid)
    local win_width = vim.api.nvim_win_get_width(winid)
    local win_height = vim.api.nvim_win_get_height(winid)

    local row = math.floor(win_pos[1] + (win_height - height) / 2)
    local col = math.floor(win_pos[2] + (win_width - width) / 2)

    -- Clipping logic to ensure the window stays within editor boundaries
    -- We assume a border is used, which adds 1 to each side.
    -- To keep the border within the screen (0 to vim.o.lines - 1):
    -- row - 1 >= 0 => row >= 1
    -- row + height + 1 <= vim.o.lines => row <= vim.o.lines - height - 1
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

    local function close()
        if vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_win_close(win, true)
        end
    end

    vim.keymap.set('n', 'q', close, { buffer = buf, silent = true })
    vim.keymap.set('n', '<Esc>', close, { buffer = buf, silent = true })
    vim.keymap.set('n', '<C-g>', close, { buffer = buf, silent = true })
end

function M.setup()
    vim.api.nvim_create_user_command('FileInfo', M.show, {})
    ut.nnoremap('<C-g>', M.show)
end

return M
