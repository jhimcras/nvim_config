local timeout_ms = 50000

-- Runs every spec in its own Neovim like plenary.test_harness, but through vim.system, which
-- reports a process only after its output pipes reach EOF. plenary.job shuts a job down on process
-- exit and drops output still in the pipe, so busy parallel runs lost the tail of some specs, and
-- the harness ignored termination signals.
local function run_directory(target)
    local busted = vim.api.nvim_get_runtime_file('lua/plenary/busted.lua', false)[1]
    assert(busted, 'plenary.nvim not found on runtimepath')
    local plenary_dir = vim.fn.fnamemodify(busted, ':h:h:h')
    vim.env.PLENARY_TEST_TIMEOUT = timeout_ms

    local paths = require('plenary.test_harness')._find_files_to_run(target)
    assert(#paths > 0, 'No specs found: ' .. target)
    local jobs = {}
    for _, p in ipairs(paths) do
        local file = p:absolute()
        io.stdout:write('Scheduling: ' .. p.filename .. '\n')
        jobs[#jobs + 1] = {
            file = file,
            proc = vim.system({
                vim.v.progpath, '--headless',
                '-c', 'set rtp+=.,' .. vim.fn.escape(plenary_dir, ' ') .. ' | runtime plugin/plenary.vim',
                '--noplugin', '-u', 'tests/minimal_init.lua',
                '-c', string.format('lua require("plenary.busted").run(%q)', file),
            }, { text = true, timeout = timeout_ms }),
        }
    end

    local failed = {}
    for _, job in ipairs(jobs) do
        local r = job.proc:wait()
        io.stdout:write((r.stderr or ''):gsub('\r', ''), (r.stdout or ''):gsub('\r', ''), '\n')
        if r.code ~= 0 or r.signal ~= 0 then
            failed[#failed + 1] = string.format('%s (code %d, signal %d)', job.file, r.code, r.signal)
        end
    end
    if #failed > 0 then
        error('Failed specs:\n  ' .. table.concat(failed, '\n  '), 0)
    end
end

local ok, err = xpcall(function()
    local target = vim.env.NVIM_TEST_TARGET or 'tests/spec'
    local stat = vim.uv.fs_stat(target)
    assert(stat, 'Test target does not exist: ' .. target)
    if stat.type == 'file' then
        assert(target:match('_spec%.lua$'), 'Expected a *_spec.lua file')
        require('plenary.busted').run(target)
    else
        run_directory(target)
    end
end, debug.traceback)
if not ok then
    io.stderr:write(err .. '\n')
    vim.cmd('cquit 1')
end
