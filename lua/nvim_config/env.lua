local M = {}

M.os = {
    unix = vim.fn.has('unix') == 1;
    win32 = vim.fn.has('win32') == 1;
    win64 = vim.fn.has('win64') == 1;
    win = vim.fn.has('win32') == 1 or vim.fn.has('win64') == 1;
}

M.dir_sep = (M.os.win) and [[\]] or '/'
M.new_line_char = (M.os.win) and '\r\n' or '\n'

return M
