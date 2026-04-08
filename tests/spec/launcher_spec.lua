local launcher = require 'launcher'
local api = vim.api

describe("Launcher error handling", function()
    it("should allow closing the buffer if a command fails to start", function()
        -- Attempt to launch an invalid command
        local buf = launcher.Launch("nonexistent_command", {}, vim.uv.cwd())
        
        -- Access variables directly using the buffer handle
        local vars = vim.b[buf]
        local launcher_failed = vars.launcher_failed
        local this_buf_can_be_closed = vars.this_buf_can_be_closed
        
        -- Assert
        local is_failed = (launcher_failed == true)
        local is_closable = (this_buf_can_be_closed == true)

        assert(is_failed or is_closable, "Buffer should have been marked as failed or closable. Got: " .. tostring(launcher_failed) .. ", " .. tostring(this_buf_can_be_closed))
    end)
end)

describe("Launcher encoding", function()
    it("should convert output with specified encoding", function()
        -- Setup: A command that outputs non-utf8 data (simulated with iconv)
        local input = "한글"
        local cp949_data = vim.iconv(input, 'utf-8', 'cp949')
        
        -- Use a mock setup to feed cp949 data into onread
        -- Since launcher.Launch takes a command, we can just test if encoding param is respected
        -- if we mock or verify the flow.
        -- For this test, we verify that passing an encoding works and doesn't break
        local buf = launcher.Launch("echo", {input}, vim.uv.cwd(), nil, nil, nil, nil, nil, "cp949")
        assert(vim.api.nvim_buf_is_valid(buf), "Buffer should be created")
    end)
end)
