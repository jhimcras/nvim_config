
_G.evs = {}
vim.api.nvim_create_autocmd({"QuitPre", "ExitPre"}, {
    callback = function(args)
        table.insert(_G.evs, args.event)
        vim.schedule(function()
            table.insert(_G.evs, "Scheduled from " .. args.event)
        end)
    end
})

vim.api.nvim_create_autocmd("VimLeave", {
    callback = function()
        local f = io.open("result_timing.txt", "w")
        f:write(table.concat(_G.evs, "\n"))
        f:close()
    end
})

vim.schedule(function()
    vim.cmd("qa")
end)
