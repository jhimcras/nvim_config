-- Manual test for NewInstance command

local function test_new_instance()
    -- 1. Verify command existence
    if vim.fn.exists(':NewInstance') == 0 then
        error('Command :NewInstance does not exist')
    end

    -- 2. Mock vim.fn.jobstart
    local jobstart_called = false
    local jobstart_args = nil
    local jobstart_opts = nil

    local original_jobstart = vim.fn.jobstart
    vim.fn.jobstart = function(args, opts)
        jobstart_called = true
        jobstart_args = args
        jobstart_opts = opts
        return 1 -- dummy job id
    end

    -- Test case 1: No arguments, vim.g.neovide = nil
    vim.g.neovide = nil
    vim.cmd('NewInstance')
    assert(jobstart_called, 'jobstart should be called')
    assert(jobstart_args[1] == 'nvim', 'command should be nvim')
    assert(#jobstart_args == 1, 'should have no extra args')
    assert(jobstart_opts.detach == true, 'detach should be true')

    -- Reset
    jobstart_called = false

    -- Test case 2: With file argument, vim.g.neovide = true
    vim.g.neovide = true
    vim.cmd('NewInstance test.txt')
    assert(jobstart_called, 'jobstart should be called')
    assert(jobstart_args[1] == 'neovide', 'command should be neovide')
    assert(jobstart_args[2] == 'test.txt', 'should have file argument')
    assert(jobstart_opts.detach == true, 'detach should be true')

    -- Restore
    vim.fn.jobstart = original_jobstart
    vim.g.neovide = nil

    print('NewInstance tests passed!')
end

local status, err = pcall(test_new_instance)
if not status then
    print('NewInstance tests failed: ' .. tostring(err))
    os.exit(1)
else
    os.exit(0)
end
