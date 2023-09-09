local env = require 'env'
local M = {}

local function LoupeSetting()
    local ut = require'util'
    vim.g.LoupeCenterResults = 0
    ut.nmap('*', [[<Plug>(LoupeStar)\|N]])
    ut.nmap('n', '<cmd>let v:searchforward=1<cr><Plug>(Loupen)')
    ut.nmap('N', '<cmd>let v:searchforward=1<cr><Plug>(LoupeN)')
    ut.nmap('<esc>', '<Plug>(LoupeClearHighlight)')
end

local function DirvishSetting()
    local ut, api = require'util', vim.api
    api.nvim_create_autocmd('FileType', {pattern = 'dirvish', callback = function()
        require'util'.nnoremap('gx', ut.ExecFileOnDirvish, {'silent', 'buffer'})
    end})
    ut.nnoremap('_', [[<cmd>execute 'vertical split | Dirvish %'<cr>]])
    vim.g.dirvish_mode = [[:sort ,^.*[\/],]]
end

local function SlimeSetting()
    vim.g.slime_target = 'neovim'
end

local function VsnipSetting()
    local ut = require'util'
    vim.g.vsnip_snippet_dir = vim.fn.stdpath('config') .. '/vsnip'
    ut.imap('<c-space>', "vsnip#jumpable(1) ? '<Plug>(vsnip-jump-next)' : vsnip#expandable()  ? '<Plug>(vsnip-expand)' : ''", {'expr'})
    ut.smap('<c-space>', "vsnip#jumpable(1) ? '<Plug>(vsnip-jump-next)' : vsnip#expandable()  ? '<Plug>(vsnip-expand)' : ''", {'expr'})
    ut.imap('<c-bs>', "vsnip#jumpable(-1) ? '<Plug>(vsnip-jump-prev)' : ''", {'expr'})
    ut.smap('<c-bs>', "vsnip#jumpable(-1) ? '<Plug>(vsnip-jump-prev)' : ''", {'expr'})

    -- Select or cut text to use as $TM_SELECTED_TEXT in the next snippet.
    -- See https://github.com/hrsh7th/vim-vsnip/pull/50
    ut.nmap('<c-cr>', '<Plug>(vsnip-cut-text)', {'expr'})
    ut.xmap('<c-cr>', '<Plug>(vsnip-cut-text)', {'expr'})
end

local function MatchupSetting()
    vim.g.matchup_matchparen_offscreen = {}
    -- ut.set_highlight('MatchParen', { gui='bold', guifg='#ff0000', guibg='NONE' })
end

local function BarbaricSetting()
    vim.g.barbaric_ime = 'fcitx'
    vim.g.barbaric_default = '-c'
    vim.g.barbaric_fcitx_cmd = 'fcitx-remote'
    vim.g.barbaric_scope = 'buffer'
    vim.g.barbaric_timeout = -1
end

local function FullscreenSettings()
    vim.g['fullscreen#start_command'] = "call rpcnotify(0, 'Gui', 'WindowFullScreen', 1)"
    vim.g['fullscreen#stop_command'] = "call rpcnotify(0, 'Gui', 'WindowFullScreen', 0)"
    vim.g['fullscreen#enable_default_keymap'] = 0
    require'util'.nnoremap('<F11>', vim.cmd.FullscreenToggle)
end

local function load_plugins(use)
    use { 'wbthomason/packer.nvim' }
    use { 'johngrib/vim-f-hangul' }
    use { 'kana/vim-textobj-entire' }
    use { 'kana/vim-textobj-user' }
    use { 'michaeljsmith/vim-indent-object' }
    use { 'lambdalisue/vim-fullscreen', config = FullscreenSettings }
    use { 'neovim/nvim-lsp' }
    use { 'nvim-lua/lsp-status.nvim' }
    use { 'nvim-treesitter/nvim-treesitter', run = ':TSUpdate' }
    use { 'nvim-treesitter/playground' }
    use { 'nvim-treesitter/nvim-treesitter-textobjects' }
    use { 'plasticboy/vim-markdown', ft = { 'markdown' } }
    use { 'iamcco/markdown-preview.nvim', ft = { 'markdown' }, run = 'cd app & yarn install' }
    use { 'tpope/vim-fugitive' }
    use { 'tpope/vim-surround' }
    use { 'justinmk/vim-dirvish', config = DirvishSetting }
    use { 'weirongxu/plantuml-previewer.vim', ft = { 'plantuml' } }
    use { 'aklt/plantuml-syntax', ft = { 'plantuml' } }
    use { 'will133/vim-dirdiff' }
    use { 'norcalli/nvim-colorizer.lua' }
    use { 'junegunn/gv.vim' }
    use { 'wincent/loupe', branch = 'main', config = LoupeSetting }
    use { 'andymass/vim-matchup', config = MatchupSetting }
    use { 'hrsh7th/vim-vsnip', config = VsnipSetting }
    use { 'rlue/vim-barbaric', disable = not env.os.unix, config = BarbaricSetting }
    use { 'jpalardy/vim-slime', config = SlimeSetting }
    use { 'tyru/open-browser.vim' }
    use { 'nvim-telescope/telescope.nvim', requires = 'nvim-lua/plenary.nvim' }
    use { 'numToStr/Comment.nvim', config = function() require'Comment'.setup() end }
    use { 'hrsh7th/cmp-nvim-lsp' }
    use { 'hrsh7th/cmp-nvim-lsp-signature-help' }
    use { 'hrsh7th/nvim-cmp' }
    use { 'sam4llis/nvim-tundra' }
    -- use { 'jghauser/follow-md-links.nvim' }

    -- Disabled
    -- use { 'mfussenegger/nvim-dap' }
    -- use { 'jose-elias-alvarez/null-ls.nvim', config = function() require'null-ls'.setup() end, requires = { 'nvim-lua/plenary.nvim' } }
    -- use { 'chrisbra/csv.vim', ft = { 'csv' } }
    -- use { 'puremourning/vimspector', disable = not env.os.unix }
    -- use { 'glepnir/lspsaga.nvim' }
    -- use { 'unblevable/quick-scope' }
    -- use { 'arcticicestudio/nord-vim' }
    -- use { 'drmikehenry/vim-fontsize' }
    -- use { 'ervandew/supertab' }
    -- use { 'godlygeek/tabular' }
    -- use { 'itchyny/calendar.vim' }
    -- use { 'itchyny/vim-cursorword' }
    -- use { 'nelstrom/vim-visual-star-search' }
    -- use { 'gabrielelana/vim-markdown' }
    -- use { 'tpope/vim-vinegar' }
    -- use { 'rhysd/clever-f.vim' }
    -- use { 'kana/vim-textobj-lastpat' }
    -- use { 'wellle/targets.vim' }
    -- use { 'vim-pandoc/vim-pandoc-syntax' }
    -- use { 'vim-utils/vim-man' }
    -- use { 'vim-scripts/utl.vim' }
    -- use { 'justinmk/vim-gtfo' }
    -- use { 'md-map', { dir=vim.fn.stdpath('config') .. '/plugin/md-map' } }
    -- use { 'dstein64/nvim-scrollview' } -- TODO: this plugin has session problem
    -- use { 'hrsh7th/vim-vsnip-integ' }
    -- use { 'vimwiki/vimwiki' }
end

function M.setup()
    -- local install_path = vim.fn.stdpath('data') .. '/site/pack/packer/start/packer.nvim'
    -- if vim.fn.empty(vim.fn.glob(install_path)) > 0 then
    --     vim.fn.system({ 'git', 'clone', 'https://github.com/wbthomason/packer.nvim', install_path })
    -- end
    -- vim.api.nvim_create_autocmd('BufWritePost', { pattern = 'plugins.lua', command = 'PackerCompile' })

    vim.cmd 'packadd packer.nvim'
    require'packer'.startup(load_plugins)
    require'prjroot'.setup()
    require'launcher'.setup()
    require'grep'.setup()
    require'session'.setup()
    require'status'.setup()
    require'smart_colorcolumn'.setup(120)
    require'smart_cursorline'.setup()
    require'lsp_setting'.setup()
    require'treesitter_setting'.setup()
    require'complete'.setup()
    require'tele'.setup()
    require'md'.setup()
    --require'focus_win'.setup{ active='#212121', inactive='#303030' }
end

return M
