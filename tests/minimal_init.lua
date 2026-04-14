vim.g.is_testing = true
vim.opt.rtp:prepend(vim.fn.getcwd())

-- Dynamically locate plenary.nvim
local data_path = vim.fn.stdpath('data')
-- Check common paths for pckr/packer installations, including the specific Windows path
local potential_paths = {
    data_path .. '/pckr/plenary.nvim',
    data_path .. '/site/pack/packer/start/plenary.nvim',
    data_path .. '/site/pack/pckr/opt/plenary.nvim'
}

local found = false
for _, path in ipairs(potential_paths) do
    if vim.fn.isdirectory(path) == 1 then
        vim.opt.rtp:prepend(path)
        found = true
        break
    end
end

if not found then
    print("WARNING: plenary.nvim not found in searched paths: ")
    for _, path in ipairs(potential_paths) do print(path) end
end

require'status'.setup()
require'launcher'.setup()
require'grep'.setup()
