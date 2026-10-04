-- Run with the real init.lua and NVIM_LAZY_TEST set to a case below.
local plugins = require('pckr.plugin').plugins_by_name
local function loaded(name)
    return plugins[name].loaded == true
end

for _, name in ipairs {
    'telescope.nvim', 'nvim-cmp', 'vim-vsnip', 'cmp-vsnip',
    'cmp-nvim-lsp', 'cmp-nvim-lsp-signature-help', 'vim-fugitive', 'gv.vim',
} do
    assert(not loaded(name), name .. ' loaded at startup')
end
assert(not package.loaded['plugins.tele'], 'Telescope config loaded at startup')
assert(not package.loaded['cmp'], 'cmp loaded at startup')

local case = vim.env.NVIM_LAZY_TEST
if case == 'telescope-key' then
    local mapping = vim.fn.maparg('<leader>fb', 'n', false, true)
    mapping.callback()
    assert(loaded('telescope.nvim'))
    assert(vim.bo.filetype == 'TelescopePrompt')
elseif case == 'telescope-command' then
    vim.cmd('Telescope buffers')
    assert(loaded('telescope.nvim'))
    assert(vim.bo.filetype == 'TelescopePrompt')
elseif case == 'config' then
    vim.cmd('Config init')
    assert(loaded('telescope.nvim'))
    assert(vim.bo.filetype == 'TelescopePrompt')
elseif case == 'insert' then
    local get_clients = vim.lsp.get_clients
    local client = {
        id = 9999, name = 'lazy-test', server_capabilities = { completionProvider = {} }, attached_buffers = { [vim.api.nvim_get_current_buf()] = true },
        is_stopped = function() return false end,
        supports_method = function() return true end,
    }
    vim.lsp.get_clients = function() return { client } end
    vim.api.nvim_exec_autocmds('InsertEnter', {})
    vim.lsp.get_clients = get_clients
    for _, name in ipairs {
        'nvim-cmp', 'vim-vsnip', 'cmp-vsnip', 'cmp-nvim-lsp', 'cmp-nvim-lsp-signature-help',
    } do
        assert(loaded(name), name .. ' did not load on InsertEnter')
    end
    local cmp = require('cmp')
    for _, name in ipairs { 'vsnip', 'nvim_lsp', 'nvim_lsp_signature_help', 'markdown_image' } do
        local found = false
        for _, source in pairs(cmp.core.sources) do
            if source.name == name then found = true end
        end
        assert(found, name .. ' source not registered')
    end
elseif case == 'git' then
    vim.cmd('Git')
    assert(loaded('vim-fugitive'))
    assert(vim.bo.filetype == 'fugitive')
    assert(vim.wo.winfixheight)
elseif case == 'gv' then
    vim.cmd('GV')
    assert(loaded('gv.vim'))
    assert(loaded('vim-fugitive'))
elseif case == 'coverage' then
    assert(not loaded('nvim-coverage'))
    local mapping = vim.fn.maparg('<leader>ch', 'n', false, true)
    assert(mapping.rhs:lower() == '<cmd>coveragehide<cr>')
    vim.cmd('CoverageHide')
    assert(loaded('nvim-coverage'))
else
    error('Unknown NVIM_LAZY_TEST case: ' .. tostring(case))
end
print('PASS: ' .. case)
