local util_buffer = require('nvim_config.util.buffer')
local ut = require('nvim_config.util.map')
local util_text = require('nvim_config.util.text')
local api, cmd = vim.api, vim.cmd

local M = {}

local function open_picker(name, ...)
    require('nvim_config.plugins').load_telescope()
    return require('nvim_config.plugins.tele.pickers')[name](...)
end

local function select_instance_target(on_select)
    open_picker('InstanceTargets', on_select)
end

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

    -- Window navigation
    ut.nnoremap('<c-h>', '<c-w><c-h>')
    ut.nnoremap('<c-j>', '<c-w><c-j>')
    ut.nnoremap('<c-k>', '<c-w><c-k>')
    ut.nnoremap('<c-l>', '<c-w><c-l>')

    -- Insert blank line
    ut.nnoremap('[<space>', 'O<c-[>')
    ut.nnoremap(']<space>', 'o<c-[>')

    -- New undo group before <C-W>/<C-R> in Insert mode
    ut.inoremap('<C-W>', '<C-G>u<C-W>')
    ut.inoremap('<C-R>', '<C-G>u<C-R>')

    -- Misc
    ut.noremap('H', '^')
    ut.noremap('L', 'g_')
    ut.vnoremap('>', '>gv')
    ut.vnoremap('<', '<gv')

    -- Abbreviations: date, time, file name
    cmd.inoreabbrev 'todayy <C-R>=strftime("%F")<CR>'
    cmd.inoreabbrev 'noww <C-R>=strftime("%T")<CR>'
    cmd.inoreabbrev 'thisfilee <C-R>=expand("%:t")<CR>'
    cmd.inoreabbrev '--> →'

    -- Escape Windows path separators
    -- TODO: Visual mode
    ut.nnoremap('<leader>s/', [[<cmd>s/\\/\\\\/g<cr>]])

    -- Paste charwise text on a new line (https://stackoverflow.com/a/1346777/6064933)
    ut.nnoremap('<leader>p', 'm`o<ESC>p``')
    ut.nnoremap('<leader>P', 'm`O<ESC>p``')

    -- Move by display lines
    ut.nnoremap('j', 'v:count == 0 ? "gj" : "j"', { 'expr' })
    ut.nnoremap('k', 'v:count == 0 ? "gk" : "k"', { 'expr' })
    ut.vnoremap('j', 'v:count == 0 ? "gj" : "j"', { 'expr' })
    ut.vnoremap('k', 'v:count == 0 ? "gk" : "k"', { 'expr' })

    -- Resize and move windows
    ut.nnoremap('<M-h>', '<C-w><')
    ut.nnoremap('<M-l>', '<C-w>>')
    ut.nnoremap('<M-j>', '<C-W>-')
    ut.nnoremap('<M-k>', '<C-W>+')
    ut.nnoremap('<M-left>', '<C-w>H')
    ut.nnoremap('<M-right>', '<C-w>L')
    ut.nnoremap('<M-up>', '<C-w>K')
    ut.nnoremap('<M-down>', '<C-w>J')

    -- Esc leaves terminal mode
    ut.tnoremap('<ESC>', [[<C-\><C-n>]])

    -- Reselect pasted text
    ut.nnoremap('<leader>v', '`[v`]')
    ut.nnoremap('<leader>V', '`[V`]')

    -- Move lines
    ut.vnoremap('K', ":m '<-2<CR>gv=gv")
    ut.vnoremap('J', ":m '>+1<CR>gv=gv")

    -- Misc
    ut.nnoremap('<m-cr>', '<cmd>buffer #<cr><cmd>vertical sbuffer #<cr>')
    cmd.cnoreabbrev 'W w'
    cmd.cnoreabbrev 'Wa wa'
    cmd.cnoreabbrev 'Q q'
    cmd.cnoreabbrev 'Qa qa'

    ut.inoremap('{<cr>', '{<cr>}<esc>O')

    api.nvim_create_user_command('Config', function(opts)
        if opts.args ~= '' then
            open_picker('ConfigFiles', opts.args)
        else
            util_buffer.OpenConfig(opts)
        end
    end, { nargs='?' })
    api.nvim_create_user_command('StripTrailingWhitespace', util_text.StripTrailingWhitespace, {})
    api.nvim_create_user_command('OpenAllHiddenBuffer', util_buffer.OpenAllHiddenBuffers, {})
    api.nvim_create_user_command('WipeHiddenBuffers', util_buffer.wipeout_hidden_buffers, {})
    api.nvim_create_user_command('NewInstance', function(opts)
        if opts.bang then
            api.nvim_echo({ { require'nvim_config.instance'.diagnose() } }, true, {})
        else
            require'nvim_config.instance'.new(opts.args ~= '' and opts.args or nil)
        end
    end, { nargs = '?', bang = true, complete = 'file' })
    api.nvim_create_user_command('MoveBufferToInstance', function()
        require'nvim_config.instance.move'.move('buffer', select_instance_target)
    end, {})
    api.nvim_create_user_command('MoveTabToInstance', function()
        require'nvim_config.instance.move'.move('tab', select_instance_target)
    end, {})

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

    -- Textobject keymaps live in plugins/treesitter.lua.

    -- Loupe (search)
    ut.nnoremap('n', '<cmd>let v:searchforward=1<cr><Plug>(Loupen)')
    ut.nnoremap('N', '<cmd>let v:searchforward=1<cr><Plug>(LoupeN)')
    -- On VimEnter so plugin files can't override it
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
    ut.nnoremap('<leader>gg', function() require'nvim_config.grep'.prompt_grep(false) end)
    ut.nnoremap('<leader>gw', function() require'nvim_config.grep'.prompt_grep(true) end)
    ut.vnoremap('<leader>g', function() require'nvim_config.grep'.asyncGrep(util_text.GetSelectWord(), false, vim.fn.win_getid()) end)
    ut.nnoremap('<leader>gc', function() require'nvim_config.grep'.asyncGrep(vim.fn.expand('<cword>'), true, vim.fn.win_getid()) end)

    -- file_info
    api.nvim_create_user_command('FileInfo', function() require'nvim_config.file_info'.show() end, {})
    ut.nnoremap('<C-g>', function() require'nvim_config.file_info'.show() end)

    -- launcher
    api.nvim_create_user_command('ProcessList', function() require'nvim_config.launcher'.ShowProcessList() end, {})
    api.nvim_create_user_command('WipeLauncherBuffers', function() require'nvim_config.launcher'.WipeLauncherBuffers() end, {})
    ut.nnoremap('<leader>lc', function() require'nvim_config.launcher'.WipeLauncherBuffers() end)

    -- prjroot
    ut.nnoremap('<leader>tv', function() require('nvim_config.prjroot').OpenProjectRootTerminal('vertical') end)
    ut.nnoremap('<leader>tx', function() require('nvim_config.prjroot').OpenProjectRootTerminal('horizontal') end)
    ut.nnoremap('<leader>tt', function() require('nvim_config.prjroot').OpenProjectRootTerminal('tab') end)
    api.nvim_create_user_command('PrjRootConfig', function(t)
        vim.cmd.vsplit {mods = t.smods, args = {(require'nvim_config.prjroot'.GetCurrentProjectRoot() or '.') .. '/.prjroot'}}
    end, {})

    -- read_mode
    ut.nnoremap('<leader>r', function() require'nvim_config.read_mode'.toggle() end)

    -- reopen
    ut.nnoremap('<leader>u', function() require'nvim_config.reopen'.restore() end)

    -- json
    if vim.fn.executable('jq') == 1 then
        api.nvim_create_user_command('JsonPretty', function(t) require'nvim_config.json'.pretty(t.line1, t.line2) end, { range = '%' })
        api.nvim_create_user_command('JsonOneline', function(t) require'nvim_config.json'.oneline(t.line1, t.line2) end, { range = '%' })
    end

    -- session
    ut.nnoremap('<F12>', function() require'nvim_config.session'.SaveSession() end)

    -- tabline
    ut.nnoremap('<c-right>', function() require'nvim_config.tabline'.tab_scroll(vim.v.count1) end)
    ut.nnoremap('<c-left>', function() require'nvim_config.tabline'.tab_scroll(-vim.v.count1) end)

    -- tele
    ut.nmap('<Leader>ff', function() open_picker('Files') end)
    ut.nmap('<Leader>fb', function() open_picker('Buffers') end)
    ut.nmap('<Leader>fs', function() open_picker('Sessions') end)
    ut.nmap('<Leader>fu', function() open_picker('RunLauncher') end)
    ut.nmap('<Leader>fn', function() open_picker('Notes') end)
    ut.nmap('<Leader>fw', function() open_picker('LSPWorkspaceSymbols') end)
    ut.nmap('<Leader>ft', function() open_picker('Tabs') end)
end

return M
