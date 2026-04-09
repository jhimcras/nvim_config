vim.opt.rtp:prepend(vim.fn.getcwd())

-- Dynamically locate plenary.nvim in the standard data directory
local data_path = vim.fn.stdpath('data')
local plenary_path = data_path .. '/pckr/plenary.nvim'
vim.opt.rtp:prepend(plenary_path)

require'status'.setup()
