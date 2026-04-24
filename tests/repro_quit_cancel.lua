
local session = require('lua.session')

-- Mock vim.fn.confirm
local confirm_val = 2 -- Default to Cancel
vim.fn.confirm = function(msg, choices, default)
    print("MOCK confirm called with msg: " .. msg)
    return confirm_val
end

-- Mock processes
local processes_killed = false
local mock_process = {
    obj = "MockProcess",
    terminate = function() 
        print("MOCK terminate called")
        processes_killed = true 
    end
}

-- Monkey patch get_running_processes to return our mock
local original_get_running_processes = session.get_running_processes
session.get_running_processes = function()
    return { mock_process }
end

-- Mock nvim_list_bufs to return empty
vim.api.nvim_list_bufs = function() return {} end

-- We need to trigger the QuitPre autocmd.
-- Since we can't easily trigger a real quit and catch it in this script without exiting,
-- we'll manually call the callback if we can find it, or just simulate the quit.

local quit_pre_cb = nil
local autocmds = vim.api.nvim_get_autocmds({ event = "QuitPre" })
for _, au in ipairs(autocmds) do
    if au.group_name == "ExitGuard" then
        quit_pre_cb = au.callback
    end
end

if not quit_pre_cb then
    print("QuitPre callback not found! Setup might not have run.")
    session.setup()
    autocmds = vim.api.nvim_get_autocmds({ event = "QuitPre" })
    for _, au in ipairs(autocmds) do
        if au.group_name == "ExitGuard" then
            quit_pre_cb = au.callback
        end
    end
end

-- Mock nvim_feedkeys
local feedkeys_called = false
vim.api.nvim_feedkeys = function(keys, mode, escape)
    print("MOCK nvim_feedkeys called with: " .. keys)
    feedkeys_called = true
end
vim.api.nvim_replace_termcodes = function(str, ...) return str end

if quit_pre_cb then
    print("Testing Cancel...")
    confirm_val = 2
    feedkeys_called = false
    local ok, err = pcall(quit_pre_cb)
    print("Cancel ok:", ok, "err:", err)
    print("Feedkeys called:", feedkeys_called)
    
    print("Testing Stop and Quit...")
    confirm_val = 1
    processes_killed = false
    ok, err = pcall(quit_pre_cb)
    print("Stop and Quit ok:", ok, "err:", err)
    print("Processes killed:", processes_killed)
else
    print("Failed to find QuitPre callback")
end
