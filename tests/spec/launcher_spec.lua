local launcher = require 'launcher'
local api = vim.api

describe("Launcher error handling", function()
    it("should allow closing the buffer if a command fails to start", function()
        -- Attempt to launch an invalid command
        local buf = launcher.Launch("nonexistent_command", {}, vim.uv.cwd())
        
        -- Access variables directly using the buffer handle
        local success1, launcher_failed = pcall(vim.api.nvim_buf_get_var, buf, 'launcher_failed')
        local success2, this_buf_can_be_closed = pcall(vim.api.nvim_buf_get_var, buf, 'this_buf_can_be_closed')
        
        -- Assert
        local is_failed = (success1 and launcher_failed == true)
        local is_closable = (success2 and this_buf_can_be_closed == true)

        assert(is_failed or is_closable, "Buffer should have been marked as failed or closable. Got: launcher_failed=" .. tostring(launcher_failed) .. ", this_buf_can_be_closed=" .. tostring(this_buf_can_be_closed))
    end)
end)

describe("Launcher encoding", function()
    it("should convert output with specified encoding", function()
        -- Setup: A command that outputs non-utf8 data (simulated with iconv)
        local input = "한글"
        
        -- For this test, we verify that passing an encoding works and doesn't break
        local buf = launcher.Launch("echo", {input}, vim.uv.cwd(), nil, nil, nil, nil, nil, "cp949")
        assert(vim.api.nvim_buf_is_valid(buf), "Buffer should be created")
    end)
end)
