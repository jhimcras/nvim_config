
_G.evs = {}
vim.api.nvim_create_autocmd({"QuitPre", "ExitPre"}, {
    callback = function(args)
        table.insert(_G.evs, args.event)
    end
})

vim.schedule(function()
    vim.cmd("split")
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {"modified content"})
    
    local ok, err = pcall(vim.cmd, "q")
    
    local f = io.open("result_mod2_err.txt", "w")
    f:write("Result: " .. tostring(ok) .. ", Error: " .. tostring(err) .. "\n")
    f:write("Events: " .. table.concat(_G.evs, ", ") .. "\n")
    f:close()
    
    vim.cmd("qa!")
end)
