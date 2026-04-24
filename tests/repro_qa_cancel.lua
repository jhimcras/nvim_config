
local session = require('lua.session')
session.setup()

-- Create multiple buffers
vim.cmd('edit buf1')
vim.cmd('edit buf2')

-- Mock get_running_processes to return a dummy process
session.get_running_processes = function()
    return {{ cmd = "dummy", key = 1 }}
end

-- Mock vim.fn.confirm to return 2 (Cancel)
vim.fn.confirm = function(msg, choices, default)
    print("MOCK CONFIRM: " .. msg)
    return 2 -- Cancel
end

-- Use a file to signal that we are still alive
local alive_file = "tests/alive.txt"
vim.fn.writefile({"ALIVE"}, alive_file)

print("Attempting vim.cmd('qa')...")
local ok, err = pcall(vim.cmd, 'qa')
print("vim.cmd('qa') returned: ", ok, err)

-- If we are still alive, this will be executed
vim.fn.writefile({"STILL ALIVE after :qa pcall"}, alive_file, "a")
print("FINISHED SCRIPT")
