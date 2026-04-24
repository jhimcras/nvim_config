
_G.evs = {}
vim.api.nvim_create_autocmd({"QuitPre", "ExitPre", "VimLeavePre"}, {
    callback = function(args)
        table.insert(_G.evs, args.event .. " (exiting=" .. tostring(vim.v.exiting) .. ") buf=" .. vim.api.nvim_get_current_buf())
    end
})

vim.api.nvim_create_autocmd("VimLeave", {
    callback = function()
        local test_type = os.getenv("TEST_TYPE")
        local f = io.open("result_" .. (test_type or "none") .. ".txt", "w")
        f:write(table.concat(_G.evs, "\n"))
        f:close()
    end
})

local test_type = os.getenv("TEST_TYPE")
vim.schedule(function()
    if test_type == "qa3" then
        vim.cmd("split")
        vim.cmd("split")
        vim.cmd("qa")
    end
end)
