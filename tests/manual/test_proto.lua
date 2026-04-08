local bufnr = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(bufnr, "fugitive:///home/ilmoek/workspace/nvim_config/.git//0/init.lua")
local protocol = require("util").GetBufferProtocol(bufnr)
print("Protocol: " .. (protocol or "nil"))
