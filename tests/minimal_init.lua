vim.opt.rtp:prepend(vim.fn.getcwd())

-- Dynamically locate plenary.nvim
local data_path = vim.fn.stdpath('data')
-- Check common paths for pckr/packer installations
local potential_paths = {
    data_path .. '/pckr/plenary.nvim',
    data_path .. '/site/pack/packer/start/plenary.nvim'
}

for _, path in ipairs(potential_paths) do
    if vim.fn.isdirectory(path) == 1 then
        vim.opt.rtp:prepend(path)
        break
    end
end

require'status'.setup()
