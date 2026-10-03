-- tests/manual/test_warning_options.lua
local session = require('session')
local launcher = require('launcher')

session.setup()

local function assert_eq(actual, expected, msg)
    if actual ~= expected then
        print("FAILED: " .. msg)
        print("  Expected: " .. vim.inspect(expected))
        print("  Actual:   " .. vim.inspect(actual))
        os.exit(1)
    end
end

local function test_launcher_close_warning()
    print("Testing launcher.CloseLauncherBuffer warning...")
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(0, buf)
    
    -- Mock running process
    launcher.running_processes[buf] = { type = 'general', obj = 'Test Process' }
    
    local confirm_msg, confirm_choices, confirm_default
    local old_confirm = vim.fn.confirm
    vim.fn.confirm = function(msg, choices, default)
        confirm_msg = msg
        confirm_choices = choices
        confirm_default = default
        return 2 -- Cancel
    end
    
    launcher.CloseLauncherBuffer()
    
    assert_eq(confirm_choices, "&Stop and Close Buffer\n&Cancel", "Launcher close choices mismatch")
    assert_eq(confirm_default, 2, "Launcher close default mismatch")
    
    vim.fn.confirm = old_confirm
    launcher.running_processes[buf] = nil
    vim.api.nvim_buf_delete(buf, {force = true})
    print("Launcher close warning test passed!")
end

local function test_session_open_warning()
    print("Testing session.OpenSession warning...")
    
    -- Mock running process via get_running_processes
    local old_grp = session.get_running_processes
    session.get_running_processes = function()
        return {{ type = 'general', obj = 'Test Process' }}
    end
    
    local confirm_msg, confirm_choices, confirm_default
    local old_confirm = vim.fn.confirm
    vim.fn.confirm = function(msg, choices, default)
        confirm_msg = msg
        confirm_choices = choices
        confirm_default = default
        return 2 -- Cancel
    end
    
    session.OpenSession("dummy")
    
    assert_eq(confirm_choices, "&Stop and Open Session\n&Cancel", "Session open choices mismatch")
    assert_eq(confirm_default, 2, "Session open default mismatch")
    
    vim.fn.confirm = old_confirm
    session.get_running_processes = old_grp
    print("Session open warning test passed!")
end

local function test_session_close_warning()
    print("Testing session.CloseSession warning...")
    
    -- Mock running process
    local old_grp = session.get_running_processes
    session.get_running_processes = function()
        return {{ type = 'general', obj = 'Test Process' }}
    end
    
    local confirm_msg, confirm_choices, confirm_default
    local old_confirm = vim.fn.confirm
    vim.fn.confirm = function(msg, choices, default)
        confirm_msg = msg
        confirm_choices = choices
        confirm_default = default
        return 2 -- Cancel
    end
    
    session.CloseSession()
    
    assert_eq(confirm_choices, "&Stop and Close Session\n&Cancel", "Session close choices mismatch")
    assert_eq(confirm_default, 2, "Session close default mismatch")
    
    vim.fn.confirm = old_confirm
    session.get_running_processes = old_grp
    print("Session close warning test passed!")
end

local function test_quit_pre_warning()
    print("Testing QuitPre warning...")
    
    -- The QuitPre callback is anonymous; trigger it via the autocmd.
    
    -- Mock running process
    local old_grp = session.get_running_processes
    session.get_running_processes = function()
        return {{ type = 'general', obj = 'Test Process' }}
    end
    
    local confirm_msg, confirm_choices, confirm_default
    local old_confirm = vim.fn.confirm
    vim.fn.confirm = function(msg, choices, default)
        confirm_msg = msg
        confirm_choices = choices
        confirm_default = default
        return 2 -- Cancel
    end

    -- May throw "Exit cancelled"; propagation to pcall varies by version.
    local status, err = pcall(function()
        vim.api.nvim_exec_autocmds("QuitPre", { group = "ExitGuard" })
    end)
    
    assert_eq(confirm_choices, "&Stop and Quit\n&Cancel", "QuitPre choices mismatch")
    assert_eq(confirm_default, 2, "QuitPre default mismatch")
    
    vim.fn.confirm = old_confirm
    session.get_running_processes = old_grp
    print("QuitPre warning test passed!")
end

-- Run tests
test_launcher_close_warning()
test_session_open_warning()
test_session_close_warning()
test_quit_pre_warning()

print("All standardization tests passed!")
os.exit(0)
