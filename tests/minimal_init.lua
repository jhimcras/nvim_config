vim.opt.rtp:prepend(vim.fn.getcwd())
vim.opt.rtp:prepend(vim.fn.expand('~/.local/share/nvim/site/pack/packer/start/plenary.nvim'))
require'status'.setup()
