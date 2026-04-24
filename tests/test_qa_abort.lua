
vim.api.nvim_create_autocmd("QuitPre", {
    callback = function()
        print("QuitPre triggered")
        local buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_option(buf, 'modified', true)
        print("Created modified buffer")
    end
})

print("Calling qa")
local ok, err = pcall(vim.cmd, 'qa')
print("qa result:", ok, err)
print("Still alive")
