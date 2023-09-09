local env = require 'env'
local ut = require 'util'
local api, cmd = vim.api, vim.cmd

local function BasicSettings()
    vim.g.mapleader = ' '
    vim.o.background = 'dark'
    vim.o.belloff = 'all'
    vim.opt.clipboard:append('unnamedplus')
    vim.opt.diffopt:append('vertical')
    vim.opt.fillchars = { fold = ' ', eob = ' ', vert ='│', diff = '·' }
    vim.o.hidden = true
    vim.o.ignorecase = true
    vim.o.smartcase = true
    vim.o.inccommand = 'nosplit'
    vim.opt.listchars = { tab = '→ ', eol = '¬', trail = '␣', extends = '>', precedes ='<', nbsp = '+' }
    vim.o.showbreak = '↪'
    vim.opt.matchpairs:append { '<:>', '「:」' }
    vim.o.history = 1024
    vim.o.maxmempattern = 10240
    vim.o.undolevels = 2048
    vim.o.mouse = 'nv'
    vim.o.lazyredraw = true
    vim.o.showmode = false
    vim.o.swapfile = false
    vim.o.wrap = false
    vim.o.pumheight = 20
    vim.o.pyx = 3
    vim.o.number = true
    vim.o.relativenumber = false
    vim.o.scrolloff = 1
    vim.o.sidescrolloff = 5
    vim.o.showmatch = true
    vim.o.splitright = true
    vim.o.switchbuf = 'useopen'
    vim.o.title = true
    vim.opt.path:append('**')
    vim.opt.wildignore:append { '*/.git/*', '*/.hg/*', '*/.svn/*', '*/.sass-cache/*', '*/x64/*', '*/.vs/*', '*/.clangd/*' }
    vim.opt.suffixes:remove('.h')
    vim.o.updatetime = 500
    vim.o.signcolumn = 'yes:1'
    vim.o.timeoutlen = 1000
    vim.o.ttimeoutlen = 0       -- This solves the problem on linux terminal esc dealy
    vim.o.breakindent = true
    vim.g.original_path = vim.env.PATH
    vim.o.fileencodings = 'ucs-bom,utf-8,euckr,latin1'
    cmd.packadd 'cfilter'   -- enable Cfilter command

    -- Disabling netrw and matchit
    vim.g.loaded_netrw = 1
    vim.g.loaded_netrwPlugin = 1
    vim.g.loaded_matchit = 1

    api.nvim_create_autocmd('BufEnter', { callback = function()
        vim.opt_local.formatoptions:append('j')
        vim.opt_local.formatoptions:remove{'r', 'o'}
    end })
end

-- TODO: Find out not to use global function
function FoldText()
    local first_folded_line = vim.fn.getline(vim.v.foldstart)
    local l = {
        first_folded_line,
        '  ',
        string.rep('·', vim.wo.colorcolumn - first_folded_line:len() - 3)
    }
    return table.concat(l)
end

local function FoldSetting()
    vim.o.foldtext = "v:lua.FoldText()"
end

local function TerminalSetting()
    api.nvim_create_autocmd('TermOpen', { callback = function()
        vim.wo.relativenumber = false
        vim.wo.number = false
        cmd.startinsert()
    end })
end

local function SetAutoChangedFileReloading()
    -- Automatically reload the file if it is changed outside of Nvim, see
    -- https://unix.stackexchange.com/a/383044/221410. It seems that `checktime`
    -- command does not work in command line. We need to check if we are in command
    -- line before executing this command. See also http://tinyurl.com/y6av4sy9.
    api.nvim_create_autocmd({ 'FocusGained','BufEnter','CursorHold','CursorHoldI' }, { callback = function()
        if vim.fn.mode() == 'n' and vim.fn.getcmdwintype() == '' then
            cmd.checktime()
        end
    end })
    api.nvim_create_autocmd('FileChangedShellPost', { callback = function()
        vim.notify("File changed on disk. Buffer reloaded!" , vim.log.levels.WARN)
    end })
end

local function SetTabAndIndent()
    vim.o.expandtab = true
    vim.o.shiftround = true
    vim.o.shiftwidth = 4
    vim.o.softtabstop = 4
    vim.o.tabstop = 8
    api.nvim_create_autocmd('FileType', {pattern = {'cpp', 'c'}, callback = function()
        vim.opt_local.cinoptions:append {'g0', ':0'}
    end})
    api.nvim_create_autocmd('FileType', {pattern = 'make', callback = function()
        vim.bo.expandtab = false
    end})
end

local function SetColorsAndHighlighting()
    require('nvim-tundra').setup {}
    cmd.colorscheme 'tundra'
    vim.o.pumblend = 10
    -- ut.set_highlight('Pmenu', { ctermbg=238 })
    cmd.let '$TERM="xterm-256color"'
    if not env.os.win then
        vim.o.termguicolors = true
    end
    api.nvim_create_autocmd('TextYankPost', { callback = function()
        vim.highlight.on_yank { timeout = 200 }
    end } )
end


local function KeyMappings()
    ut.nnoremap('<Up>', '<C-y>')
    ut.nnoremap('<Down>', '<C-e>')
    ut.nnoremap('<Left>', 'zh')
    ut.nnoremap('<Right>', 'zl')
    ut.inoremap('<Up>', '<NOP>')
    ut.inoremap('<Down>', '<NOP>')
    ut.inoremap('<Left>', '<NOP>')
    ut.inoremap('<Right>', '<NOP>')

    ut.noremap('<F1>', '<NOP>')
    ut.inoremap('<F1>', '<NOP>')
    ut.nnoremap('Q', '<NOP>')

    -- Easy yanking start from current position
    ut.nnoremap('Y', 'y$')

    -- Easy to switch between windows
    ut.nnoremap('<c-h>', '<c-w><c-h>')
    ut.nnoremap('<c-j>', '<c-w><c-j>')
    ut.nnoremap('<c-k>', '<c-w><c-k>')
    ut.nnoremap('<c-l>', '<c-w><c-l>')

    -- Insert blank line
    ut.nnoremap('[<space>', 'O<c-[>')
    ut.nnoremap(']<space>', 'o<c-[>')

    -- Start a new Undo group before making changes in INSERT mode.
    ut.inoremap('<C-W>', '<C-G>u<C-W>')
    ut.inoremap('<C-R>', '<C-G>u<C-R>')

    -- For convinient
    ut.noremap('H', '^')
    ut.noremap('L', 'g_')
    ut.inoremap('<C-k>', '<Up>')
    ut.inoremap('<C-j>', '<Down>')
    ut.inoremap('<C-h>', '<Left>')
    ut.inoremap('<C-l>', '<Right>')
    ut.vnoremap('>', '>gv')
    ut.vnoremap('<', '<gv')


    -- Mapping to insert today and current time
    cmd.inoreabbrev 'todayy <C-R>=strftime("%F")<CR>'
    cmd.inoreabbrev 'noww <C-R>=strftime("%T")<CR>'
    cmd.inoreabbrev 'thisfilee <C-R>=expand("%:t")<CR>'

    -- Escaping Windows folder seperators
    -- TODO: Make it works on visual mode
    if env.os.win then
        ut.nnoremap('<leader>ds', [[<cmd>s/\\/\\\\/g<cr>]])
    end

    -- Quicker <Esc> in insert mode
    --inoremap('jk', '<Esc>')

    -- Paste non-linewise text above or below current cursor,
    -- see https://stackoverflow.com/a/1346777/6064933
    ut.nnoremap('<leader>p', 'm`o<ESC>p``')
    ut.nnoremap('<leader>P', 'm`O<ESC>p``')

    -- Move the cursor based on physical lines, not the actual lines.
    ut.nnoremap('j', 'v:count == 0 ? "gj" : "j"', { 'expr' })
    ut.nnoremap('k', 'v:count == 0 ? "gk" : "k"', { 'expr' })
    ut.vnoremap('j', 'v:count == 0 ? "gj" : "j"', { 'expr' })
    ut.vnoremap('k', 'v:count == 0 ? "gk" : "k"', { 'expr' })

    -- Resize and change position windows
    ut.nnoremap('<M-h>', '<C-w><')
    ut.nnoremap('<M-l>', '<C-w>>')
    ut.nnoremap('<M-j>', '<C-W>-')
    ut.nnoremap('<M-k>', '<C-W>+')
    ut.nnoremap('<M-left>', '<C-w>H')
    ut.nnoremap('<M-right>', '<C-w>L')
    ut.nnoremap('<M-up>', '<C-w>K')
    ut.nnoremap('<M-down>', '<C-w>J')

    -- Change current working directory locally and print cwd after that,
    -- see https://vim.fandom.com/wiki/Set_working_directory_to_the_current_file
    ut.nnoremap('<leader>cd', ':lcd %:p:h<CR>:pwd<CR>')

    -- Use Esc to quit builtin terminal
    ut.tnoremap('<ESC>', [[<C-\><C-n>]])

    -- Reselect the text that has just been pasted
    ut.nnoremap('<leader>v', '`[V`]')

    -- Search in selected region
    --vnoremap('/', ':<C-U>call feedkeys('/\%>'.(line("'<")-1).'l\%<'.(line("'>")+1)."l")<CR>')

    -- Move lines up and down
    ut.vnoremap('K', ":m '<-2<CR>gv=gv")
    ut.vnoremap('J', ":m '>+1<CR>gv=gv")

    -- Convinients
    ut.nnoremap('<m-cr>', '<cmd>buffer #<cr><cmd>vertical sbuffer #<cr>')
    cmd.cnoreabbrev 'h vert help'
    cmd.cnoreabbrev 'he vert help'
    cmd.cnoreabbrev 'hel vert help'
    cmd.cnoreabbrev 'help vert help'
    cmd.cnoreabbrev 'W w'
    cmd.cnoreabbrev 'Wa wa'
    cmd.cnoreabbrev 'Q q'
    cmd.cnoreabbrev 'Qa qa'

    ut.inoremap('{<cr>', '{<cr>}<esc>O')

    api.nvim_create_user_command('Config', function(opts) ut.OpenConfig(opts) end, {})
    api.nvim_create_user_command('StripTrailingWhitespace', ut.StripTrailingWhitespace, {})
    api.nvim_create_user_command('OpenAllHiddenBuffer', ut.OpenAllHiddenBuffers, {})

    ut.nnoremap('<leader><leader>', function() vim.notify(os.date("%F %T"), vim.log.levels.INFO) end)
end


local function QuickFixSetting()
    -- Navigation in the location and quickfix list
    --nnoremap('<silent>[l', '<cmd>lprevious<CR>zv')
    --nnoremap('<silent>]l', '<cmd>lnext<CR>zv')
    --nnoremap('<silent>[L', '<cmd>lfirst<CR>zv')
    --nnoremap('<silent>]L', '<cmd>llast<CR>zv')
    ut.nnoremap('[q', cmd.cprevious)
    ut.nnoremap(']q', cmd.cnext)
    ut.nnoremap('[Q', cmd.cfirst)
    ut.nnoremap(']Q', cmd.clast)

    -- ut.set_highlight('QuickFixLine', { gui='underline' })
end

----------------------------------------------------------------------------------------------------
BasicSettings()
FoldSetting()
QuickFixSetting()
TerminalSetting()
SetAutoChangedFileReloading()
SetTabAndIndent()
SetColorsAndHighlighting()
KeyMappings()
require'plugins'.setup()
