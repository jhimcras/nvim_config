-- tests/manual/test_process_warnings.lua
local session = require('session')
local launcher = require('launcher')

local function assert_eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format("%s: expected %s, got %s", msg, vim.inspect(expected), vim.inspect(actual)))
    end
end

local function test_get_running_processes()
    print("Running test_get_running_processes...")

    -- 1. Mock a general launcher process
    local dummy_buf_general = vim.api.nvim_create_buf(false, true)
    launcher.running_processes[dummy_buf_general] = {
        type = 'general',
        obj = 'Test General',
        cmd = 'ls',
        buf = dummy_buf_general
    }

    -- 2. Mock an external process
    local dummy_buf_external = vim.api.nvim_create_buf(false, true)
    launcher.running_processes[dummy_buf_external] = {
        type = 'external',
        obj = 'Test External',
        cmd = 'external_cmd',
        buf = dummy_buf_external
    }

    -- 3. Create a dummy terminal buffer (manual)
    local dummy_buf_term = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_call(dummy_buf_term, function()
        vim.fn.termopen('sleep 10')
    end)
    -- The buftype is now 'terminal'
    
    -- Mock vim.fn.jobwait to return -1 (still running)
    local old_jobwait = vim.fn.jobwait
    vim.fn.jobwait = function(ids, timeout)
        if ids[1] == vim.b[dummy_buf_term].terminal_job_id or ids[1] == vim.bo[dummy_buf_term].channel then
            return {-1}
        end
        return old_jobwait(ids, timeout)
    end

    local processes = session.get_running_processes()
    
    -- Restore jobwait
    vim.fn.jobwait = old_jobwait

    -- Verify all are detected
    local found_general = false
    local found_external = false
    local found_term = false

    for _, p in ipairs(processes) do
        if p.obj == 'Test General' then found_general = true end
        if p.obj == 'Test External' then found_external = true end
        if p.type == 'terminal' and p.buf == dummy_buf_term then found_term = true end
    end

    assert_eq(found_general, true, "General launcher not found")
    assert_eq(found_external, true, "External process not found")
    assert_eq(found_term, true, "Manual terminal buffer not found")

    print("test_get_running_processes passed!")

    -- Cleanup
    launcher.running_processes = {}
    vim.api.nvim_buf_delete(dummy_buf_general, {force = true})
    vim.api.nvim_buf_delete(dummy_buf_external, {force = true})
    vim.api.nvim_buf_delete(dummy_buf_term, {force = true})
end

local function test_close_session_warning()
    print("Running test_close_session_warning...")

    -- Mock a running process
    local dummy_buf = vim.api.nvim_create_buf(false, true)
    launcher.running_processes[dummy_buf] = {
        type = 'general',
        obj = 'Test General',
        cmd = 'ls',
        buf = dummy_buf
    }

    -- Mock vim.fn.confirm
    local confirm_called = false
    local old_confirm = vim.fn.confirm
    vim.fn.confirm = function(msg, choices, default)
        confirm_called = true
        if msg:find("Running processes:") and msg:find("Test General") then
            return 2 -- Choose "No" (Cancel)
        end
        return 1
    end

    -- CloseSession should call confirm
    session.CloseSession()

    assert_eq(confirm_called, true, "vim.fn.confirm was not called")

    -- Restore confirm
    vim.fn.confirm = old_confirm

    print("test_close_session_warning passed!")

    -- Cleanup
    launcher.running_processes = {}
    vim.api.nvim_buf_delete(dummy_buf, {force = true})
end

test_get_running_processes()
test_close_session_warning()

print("All tests passed!")
os.exit(0)
