
local results = {}

vim.api.nvim_create_autocmd({"QuitPre", "ExitPre", "VimLeavePre"}, {
    callback = function(args)
        table.insert(results, string.format("Event: %s, exiting: %s, bufnr: %d, bufname: %s", 
            args.event, tostring(vim.v.exiting), vim.api.nvim_get_current_buf(), vim.api.nvim_buf_get_name(0)))
    end
})

-- We'll use schedule to run commands and then quit to see the results
vim.schedule(function()
    -- Test :q on a buffer
    -- We need to run this in a way that we can capture the output.
    -- Maybe just print to a file.
end)

function _G.dump_results()
    local f = io.open("exit_test_results.txt", "w")
    for _, r in ipairs(results) do
        f:write(r .. "\n")
    end
    f:close()
end
