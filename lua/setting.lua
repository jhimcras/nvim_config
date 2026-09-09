local api, cmd = vim.api, vim.cmd
local M = {}

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
    vim.o.mouse = 'nvi'
    vim.o.lazyredraw = true
    vim.o.showmode = false
    vim.o.swapfile = false
    vim.o.wrap = false
    vim.o.pumheight = 20
    vim.o.pyx = 3
    vim.o.number = true
    vim.o.relativenumber = true
    vim.o.scrolloff = 1
    vim.o.sidescrolloff = 5
    vim.o.showmatch = true
    vim.o.splitright = true
    vim.o.title = true
    vim.o.titlestring = '(%{v:lua.require("status").titlecontext()}) %t'
    vim.opt.path:append('**')
    vim.opt.wildignore:append { '*/.git/*', '*/.hg/*', '*/.svn/*', '*/.sass-cache/*', '*/x64/*', '*/.vs/*', '*/.clangd/*' }
    vim.opt.suffixes:remove('.h')
    vim.o.updatetime = 500
    vim.o.signcolumn = 'yes:1'
    vim.o.timeoutlen = 1000
    vim.o.ttimeoutlen = 0       -- This solves the problem on linux terminal esc dealy
    vim.o.breakindent = true
    vim.g.original_path = vim.env.PATH
    vim.o.fileencodings = 'ucs-bom,utf-8,euckr' --,latin1'
    cmd.packadd 'cfilter'   -- enable Cfilter command
    vim.o.winblend = 20
    vim.o.winborder = 'rounded'
    vim.o.jumpoptions = 'stack,clean'
    vim.o.equalalways = false

    -- Disabling standard plugins
    vim.g.loaded_netrw = 1
    vim.g.loaded_netrwPlugin = 1
    vim.g.loaded_matchit = 1
    vim.g.loaded_matchparen = 1
    vim.opt.sessionoptions:remove("terminal")

    vim.o.guifont = 'D2Coding:h15'

    vim.o.cursorline = true
    vim.o.showtabline = 2

    api.nvim_create_autocmd('BufEnter', { callback = function()
        vim.opt_local.formatoptions:append('j')
        vim.opt_local.formatoptions:remove{'r', 'o'}
    end })

    -- Clean up stale shada tmp files left by previous crashes (Windows)
    api.nvim_create_autocmd('VimEnter', { once = true, callback = function()
        local shada = vim.fn.stdpath('data') .. '/shada/main.shada'
        for _, f in ipairs(vim.fn.glob(shada .. '.tmp.*', false, true)) do
            vim.fn.delete(f)
        end
    end })
end

local function FoldSetting()
    vim.o.foldtext = "v:lua.FoldText()"
end

-- The treesitter highlighter prepares states over the window's topline..botline
-- BUFFER range, which closed folds stretch across most of the file for one
-- screenful of rows (measured: 123ms per scroll step on a 37k-line cpp diff, vs
-- 3ms unfolded). diff mode is the only place this config folds by default, so big
-- diff buffers fall back to legacy syntax and get treesitter back on diff end.
local function DiffSetting()
    local big_buffer_lines = 2000

    local function in_diff_window(buf)
        for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
            if api.nvim_win_get_buf(win) == buf and vim.wo[win].diff then
                return true
            end
        end
        return false
    end

    local function sync()
        for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
            local buf = api.nvim_win_get_buf(win)
            if vim.b[buf].ts_off_for_diff then
                if not in_diff_window(buf) then
                    vim.b[buf].ts_off_for_diff = nil
                    pcall(vim.treesitter.start, buf)
                end
            elseif vim.treesitter.highlighter.active[buf]
                and vim.wo[win].diff
                and api.nvim_buf_line_count(buf) > big_buffer_lines then
                vim.treesitter.stop(buf)
                -- nvim-treesitter clears 'syntax' when it enables the highlighter.
                if vim.bo[buf].syntax == '' or vim.bo[buf].syntax == 'off' then
                    vim.bo[buf].syntax = vim.bo[buf].filetype
                end
                vim.b[buf].ts_off_for_diff = true
            end
        end
    end

    api.nvim_create_autocmd('DiffUpdated', { callback = sync })
    api.nvim_create_autocmd('OptionSet', { pattern = 'diff', callback = sync })
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

function M.setup()
    BasicSettings()
    FoldSetting()
    DiffSetting()
    SetTabAndIndent()
end

return M
