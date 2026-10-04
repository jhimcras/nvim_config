local env = require 'env'
local M = {}
local function bootstrap_pckr()
    local pckr_path = vim.fn.stdpath("data") .. "/pckr/pckr.nvim"
    if not vim.uv.fs_stat(pckr_path) then
        vim.fn.system({
            'git', 'clone', '--filter=blob:none',
            'https://github.com/lewis6991/pckr.nvim',
            pckr_path
        })
    end
    vim.opt.rtp:prepend(pckr_path)
end
function M.setup()
    bootstrap_pckr()

    local event = require'pckr.loader.event'
    local command = require'pckr.loader.cmd'
    local function commands(names)
        local conditions = {}
        for _, name in ipairs(names) do
            conditions[#conditions + 1] = command(name)
        end
        return conditions
    end

    require'pckr'.add {
        { 'johngrib/vim-f-hangul' },
        { 'kana/vim-textobj-entire' },
        { 'kana/vim-textobj-user' },
        { 'michaeljsmith/vim-indent-object' },
        { 'nvim-treesitter/nvim-treesitter', branch = 'master', run = ':TSUpdate', config = require('plugins.treesitter').setup },
        { 'nvim-treesitter/nvim-treesitter-textobjects', branch = 'master' },
        -- { 'plasticboy/vim-markdown', ft = { 'markdown' } },
        -- { 'iamcco/markdown-preview.nvim', ft = { 'markdown' }, run = 'cd app & yarn install' },
        { 'tpope/vim-fugitive', cond = commands {
            'G', 'Git', 'Gcd', 'Glcd', 'Ggrep', 'Glgrep', 'Gclog', 'GcLog', 'Gllog', 'GlLog',
            'Ge', 'Gedit', 'Gpedit', 'Gsplit', 'Gvsplit', 'Gtabedit', 'Gdrop', 'Gr', 'Gread',
            'Gdiffsplit', 'Ghdiffsplit', 'Gvdiffsplit', 'Gw', 'Gwrite', 'Gwq',
            'GRemove', 'GUnlink', 'GDelete', 'GMove', 'GRename', 'GBrowse',
        }, config = require('plugins.misc').setup_fugitive },
        { 'tpope/vim-surround' },
        { 'stevearc/oil.nvim', config = require('plugins.oil').setup },
        { 'weirongxu/plantuml-previewer.vim', cond = event({'FileType'}, {'plantuml'}), requires = {'tyru/open-browser.vim', 'aklt/plantuml-syntax'} },
        -- { 'will133/vim-dirdiff' },
        { 'junegunn/gv.vim', cond = command('GV'), requires = 'tpope/vim-fugitive' },
        { 'wincent/loupe', branch = 'main', config = require('plugins.misc').setup_loupe },
        { 'monkoose/matchparen.nvim', config = function() require'matchparen'.setup() end },
        { 'nvim-telescope/telescope.nvim', cond = {
            function(loader) M.load_telescope = loader end,
            command('Telescope'),
        }, requires = 'nvim-lua/plenary.nvim', config = function() require'plugins.tele'.setup() end },
        { 'numToStr/Comment.nvim', config = function() require'Comment'.setup() end },
        { 'hrsh7th/nvim-cmp', cond = event('InsertEnter'), requires = {
            { 'hrsh7th/vim-vsnip', config = require('plugins.misc').setup_vsnip },
            'hrsh7th/cmp-vsnip',
            'hrsh7th/cmp-nvim-lsp',
            'hrsh7th/cmp-nvim-lsp-signature-help',
        }, config = function()
            require'plugins.complete'.setup()
            -- These handlers were registered during this first InsertEnter.
            vim.api.nvim_exec_autocmds('InsertEnter', { group = 'cmp_nvim_lsp' })
            vim.api.nvim_exec_autocmds('InsertEnter', { group = require('cmp.utils.autocmd').group })
        end },
        { 'sam4llis/nvim-tundra', config = require('plugins.colorscheme').setup },
        -- { 'catppuccin/nvim', config = SetColorsAndHighlighting },

        { 'norcalli/nvim-colorizer.lua' },
    }

    if env.os.unix then
        local map = vim.keymap.set
        map('n', '<leader>cl', '<cmd>CoverageLoad<cr>')
        map('n', '<leader>cs', '<cmd>CoverageShow<cr>')
        map('n', '<leader>ch', '<cmd>CoverageHide<cr>')
        map('n', '<leader>ct', '<cmd>CoverageToggle<cr>')
        map('n', '<leader>cS', '<cmd>CoverageSummary<cr>')
        require'pckr'.add {
            { 'andythigpen/nvim-coverage',
              cond = commands {
                  'Coverage', 'CoverageLoad', 'CoverageLoadLcov', 'CoverageShow',
                  'CoverageHide', 'CoverageToggle', 'CoverageClear', 'CoverageSummary',
              },
              requires = 'nvim-lua/plenary.nvim',
              config = function()
                  require('coverage').setup({
                      lang = {
                          cpp = { coverage_file = vim.fn.getcwd() .. '/build/coverage.info' },
                          c   = { coverage_file = vim.fn.getcwd() .. '/build/coverage.info' },
                      },
                  })
              end,
            },
        }
    end

end

return M
