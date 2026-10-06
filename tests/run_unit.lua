local ok, err = xpcall(function()
    local target = vim.env.NVIM_TEST_TARGET or 'tests/spec'
    local stat = vim.uv.fs_stat(target)
    assert(stat, 'Test target does not exist: ' .. target)
    if stat.type == 'file' then
        assert(target:match('_spec%.lua$'), 'Expected a *_spec.lua file')
        require('plenary.busted').run(target)
    else
        local harness = require('plenary.test_harness')
        assert(#harness._find_files_to_run(target) > 0, 'No specs found: ' .. target)
        harness.test_directory(target, { minimal_init = 'tests/minimal_init.lua' })
    end
end, debug.traceback)
if not ok then
    io.stderr:write(err .. '\n')
    vim.cmd('cquit 1')
end
