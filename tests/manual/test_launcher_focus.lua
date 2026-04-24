local launcher = require('launcher')
local pr = require('prjroot')

-- Mock prjroot config
local mock_config = {
    launchers = {
        test_focus = {
            cmd = 'echo hello',
            focus = true
        },
        test_no_focus = {
            cmd = 'echo world',
            focus = false
        }
    }
}

pr.GetPrjrootConfig = function() return mock_config end
pr.GetCurrentProjectRoot = function() return "/tmp" end

print("Starting test: test_launcher_focus.lua")

-- Test 1: focus = true
local parent_win_1 = vim.api.nvim_get_current_win()
print("Test 1 (focus=true) - Parent window ID: " .. parent_win_1)
launcher.LaunchObject('test_focus')
local current_win_1 = vim.api.nvim_get_current_win()
print("Test 1 - Current window ID: " .. current_win_1)

if current_win_1 ~= parent_win_1 then
    print("SUCCESS: Focus shifted to launcher window for focus=true")
else
    print("FAILURE: Focus did not shift for focus=true")
    os.exit(1)
end

-- Back to parent
vim.api.nvim_set_current_win(parent_win_1)

-- Test 2: focus = false
print("Test 2 (focus=false) - Parent window ID: " .. parent_win_1)
launcher.LaunchObject('test_no_focus')
local current_win_2 = vim.api.nvim_get_current_win()
print("Test 2 - Current window ID: " .. current_win_2)

if current_win_2 == parent_win_1 then
    print("SUCCESS: Focus remained on parent window for focus=false")
else
    print("FAILURE: Focus shifted for focus=false")
    os.exit(1)
end

print("Test completed successfully")
