local M = {}
local spinner = require('nvim_config.spinner')
local frames = { '⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏' }
local active = {}
function M.start(job)
    active[job.id] = spinner.start({ buf = job.buf })
    vim.notify('coderunner: started #' .. job.id)
end
function M.stop(job)
    spinner.stop(active[job.id]); active[job.id] = nil
    vim.notify('coderunner: #' .. job.id .. ' ' .. job.status)
end
function M.status()
    local count = vim.tbl_count(active)
    if count == 0 then return '' end
    return frames[math.floor(vim.uv.hrtime() / 120000000) % #frames + 1] .. ' Code ' .. count
end
return M
