local ut = require 'util'
local api, cmd = vim.api, vim.cmd

local M = {}

local function gui_zoom(dir)  -- dir = 'in' | 'out' | 'reset'
    if vim.g.neopp_channel then
        vim.cmd('NeoppFontZoom ' .. dir)
    elseif vim.g.neovide then
        if dir == 'reset' then vim.g.neovide_scale_factor = 1.0
        else vim.g.neovide_scale_factor = vim.g.neovide_scale_factor * (dir == 'in' and 1.25 or 1/1.25) end
    end
end

local function gclog_back()
    local bufname = vim.api.nvim_buf_get_name(0)
    local normalized = bufname:gsub('\\', '/'):lower()
    if normalized:match('^fugitive://') then
        local real = vim.fn['fugitive#Real'](bufname)
        if real ~= '' then
            vim.cmd('edit ' .. vim.fn.fnameescape(real))
            return
        end
    end
    vim.notify('Not in a fugitive history buffer', vim.log.levels.WARN)
end

function M.setup()
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

    ut.nnoremap('<LeftDrag>', '<NOP>')
    ut.nnoremap('<LeftRelease>', '<NOP>')

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
    -- ut.inoremap('<C-k>', '<Up>')
    -- ut.inoremap('<C-j>', '<Down>')
    -- ut.inoremap('<C-h>', '<Left>')
    -- ut.inoremap('<C-l>', '<Right>')
    ut.vnoremap('>', '>gv')
    ut.vnoremap('<', '<gv')
    -- ut.nnoremap('<ESC>', '<CMD>nohlsearch<CR>')

    -- Mapping to insert today and current time
    cmd.inoreabbrev 'todayy <C-R>=strftime("%F")<CR>'
    cmd.inoreabbrev 'noww <C-R>=strftime("%T")<CR>'
    cmd.inoreabbrev 'thisfilee <C-R>=expand("%:t")<CR>'
    cmd.inoreabbrev '--> →'

    -- Escaping Windows folder seperators
    -- TODO: Make it works on visual mode
    ut.nnoremap('<leader>s/', [[<cmd>s/\\/\\\\/g<cr>]])

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

    -- Use Esc to quit builtin terminal
    ut.tnoremap('<ESC>', [[<C-\><C-n>]])

    -- Reselect the text that has just been pasted
    ut.nnoremap('<leader>v', '`[v`]')
    ut.nnoremap('<leader>V', '`[V`]')

    -- Move lines up and down
    ut.vnoremap('K', ":m '<-2<CR>gv=gv")
    ut.vnoremap('J', ":m '>+1<CR>gv=gv")

    -- Convinients
    ut.nnoremap('<m-cr>', '<cmd>buffer #<cr><cmd>vertical sbuffer #<cr>')
    cmd.cnoreabbrev 'W w'
    cmd.cnoreabbrev 'Wa wa'
    cmd.cnoreabbrev 'Q q'
    cmd.cnoreabbrev 'Qa qa'

    ut.inoremap('{<cr>', '{<cr>}<esc>O')

    api.nvim_create_user_command('Config', function(opts)
        if opts.args ~= '' then
            require'tele'.ConfigFiles(opts.args)
        else
            ut.OpenConfig(opts)
        end
    end, { nargs='?' })
    api.nvim_create_user_command('StripTrailingWhitespace', ut.StripTrailingWhitespace, {})
    api.nvim_create_user_command('OpenAllHiddenBuffer', ut.OpenAllHiddenBuffers, {})
    api.nvim_create_user_command('WipeHiddenBuffers', ut.wipeout_hidden_buffers, {})
    api.nvim_create_user_command('NewInstance', function(opts)
        local cmd_name = vim.g.neovide and 'neovide' or 'nvim'
        local args = { cmd_name }
        if opts.args ~= '' then
            table.insert(args, opts.args)
        end
        vim.fn.jobstart(args, { detach = true })
    end, { nargs = '?', complete = 'file' })

    ut.nnoremap('<c-=>', function() gui_zoom('in') end)
    ut.nnoremap('<c-+>', function() gui_zoom('in') end)   -- numpad + / Ctrl+Shift+=
    ut.nnoremap('<c-->', function() gui_zoom('out') end)
    ut.nnoremap('<c-0>', function() gui_zoom('reset') end)

    ut.nnoremap('<esc>', function()
        for _, win in ipairs(vim.api.nvim_list_wins()) do
            if vim.api.nvim_win_get_config(win).relative ~= '' then
                pcall(vim.api.nvim_win_close, win, false)
            end
        end
        vim.cmd.nohlsearch()
    end)

    if vim.g.neovide then
        ut.nnoremap('<s-cr>', function() vim.g.neovide_fullscreen = not vim.g.neovide_fullscreen end)
    end

    -- nvim-treesitter-textobjects keymaps (select/move/swap) are declared in
    -- TreesitterConfig via require'nvim-treesitter.configs'.setup{ textobjects = ... }.

    -- Loupe (search)
    ut.nnoremap('n', '<cmd>let v:searchforward=1<cr><Plug>(Loupen)')
    ut.nnoremap('N', '<cmd>let v:searchforward=1<cr><Plug>(LoupeN)')
    -- Apply mapping on VimEnter so it's never overridden by plugin files
    vim.api.nvim_create_autocmd('VimEnter', { once = true, callback = function()
        ut.nnoremap('*', function()
            local view = vim.fn.winsaveview()
            vim.cmd('keepjumps normal! *')
            vim.fn.winrestview(view)
        end)
    end })

    -- Oil
    vim.keymap.set('n', '-', function() require'oil'.open() end)
    vim.keymap.set('n', '_', function() vim.cmd.vsplit(); require'oil'.open() end)

    -- Fugitive
    api.nvim_create_user_command('GclogBack', gclog_back, {})

    -- grep
    api.nvim_create_user_command('Grep', function(t) require'grep'.asyncGrep(t.args, false, vim.fn.win_getid()) end, { nargs='+', bar=true })
    api.nvim_create_user_command('GrepWord', function(t) require'grep'.asyncGrep(t.args, true, vim.fn.win_getid()) end, { nargs='+', bar=true })
    ut.nnoremap('<leader>gg', function() require'grep'.prompt_grep(false) end)
    ut.nnoremap('<leader>gw', function() require'grep'.prompt_grep(true) end)
    ut.vnoremap('<leader>g', function() require'grep'.asyncGrep(ut.GetSelectWord(), false, vim.fn.win_getid()) end)
    ut.nnoremap('<leader>gc', function() require'grep'.asyncGrep(vim.fn.expand('<cword>'), true, vim.fn.win_getid()) end)

    -- file_info
    api.nvim_create_user_command('FileInfo', function() require'file_info'.show() end, {})
    ut.nnoremap('<C-g>', function() require'file_info'.show() end)

    -- launcher
    api.nvim_create_user_command('ProcessList', function() require'launcher'.ShowProcessList() end, {})
    api.nvim_create_user_command('WipeLauncherBuffers', function() require'launcher'.WipeLauncherBuffers() end, {})
    ut.nnoremap('<leader>lc', function() require'launcher'.WipeLauncherBuffers() end)

    -- prjroot
    ut.nnoremap('<leader>tv', function() ut.OpenProjectRootTerminal('vertical') end)
    ut.nnoremap('<leader>tx', function() ut.OpenProjectRootTerminal('horizontal') end)
    ut.nnoremap('<leader>tt', function() ut.OpenProjectRootTerminal('tab') end)
    api.nvim_create_user_command('PrjRootConfig', function(t)
        vim.cmd.vsplit {mods = t.smods, args = {(require'prjroot'.GetCurrentProjectRoot() or '.') .. '/.prjroot'}}
    end, {})

    -- read_mode
    ut.nnoremap('<leader>r', function() require'read_mode'.toggle() end)

    -- json
    if vim.fn.executable('jq') == 1 then
        api.nvim_create_user_command('JsonPretty', function(t) require'json'.pretty(t.line1, t.line2) end, { range = '%' })
        api.nvim_create_user_command('JsonOneline', function(t) require'json'.oneline(t.line1, t.line2) end, { range = '%' })
    end

    -- session
    api.nvim_create_user_command('SaveSession', function(t) require'session'.SaveSession(t.args) end, { nargs='?', complete="customlist,v:lua.require'session'.SessionList" })
    ut.nnoremap('<F12>', function() require'session'.SaveSession() end)

    -- tabline
    ut.nnoremap('<c-right>', function() require'tabline'.tab_scroll(vim.v.count1) end)
    ut.nnoremap('<c-left>', function() require'tabline'.tab_scroll(-vim.v.count1) end)

    -- tele
    ut.nmap('<Leader>ff', function() require'tele'.Files() end)
    ut.nmap('<Leader>fb', function() require'tele'.Buffers() end)
    ut.nmap('<Leader>fs', function() require'tele'.Sessions() end)
    ut.nmap('<Leader>fu', function() require'tele'.RunLauncher() end)
    ut.nmap('<Leader>fn', function() require'tele'.Notes() end)
    ut.nmap('<Leader>fw', function() require'tele'.LSPWorkspaceSymbols() end)
    ut.nmap('<Leader>ft', function() require'tele'.Tabs() end)
end

return M
