local launcher = require('launcher')
local pr = require('prjroot')
local ut = require('util')

-- Mock project root configuration
local mock_prjroot = vim.fn.getcwd()
pr.GetPrjrootConfig = function(p)
    if p == mock_prjroot then
        return {
            launchers = {
                test_proc = {
                    cmd = 'bash',
                    args = { '-c', 'for i in {1..5}; do echo "P1-$i"; sleep 0.1; done' },
                    mode = 'general'
                }
            }
        }
    end
    return {}
end
pr.GetCurrentProjectRoot = function() return mock_prjroot end

-- Override confirm to always say yes
local original_confirm = vim.fn.confirm
vim.fn.confirm = function() return 1 end

local function wait_for(condition, timeout_ms)
    local start = vim.uv.now()
    while not condition() do
        if vim.uv.now() - start > timeout_ms then
            return false
        end
        vim.cmd('sleep 10ms')
    end
    return true
end

-- Start first process
print("Starting Process 1...")
launcher.LaunchObject('test_proc')
local buf = vim.api.nvim_get_current_buf()

-- Wait for some output from P1
wait_for(function()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    for _, line in ipairs(lines) do
        if line:match('P1-1') then return true end
    end
    return false
end, 1000)

print("Process 1 started and produced output. Starting Process 2 (replacing)...")

-- Redefine test_proc to be Process 2
pr.GetPrjrootConfig = function(p)
    if p == mock_prjroot then
        return {
            launchers = {
                test_proc = {
                    cmd = 'bash',
                    args = { '-c', 'for i in {1..5}; do echo "P2-$i"; sleep 0.1; done' },
                    mode = 'general'
                }
            }
        }
    end
    return {}
end

launcher.LaunchObject('test_proc')

-- Wait for some output from P2
wait_for(function()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    for _, line in ipairs(lines) do
        if line:match('P2-1') then return true end
    end
    return false
end, 1000)

-- Wait for P2 to finish
wait_for(function()
    local success, status = pcall(vim.api.nvim_buf_get_var, buf, 'launcher_status')
    return success and status == 'done'
end, 2000)

print("Process 2 finished. Checking for P1 output in buffer...")

local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
local has_p1_late_output = false
-- Skip the early P1-1 which we know is there
for i, line in ipairs(lines) do
    if line:match('P1-[2-5]') then
        has_p1_late_output = true
        print("Found unexpected P1 output: " .. line)
    end
end

if has_p1_late_output then
    print("FAILURE: Old process output detected in buffer!")
    os.exit(1)
else
    print("SUCCESS: Only new process output detected.")
    os.exit(0)
end

vim.fn.confirm = original_confirm
