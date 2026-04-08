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
