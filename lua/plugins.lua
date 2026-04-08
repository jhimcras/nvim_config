local env = require 'env'
local M = {}

local function bootstrap_pckr()
    local pckr_path = vim.fn.stdpath'data' .. '/pckr/pckr.nvim'
    if not vim.uv.fs_stat(pckr_path) then
        vim.fn.system {
            'git',
            'clone',
            '--filter=blob:nonesdfadfasdf',
            'https://github.com/lewis6991/pckr.nvim',
            pckr_path
        }
    end
    vim.opt.rtp:prepend(pckr_path)
end

bootstrap_pckr()

local function LoupeSetting()
    vim.g.LoupeCenterResults = 0
    local ut = require'util'
    ut.nnoremap('n', '<cmd>let v:searchforward=1<cr><Plug>(Loupen)')
    ut.nnoremap('N', '<cmd>let v:searchforward=1<cr><Plug>(LoupeN)')
    -- Apply * mapping after VimEnter so it's never overridden by plugin files
    vim.api.nvim_create_autocmd('VimEnter', { once = true, callback = function()
        ut.nnoremap('*', function()
            local view = vim.fn.winsaveview()
            vim.cmd('keepjumps normal! *')
            vim.fn.winrestview(view)
        end)
    end })
end

local function DirvishSetting()
    local ut, api = require'util', vim.api
    api.nvim_create_autocmd('FileType', {pattern = 'dirvish', callback = function()
        require'util'.nnoremap('gx', ut.ExecFileOnDirvish, {'silent', 'buffer'})
    end})
    ut.nnoremap('_', [[<cmd>execute 'vertical split | Dirvish %'<cr>]])
    vim.g.dirvish_mode = [[:sort ,^.*[\/],]]
end

local function OilSetting()
    local oil = require('oil')

    local sort_state = { key = nil, order = 'asc' }

    local function toggle_sort(key)
        if sort_state.key == key then
            sort_state.order = (sort_state.order == 'asc') and 'desc' or 'asc'
        else
            sort_state.key = key
            sort_state.order = 'asc'
        end
        oil.set_sort { { 'type', 'asc' }, { sort_state.key, sort_state.order } }
    end

    oil.setup {
        columns = { {"mtime", format = "%Y%m%d %T"}, "size", },
        view_options = {
            show_hidden = true,
            case_insensitive = true,
        },
        confirmation = {
            border = "rounded",
        },
        keymaps = {
            ["<C-h>"] = false,
            ["<C-l>"] = false,
            ["gs"] = false,
            ['ss'] = { callback = function() toggle_sort('size')  end },
            ['st'] = { callback = function() toggle_sort('mtime') end },
            ['sn'] = { callback = function() toggle_sort('name')  end },
        },
    }
    vim.keymap.set("n", "-", function() oil.open() end)
    vim.keymap.set("n", "_", function() vim.cmd.vsplit(); oil.open(); end)
end

local function SlimeSetting()
    vim.g.slime_target = 'neovim'
end

local function VsnipSetting()
    -- local ut = require'util'
    vim.g.vsnip_snippet_dir = vim.fn.stdpath('config') .. '/vsnip'
    -- ut.imap('<c-space>', "vsnip#jumpable(1) ? '<Plug>(vsnip-jump-next)' : vsnip#expandable()  ? '<Plug>(vsnip-expand)' : ''", {'expr'})
    -- ut.smap('<c-space>', "vsnip#jumpable(1) ? '<Plug>(vsnip-jump-next)' : vsnip#expandable()  ? '<Plug>(vsnip-expand)' : ''", {'expr'})
    -- ut.imap('<c-bs>', "vsnip#jumpable(-1) ? '<Plug>(vsnip-jump-prev)' : ''", {'expr'})
    -- ut.smap('<c-bs>', "vsnip#jumpable(-1) ? '<Plug>(vsnip-jump-prev)' : ''", {'expr'})

    -- Select or cut text to use as $TM_SELECTED_TEXT in the next snippet.
    -- See https://github.com/hrsh7th/vim-vsnip/pull/50
    -- ut.nmap('<c-cr>', '<Plug>(vsnip-cut-text)', {'expr'})
    -- ut.xmap('<c-cr>', '<Plug>(vsnip-cut-text)', {'expr'})
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
    if vim.g.neovide then
        require'util'.nnoremap('<s-cr>', function() vim.g.neovide_fullscreen = not vim.g.neovide_fullscreen end)
    end
end

local function SetColorsAndHighlighting()
    require('nvim-tundra').setup {
        -- transparent_background = true,
        dim_inactive_windows = {
            enabled = true,
        },
        overwrite = {
            highlights = {
                DiagnosticError = { bold = false },
                DiagnosticWarn = { bold = false },
                DiagnosticInfo = { bold = false },
                DiagnosticHint = { bold = false },
                SpecialKey = { link = '', fg = '#a5b4fc' },
            },
        },
        plugins = {
            -- telescope = true,
            lsp = true,
        },
    }
    vim.cmd.colorscheme 'tundra'

    -- require('catppuccin').setup {
    -- }
    -- vim.cmd.colorscheme 'catppuccin'

    vim.o.pumblend = 10
    -- ut.set_highlight('Pmenu', { ctermbg=238 })
    vim.cmd.let '$TERM="xterm-256color"'
    if not env.os.win then
        vim.o.termguicolors = true
    end
    vim.api.nvim_create_autocmd('TextYankPost', { callback = function()
        vim.hl.on_yank { timeout = 200 }
    end } )
end

local function LspStatusConfig()
    local lsp_setting = require'lsp_setting'
    local lsp_status = require'lsp-status'
    lsp_status.register_progress()
    lsp_status.config {
        indicator_errors = lsp_setting.SymError,
        indicator_warnings = lsp_setting.SymWarn,
        indicator_info = lsp_setting.SymInfo,
        indicator_hint = lsp_setting.SymHint,
        status_symbol = '',
        current_function = true,
    }
end

local function MarkdownConfig()
    require'render-markdown'.setup{
        overrides = {
            buftype = {
                nofile = { enabled = false },
            },
        },
        indent = {
            enabled = true,
            render_modes = true,
            per_level = 4,
            skip_level = 0,
            skip_heading = true,
        },
        heading = {
            icons = { '  ' },
            signs = { ' ' },
            width = 'block',
            border = true,
            left_pad = 2,
            right_pad = 2,
        },
        checkbox = {
            unchecked = { icon = ' ' },
            checked   = { icon = ' ' },
            custom = {
                todo = { raw = '[-]', rendered = ' ', highlight = 'RenderMarkdownTodo', scope_highlight = nil },
            },
        },
        link = {
            image     = ' ',
            email     = ' ',
            hyperlink = ' ',
            wiki      = { icon = ' ' },
            custom = {
                web       = { pattern = '^http',          icon = ' '  },
                github    = { pattern = 'github%.com',    icon = '  ' },
                google    = { pattern = 'google%.com',    icon = '  ' },
                reddit    = { pattern = 'reddit%.com',    icon = '  ' },
                wikipedia = { pattern = 'wikipedia%.org', icon = '  ' },
                youtube   = { pattern = 'youtube%.com',   icon = '󰗃 '  },
            },
        },
    }
end

local function bootstrap_pckr()
    local pckr_path = vim.fn.stdpath("data") .. "/pckr/pckr.nvim"
    if not (vim.uv or vim.loop).fs_stat(pckr_path) then
        vim.fn.system({
            'git', 'clone', '--filter=blob:none',
            'https://github.com/lewis6991/pckr.nvim',
            pckr_path
        })
    end
    vim.opt.rtp:prepend(pckr_path)
end

local function FugitiveSetting()
    local ut = require'util'
    local function gclog_back()
        local bufname = vim.api.nvim_buf_get_name(0)
        if bufname:match('^fugitive://') then
            local real = vim.fn['fugitive#Real'](bufname)
            if real ~= '' then
                vim.cmd('edit ' .. vim.fn.fnameescape(real))
                return
            end
        end
        vim.notify('Not in a fugitive history buffer', vim.log.levels.WARN)
    end
    vim.api.nvim_create_user_command('GclogBack', gclog_back, {})
    ut.nnoremap('<leader>gb', gclog_back)
end

function M.setup()
    bootstrap_pckr()

    local cmd = require'pckr.loader.cmd'
    local keys = require'pckr.loader.keys'

    require'pckr'.add {
        { 'johngrib/vim-f-hangul' },
        { 'kana/vim-textobj-entire' },
        { 'kana/vim-textobj-user' },
        { 'michaeljsmith/vim-indent-object' },
        { 'nvim-lua/lsp-status.nvim', config = LspStatusConfig },
        { 'nvim-treesitter/nvim-treesitter', run = ':TSUpdate', config = function() require'treesitter_setting'.setup() end },
        { 'nvim-treesitter/playground' },
        { 'nvim-treesitter/nvim-treesitter-textobjects' },
        -- { 'plasticboy/vim-markdown', ft = { 'markdown' } },
        -- { 'iamcco/markdown-preview.nvim', ft = { 'markdown' }, run = 'cd app & yarn install' },
        { 'tpope/vim-fugitive', config = FugitiveSetting },
        { 'tpope/vim-surround' },
        -- { 'justinmk/vim-dirvish', config = DirvishSetting },
        { 'stevearc/oil.nvim', config = OilSetting },
        { 'weirongxu/plantuml-previewer.vim', ft = { 'plantuml' }, requires = {'tyru/open-browser.vim', 'aklt/plantuml-syntax'} },
        -- { 'will133/vim-dirdiff' },
        { 'junegunn/gv.vim' },
        { 'wincent/loupe', branch = 'main', config = LoupeSetting },
        -- { 'andymass/vim-matchup', config = MatchupSetting },
        { 'monkoose/matchparen.nvim', config = function() require'matchparen'.setup() end },
        -- { 'rlue/vim-barbaric', disable = not env.os.unix, config = BarbaricSetting },
        -- { 'jpalardy/vim-slime', config = SlimeSetting },
        { 'nvim-telescope/telescope.nvim', requires = 'nvim-lua/plenary.nvim', config = function() require'tele'.setup() end },
        { 'numToStr/Comment.nvim', config = function() require'Comment'.setup() end },
        { 'hrsh7th/vim-vsnip', config = VsnipSetting },
        -- { 'hrsh7th/vim-vsnip' },
        { 'hrsh7th/cmp-vsnip' },
        { 'hrsh7th/cmp-nvim-lsp' },
        { 'hrsh7th/cmp-nvim-lsp-signature-help' },
        { 'hrsh7th/nvim-cmp', config = function() require'complete'.setup() end },
        { 'sam4llis/nvim-tundra', config = SetColorsAndHighlighting },
        -- { 'catppuccin/nvim', config = SetColorsAndHighlighting },

        {
            'MeanderingProgrammer/render-markdown.nvim',
            requires = {'nvim-treesitter/nvim-treesitter'},
            config = MarkdownConfig,
            ft = { 'markdown' },
        },
        { 'norcalli/nvim-colorizer.lua' },

        -- { 'nvim-lualine/lualine.nvim', config = function() require'lualine'.setup{ extensions = {'fugitive'} } end },

        -- { 'kevinhwang91/nvim-bqf', ft='qf' },

        -- { 'folke/trouble.nvim', config = function() require'trouble'.setup() end },

        -- Disabled
        -- { 'mfussenegger/nvim-dap' },
        -- { 'jose-elias-alvarez/null-ls.nvim', config = function() require'null-ls'.setup() end, requires = { 'nvim-lua/plenary.nvim' } },
        -- { 'chrisbra/csv.vim', ft = { 'csv' } },
        -- { 'puremourning/vimspector', disable = not env.os.unix },
        -- { 'glepnir/lspsaga.nvim' },
        -- { 'unblevable/quick-scope' },
        -- { 'arcticicestudio/nord-vim' },
        -- { 'drmikehenry/vim-fontsize' },
        -- { 'ervandew/supertab' },
        -- { 'godlygeek/tabular' },
        -- { 'itchyny/calendar.vim' },
        -- { 'itchyny/vim-cursorword' },
        -- { 'nelstrom/vim-visual-star-search' },
        -- { 'gabrielelana/vim-markdown' },
        -- { 'tpope/vim-vinegar' },
        -- { 'rhysd/clever-f.vim' },
        -- { 'kana/vim-textobj-lastpat' },
        -- { 'wellle/targets.vim' },
        -- { 'vim-pandoc/vim-pandoc-syntax' },
        -- { 'vim-utils/vim-man' },
        -- { 'vim-scripts/utl.vim' },
        -- { 'justinmk/vim-gtfo' },
        -- { 'md-map', { dir=vim.fn.stdpath('config') .. '/plugin/md-map' } },
        -- { 'dstein64/nvim-scrollview' } -- TODO: this plugin has session problem
        -- { 'hrsh7th/vim-vsnip-integ' },
        -- { 'vimwiki/vimwiki' },
        -- { 'jghauser/follow-md-links.nvim' },
        -- { 'lambdalisue/vim-fullscreen' }
    }

    require'prjroot'.setup()
    require'launcher'.setup()
    require'grep'.setup()
    require'session'.setup()
    require'status'.setup()
    require'file_info'.setup()
    require'smart_colorcolumn'.setup(120)
    require'smart_cursorline'.setup()
    require'lsp_setting'.setup()
    -- require'treesitter_setting'.setup()
    -- require'complete'.setup()
    -- require'md'.setup()

    --require'focus_win'.setup{ active='#212121', inactive='#303030' }

    FullscreenSettings()
end

return M
