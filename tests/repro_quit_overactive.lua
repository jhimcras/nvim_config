local ut = require('util')
local launcher = require('launcher')
local session = require('session')

-- 1. Setup a dummy launcher process
local launcher_buf = ut.NewScratchBuffer('vertical')
vim.api.nvim_buf_set_option(launcher_buf, 'filetype', 'launcher')
vim.api.nvim_buf_set_var(launcher_buf, 'launcher_status', 'running')
vim.api.nvim_buf_set_var(launcher_buf, 'lc_object', 'dummy_task')
launcher.RegisterProcess(launcher_buf, { type = 'general', obj = 'dummy_task', buf = launcher_buf })

-- 2. Create a regular text buffer in a new window
vim.cmd('vsplit')
local text_buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(text_buf, "A.lua")
vim.api.nvim_win_set_buf(0, text_buf)

print("Setup complete. Launcher buf: " .. launcher_buf .. ", Text buf: " .. text_buf)
print("Current buf: " .. vim.api.nvim_get_current_buf())

-- Mock vim.fn.confirm to catch if it's called
local confirm_called = false
vim.fn.confirm = function(msg, choices, default)
    confirm_called = true
    print("WARNING: confirm called! Msg: " .. msg)
    return 2 -- Cancel
end

-- 3. Try to close the text buffer
print("Executing :q (should be silent)")
vim.cmd('q')

if confirm_called then
    print("FAILURE: Warning was triggered for regular buffer close.")
else
    print("SUCCESS: Regular buffer close was silent.")
end

-- 4. Try to close the launcher buffer
print("Executing :q on launcher buffer (should warn)")
vim.api.nvim_set_current_buf(launcher_buf)
confirm_called = false
vim.cmd('q')

if confirm_called then
    print("SUCCESS: Warning was triggered for launcher buffer close.")
else
    print("FAILURE: No warning for launcher buffer close.")
end

vim.cmd('qa!')
