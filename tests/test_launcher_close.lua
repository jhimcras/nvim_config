
local launcher = require('launcher')
launcher.setup()
require('session').setup() -- Ensure session's QuitPre is active

-- Mock AsyncProcess to keep it running
local ut = require('util')
local original_async = ut.AsyncProcess
ut.AsyncProcess = function(cmd, args, cwd, opts)
    local terminate_fn = function()
        print("Process terminated")
    end
    return 12345, terminate_fn, function() return "running" end, { is_closing = function() return false end, kill = function() end }
end

-- Create a launcher buffer
local buf = launcher.Launch('sleep', {'100'}, '.', nil, nil, { orientation = 'vertical' }, 'use', nil, nil, 'test_proc')

-- Mock confirm
local confirm_called = false
local original_confirm = vim.fn.confirm
vim.fn.confirm = function(msg, choices, default)
    confirm_called = true
    print("Confirm called with message:", msg)
    return 2 -- Cancel
end

print("\n--- Testing :q behavior (should hide WITHOUT asking) ---")
vim.api.nvim_set_current_buf(buf)
confirm_called = false

-- Open another window so :q doesn't exit Nvim
vim.cmd('split')
vim.api.nvim_set_current_buf(buf)

-- Trigger :q
vim.cmd('quit')

if confirm_called then
    print("Bug 1 NOT Fixed: confirm() was called on :q.")
else
    print("Bug 1 Fixed: confirm() was NOT called on :q. Buffer should be hidden.")
    local wins = vim.fn.win_findbuf(buf)
    print("Visible in windows:", #wins)
end

print("\n--- Testing gq behavior (SHOULD ask) ---")
-- Focus the buffer again in a window
vim.cmd('vsplit')
vim.api.nvim_set_current_buf(buf)
confirm_called = false

-- Simulate gq mapping which calls CloseLauncherBuffer(true)
launcher.CloseLauncherBuffer(true)

if confirm_called then
    print("Bug 1 (gq) Fixed: confirm() was called on gq.")
else
    print("Bug 1 (gq) NOT Fixed: confirm() was NOT called on gq.")
end

print("\n--- Testing :bw abbreviation expansion ---")
vim.api.nvim_set_current_buf(buf)
-- We check if the abbreviation expands correctly using feedkeys or just checking the expr
local expanded = vim.fn.execute('verbose cnoreabbrev bw')
print("Abbreviation for bw:", expanded)

-- Manual call test for Bug 2 logic
print("\n--- Testing :bw logic (SHOULD ask) ---")
confirm_called = false
launcher.CloseLauncherBuffer(true)

if confirm_called then
    print("Bug 2 Fixed: confirm() was called when simulating :bw.")
else
    print("Bug 2 NOT Fixed: confirm() was NOT called.")
end

-- Cleanup to avoid hang on exit
print("\n--- Cleaning up and exiting ---")
launcher.UnregisterProcess(buf)
vim.fn.confirm = original_confirm
ut.AsyncProcess = original_async

-- Force exit to prevent hang in headless mode
vim.schedule(function()
    os.exit(0)
end)
