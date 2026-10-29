local M = {}
local api = vim.api
local views = {}
local function content(job)
    local lines = { 'CodeRunner #' .. job.id .. ' — ' .. job.status }
    local result = job.result or job
    if result.elapsed then lines[#lines + 1] = string.format('Elapsed: %.0f ms', result.elapsed) end
    if result.code then lines[#lines + 1] = 'Exit code: ' .. result.code end
    if result.signal then lines[#lines + 1] = 'Signal: ' .. result.signal end
    if result.message then lines[#lines + 1] = 'Error: ' .. result.message end
    for _, stream in ipairs({ 'stdout', 'stderr' }) do
        lines[#lines + 1] = ''; lines[#lines + 1] = stream .. (result[stream .. '_truncated'] and ' [truncated]' or '')
        vim.list_extend(lines, vim.split(require('nvim_config.coderunner.exec').clean_utf8(result[stream] or ''), '\n', { plain = true }))
    end
    if result.artifacts and #result.artifacts > 0 then
        lines[#lines + 1] = ''; lines[#lines + 1] = 'Artifacts:'
        for _, file in ipairs(result.artifacts) do lines[#lines + 1] = file end
    end
    return lines
end
function M.update(job)
    local view = views[job.id]
    if not view or not api.nvim_buf_is_valid(view.buf) then return end
    vim.bo[view.buf].modifiable = true
    api.nvim_buf_set_lines(view.buf, 0, -1, false, content(job))
    vim.bo[view.buf].modifiable = false
end
function M.close(id)
    local view = views[id]
    if view and view.win and api.nvim_win_is_valid(view.win) then api.nvim_win_close(view.win, true) end
end
function M.release(id)
    M.close(id)
    local view = views[id]
    if view and api.nvim_buf_is_valid(view.buf) then api.nvim_buf_delete(view.buf, { force = true }) end
    views[id] = nil
end
function M.open(job)
    if not job then return nil, 'no result' end
    local view = views[job.id]
    if not view or not api.nvim_buf_is_valid(view.buf) then
        view = { buf = api.nvim_create_buf(false, true) }; views[job.id] = view
        vim.bo[view.buf].bufhidden = 'hide'
        vim.bo[view.buf].filetype = 'coderunner'
        vim.b[view.buf].coderunner_job_id = job.id
        vim.keymap.set('n', 'q', function() M.close(job.id) end, { buffer = view.buf, silent = true })
    end
    if not view.win or not api.nvim_win_is_valid(view.win) then
        local width = math.max(1, math.min(100, vim.o.columns - 4))
        local height = math.max(1, math.min(30, vim.o.lines - 4))
        view.win = api.nvim_open_win(view.buf, true, { relative = 'editor', border = 'rounded',
            width = width, height = height, row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
            col = math.max(0, math.floor((vim.o.columns - width) / 2)), style = 'minimal' })
        vim.wo[view.win].statusline = "%!v:lua.require'nvim_config.coderunner.progress'.status()"
    else api.nvim_set_current_win(view.win) end
    M.update(job)
    return view
end
return M
