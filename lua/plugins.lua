local env = require 'env'
local M = {}

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
    vim.g.vsnip_snippet_dir = vim.fn.stdpath('config') .. '/vsnip'
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

local function MarkdownConfig()
    require'render-markdown'.setup{
        overrides = {
            buftype = {
                nofile = { enabled = false },
            },
        },
        indent = {
            enabled = false,
            render_modes = true,
            per_level = 4,
            skip_level = 0,
            skip_heading = true,
        },
        heading = {
            icons = { '  ' },
            signs = { ' ' },
            width = 'block',
            -- border = true,
            -- left_pad = 2,
            -- right_pad = 2,
        },
        checkbox = {
            unchecked = { icon = ' ' },
            checked   = { icon = ' ' },
            custom = {
                todo = { raw = '[-]', rendered = ' ', highlight = 'RenderMarkdownTodo', scope_highlight = nil },
            },
        },
        link = {
            image     = '',
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
        code = {
            language = true,
            position = 'right',
            width = 'block',
            left_pad = 1,
            right_pad = 1,
            min_width = 50,
            border = 'thin',
            disable = { 'plantuml', 'puml', 'uml' },
        },
        -- Tables are rendered by lua/wrap.lua (wrapped cells + proportional widths).
        pipe_table = { enabled = false },
    }
end

local function TreesitterConfig()
    require'nvim-treesitter.configs'.setup{
        ensure_installed = {
            'bash', 'c', 'cpp', 'lua', 'vim', 'vimdoc', 'query',
            'markdown', 'markdown_inline',
            'javascript', 'typescript', 'json', 'python', 'rust', 'regex',
        },
        highlight = { enable = true },
        textobjects = {
            select = {
                enable = true,
                lookahead = true,
                keymaps = {
                    ['af'] = '@function.outer',  ['if'] = '@function.inner',
                    ['ac'] = '@class.outer',     ['ic'] = '@class.inner',
                    ['a,'] = '@parameter.outer', ['i,'] = '@parameter.inner',
                },
            },
            move = {
                enable = true,
                set_jumps = true,
                goto_next_start     = { [']m'] = '@function.outer', [']]'] = '@class.outer' },
                goto_next_end       = { [']M'] = '@function.outer', ['][']  = '@class.outer' },
                goto_previous_start = { ['[m'] = '@function.outer', ['[['] = '@class.outer' },
                goto_previous_end   = { ['[M'] = '@function.outer', ['[]']  = '@class.outer' },
            },
            swap = {
                enable = true,
                swap_next     = { ['>,'] = '@parameter.inner' },
                swap_previous = { ['<,'] = '@parameter.inner' },
            },
        },
    }

    if vim.fn.has('nvim-0.12') == 1 then
        -- Neovim 0.12 removed the `all` option from Query:iter_matches(), which
        -- now always returns TSNode[] per capture instead of a single TSNode
        -- (core's own highlighter/injection code was updated for this; third-
        -- party nvim-treesitter wasn't). nvim-treesitter's textobjects
        -- machinery (select/move/swap) stores those raw capture values into
        -- `prepared_match` and downstream code (tsrange.from_nodes,
        -- move.lua's filter_predicate/scoring_function, etc.) still calls
        -- TSNode methods like :start()/:range() directly on them, crashing
        -- with e.g. "attempt to call method 'start' (a nil value)" as soon as
        -- [m/]m or af/if/etc. hits a query match. Reimplement
        -- iter_prepared_matches with capture values unwrapped to a single
        -- node (last one, matching the old all=false semantics) so every
        -- consumer gets a plain TSNode again.
        local nt_query = require'nvim-treesitter.query'
        local tsrange = require'nvim-treesitter.tsrange'
        local function last_node(node)
            if type(node) == 'table' then
                return node[#node]
            end
            return node
        end
        function nt_query.iter_prepared_matches(query, qnode, bufnr, start_row, end_row)
            local function split(to_split)
                local t = {}
                for str in string.gmatch(to_split, "([^.]+)") do
                    table.insert(t, str)
                end
                return t
            end

            local matches = query:iter_matches(qnode, bufnr, start_row, end_row, { all = false })

            local function iterator()
                local pattern, match, metadata = matches()
                if pattern ~= nil then
                    local prepared_match = {}

                    for id, node in pairs(match) do
                        local name = query.captures[id]
                        if name ~= nil then
                            local path = split(name .. ".node")
                            nt_query.insert_to_path(prepared_match, path, last_node(node))
                            local metadata_path = split(name .. ".metadata")
                            nt_query.insert_to_path(prepared_match, metadata_path, metadata[id])
                        end
                    end

                    local preds = query.info.patterns[pattern]
                    if preds then
                        for _, pred in pairs(preds) do
                            if pred[1] == "set!" and type(pred[2]) == "string" then
                                nt_query.insert_to_path(prepared_match, split(pred[2]), pred[3])
                            end
                            if pred[1] == "make-range!" and type(pred[2]) == "string" and #pred == 4 then
                                nt_query.insert_to_path(
                                    prepared_match,
                                    split(pred[2] .. ".node"),
                                    tsrange.TSRange.from_nodes(bufnr, last_node(match[pred[3]]), last_node(match[pred[4]]))
                                )
                            end
                        end
                    end

                    return prepared_match
                end
            end
            return iterator
        end
    end

    -- nvim-treesitter still registers a few directives as if query captures are
    -- single TSNode values. Neovim 0.12 passes TSNode[] per capture, which breaks
    -- markdown injection parsing through render-markdown.nvim.
    if vim.fn.has('nvim-0.12') == 1 then
        require'nvim-treesitter.query_predicates'
        local query = require'vim.treesitter.query'
        local html_script_type_languages = {
            importmap = 'json',
            module = 'javascript',
            ['application/ecmascript'] = 'javascript',
            ['text/ecmascript'] = 'javascript',
        }
        local non_filetype_match_injection_language_aliases = {
            ex = 'elixir',
            pl = 'perl',
            sh = 'bash',
            uxn = 'uxntal',
            ts = 'typescript',
        }
        local function first_node(match, capture_id)
            local nodes = match[capture_id]
            if type(nodes) == 'table' then
                return nodes[1]
            end
            return nodes
        end
        local function parser_from_markdown_info_string(injection_alias)
            local match = vim.filetype.match { filename = 'a.' .. injection_alias }
            return match or non_filetype_match_injection_language_aliases[injection_alias] or injection_alias
        end
        query.add_directive('set-lang-from-mimetype!', function(match, _, bufnr, pred, metadata)
            local node = first_node(match, pred[2])
            if not node then
                return
            end
            local type_attr_value = vim.treesitter.get_node_text(node, bufnr)
            local configured = html_script_type_languages[type_attr_value]
            if configured then
                metadata['injection.language'] = configured
            else
                local parts = vim.split(type_attr_value, '/', {})
                metadata['injection.language'] = parts[#parts]
            end
        end, { force = true })
        query.add_directive('set-lang-from-info-string!', function(match, _, bufnr, pred, metadata)
            local node = first_node(match, pred[2])
            if not node then
                return
            end
            local injection_alias = vim.treesitter.get_node_text(node, bufnr):lower()
            metadata['injection.language'] = parser_from_markdown_info_string(injection_alias)
        end, { force = true })
        query.add_directive('downcase!', function(match, _, bufnr, pred, metadata)
            local id = pred[2]
            local node = first_node(match, id)
            if not node then
                return
            end
            local text = vim.treesitter.get_node_text(node, bufnr, { metadata = metadata[id] }) or ''
            if not metadata[id] then
                metadata[id] = {}
            end
            metadata[id].text = string.lower(text)
        end, { force = true })
    end
end

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
        { 'nvim-treesitter/nvim-treesitter', branch = 'master', run = ':TSUpdate', config = TreesitterConfig },
        { 'nvim-treesitter/nvim-treesitter-textobjects', branch = 'master' },
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

    require'prjroot'.setup()
    require'launcher'.setup()
    require'grep'.setup()
    require'session'.setup()
    require'status'.setup()
    require'file_info'.setup()
    require'smart_colorcolumn'.setup(120)
    require'smart_cursorline'.setup()
    require'lsp_setting'.setup()
    require'rendermark'.setup{
        max_width = 120,
        plantuml = {
            preview = {
                mode = 'split',            -- 'float' (default, unchanged) | 'split'
                auto = true,               -- auto-open when cursor enters a block
                split = {
                    position  = 'right',     -- 'left'/'right' ⇒ vertical, 'top'/'bottom' ⇒ horizontal
                    size      = 0.25,         -- 'half' | 0<n<1 fraction of editor | n≥1 absolute cols/rows
                    lifecycle = 'persistent',-- 'persistent' (pane stays, keeps last) | 'cursor' (open/close with block)
                },
            },
        },
    }
    -- require'complete'.setup()
    -- require'md'.setup()

    --require'focus_win'.setup{ active='#212121', inactive='#303030' }

    FullscreenSettings()
end

return M
