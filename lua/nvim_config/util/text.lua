local M = {}


function M.GetVisualSelection()
    local mode = vim.fn.mode()
    if mode == 'v' then
        local line_start = vim.fn.line('v')
        local line_end = vim.fn.line('.')
        local column_start = vim.fn.col('v')
        local column_end = vim.fn.col('.')
        if line_start == line_end then
            return { line_start, math.min(column_start, column_end), line_end, math.max(column_start, column_end) }
        elseif line_start > line_end then
            return { line_end, column_end, line_start, column_start }
        else
            return { line_start, column_start, line_end, column_end }
        end
    elseif mode == 'V' then
        local line_start = vim.fn.line('v')
        local line_end = vim.fn.line('.')
        local last_line_len = string.len(vim.api.nvim_buf_get_lines(0, math.max(line_start, line_end)-1, math.max(line_start, line_end), false)[1])
        return { math.min(line_start, line_end), 1, math.max(line_start, line_end), last_line_len }
    end
    -- TODO: visual block mode...
end


function M.GetSelectWord()
    local sel = M.GetVisualSelection()
    if sel and sel[1] == sel[3] then
        local ln = vim.api.nvim_buf_get_lines(0, sel[1]-1, sel[1], false)
        return string.sub(ln[1], sel[2], sel[4])
    end
end


function M.StripTrailingWhitespace()
    local prevPosition = vim.fn.getpos('.')
    local prevSearch = vim.fn.getreg('/')
    vim.cmd('%s/\\s\\+$//e')
    vim.fn.setreg('/', prevSearch)
    vim.fn.setpos('.', prevPosition)
end



return M
