local function test_status_column()
    -- Create a new buffer
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    
    -- Set tabstop to 8
    vim.bo[bufnr].tabstop = 8
    vim.bo[bufnr].expandtab = false
    
    -- Set content: two tabs followed by "Hello"
    -- \t (8) + \t (8) = 16. Cursor at "H" should be at virtual column 17.
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "\t\tHello" })
    
    -- Position cursor at the 'H' (index 2, 0-indexed)
    -- Byte index 0: \t, 1: \t, 2: H
    vim.api.nvim_win_set_cursor(0, { 1, 2 })
    
    -- Expected:
    -- Byte column (%c) = 3 (1-indexed)
    -- Virtual column (%v) = 17 (1-indexed)
    
    local statusline_v = vim.api.nvim_eval_statusline("%v", { winid = 0 })
    local statusline_c = vim.api.nvim_eval_statusline("%c", { winid = 0 })
    
    print("Byte column (%c): " .. statusline_c.str)
    print("Virtual column (%v): " .. statusline_v.str)
    
    if statusline_v.str == "17" then
        print("Test Passed: %v correctly reports 17")
    else
        print("Test Failed: %v reports " .. statusline_v.str .. " (expected 17)")
    end

    -- Now test the actual statusline components from lua/status.lua
    local status = require('status')
    -- We need to mock some things or just test if we can find %v in the generated statusline
    
    -- Set up statusline to use the entry function
    vim.o.statusline = "%!v:lua.require'status'.statusline_entry()"
    
    -- Wait a bit for statusline to update or force redraw
    vim.cmd('redrawstatus')
    
    local full_statusline = vim.api.nvim_eval_statusline(vim.o.statusline, { winid = 0 })
    print("Full statusline: " .. full_statusline.str)
    
    if full_statusline.str:find("17") then
        print("Test Passed: Virtual column 17 found in statusline")
    else
        print("Test Failed: Virtual column 17 NOT found in statusline")
    end
end

test_status_column()
