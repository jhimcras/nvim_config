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

    require'pckr'.add {
        { 'johngrib/vim-f-hangul' },
        { 'kana/vim-textobj-entire' },
        { 'kana/vim-textobj-user' },
        { 'michaeljsmith/vim-indent-object' },
        { 'nvim-treesitter/nvim-treesitter', branch = 'master', run = ':TSUpdate', config = require('plugins.treesitter').setup },
        { 'nvim-treesitter/nvim-treesitter-textobjects', branch = 'master' },
        -- { 'plasticboy/vim-markdown', ft = { 'markdown' } },
        -- { 'iamcco/markdown-preview.nvim', ft = { 'markdown' }, run = 'cd app & yarn install' },
        { 'tpope/vim-fugitive', config = require('plugins.misc').setup_fugitive },
        { 'tpope/vim-surround' },
        { 'stevearc/oil.nvim', config = require('plugins.oil').setup },
        { 'weirongxu/plantuml-previewer.vim', cond = event({'FileType'}, {'plantuml'}), requires = {'tyru/open-browser.vim', 'aklt/plantuml-syntax'} },
        -- { 'will133/vim-dirdiff' },
        { 'junegunn/gv.vim' },
        { 'wincent/loupe', branch = 'main', config = require('plugins.misc').setup_loupe },
        { 'monkoose/matchparen.nvim', config = function() require'matchparen'.setup() end },
        { 'nvim-telescope/telescope.nvim', requires = 'nvim-lua/plenary.nvim', config = function() require'tele'.setup() end },
        { 'numToStr/Comment.nvim', config = function() require'Comment'.setup() end },
        { 'hrsh7th/vim-vsnip', config = require('plugins.misc').setup_vsnip },
        { 'hrsh7th/cmp-vsnip' },
        { 'hrsh7th/cmp-nvim-lsp' },
        { 'hrsh7th/cmp-nvim-lsp-signature-help' },
        { 'hrsh7th/nvim-cmp', config = function() require'complete'.setup() end },
        { 'sam4llis/nvim-tundra', config = require('plugins.colorscheme').setup },
        -- { 'catppuccin/nvim', config = SetColorsAndHighlighting },

        {
            'MeanderingProgrammer/render-markdown.nvim',
            requires = {'nvim-treesitter/nvim-treesitter'},
            config = require('plugins.markdown').setup,
            cond = event({'FileType'}, {'markdown'}),
        },
        { 'norcalli/nvim-colorizer.lua' },
    }

    if env.os.unix then
        require'pckr'.add {
            { 'andythigpen/nvim-coverage',
              requires = 'nvim-lua/plenary.nvim',
              config = function()
                  require('coverage').setup({
                      lang = {
                          cpp = { coverage_file = vim.fn.getcwd() .. '/build/coverage.info' },
                          c   = { coverage_file = vim.fn.getcwd() .. '/build/coverage.info' },
                      },
                  })
                  local map = vim.keymap.set
                  map('n', '<leader>cl', '<cmd>CoverageLoad<cr>')
                  map('n', '<leader>cs', '<cmd>CoverageShow<cr>')
                  map('n', '<leader>ch', '<cmd>CoverageHide<cr>')
                  map('n', '<leader>ct', '<cmd>CoverageToggle<cr>')
                  map('n', '<leader>cS', '<cmd>CoverageSummary<cr>')
              end,
            },
        }
    end

end

return M
