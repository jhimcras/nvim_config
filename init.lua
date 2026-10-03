vim.loader.enable()

local env = require 'env'
local api, cmd = vim.api, vim.cmd

-- TODO: Find out not to use global function
function FoldText()
    local first_folded_line = vim.fn.getline(vim.v.foldstart)
    local width = tonumber(vim.wo.colorcolumn) or vim.api.nvim_win_get_width(0)
    local pad = math.max(width - first_folded_line:len() - 3, 0)
    local l = {
        first_folded_line,
        '  ',
        string.rep('·', pad)
    }
    return table.concat(l)
end

local function TerminalSetting()
    api.nvim_create_autocmd('TermOpen', { callback = function()
        vim.wo.relativenumber = false
        vim.wo.number = false
        cmd.startinsert()
    end })
end

local function SetAutoChangedFileReloading()
    -- Reload files changed outside Nvim (`checktime` fails in the command line).
    api.nvim_create_autocmd({ 'FocusGained','BufEnter','CursorHold','CursorHoldI' }, { callback = function()
        if vim.fn.mode() == 'n' and vim.fn.getcmdwintype() == '' then
            cmd.checktime()
        end
    end })
    api.nvim_create_autocmd('FileChangedShellPost', { callback = function()
        vim.notify("File changed on disk. Buffer reloaded!" , vim.log.levels.WARN)
    end })
end

local function C_CPP_HeaderCorrection()
    vim.api.nvim_create_autocmd({ "BufRead", "BufNewFile" }, {
        pattern = "*.h",
        callback = function()
            local base = vim.fn.expand("%:r")
            if vim.fn.filereadable(base .. ".cpp") == 1
                or vim.fn.filereadable(base .. ".cc") == 1
                or vim.fn.filereadable(base .. ".cxx") == 1 then
                vim.bo.filetype = "cpp"
            else
                vim.bo.filetype = "c"
            end
        end,
    })
end

----------------------------------------------------------------------------------------------------
require'setting'.setup()
TerminalSetting()
SetAutoChangedFileReloading()
require'plugins'.setup()
require'prjroot'.setup()
require'launcher'.setup()
require'grep'.setup()
require'json'.setup()
require'session'.setup()
require'status'.setup()
require'file_info'.setup()
require'smart_cursorline'.setup()
require'read_mode'.setup()
require'reopen'.setup()
require'lsp_setting'.setup()
require'rendermark'.setup{
    max_width = 120,
    plantuml = {
        preview = {
            mode = 'split',            -- 'float' | 'split'
            auto = true,               -- open when the cursor enters a block
            split = {
                -- position follows the window aspect: landscape -> right, portrait -> bottom
                size      = 0.20,         -- 'half' | fraction (<1) | absolute cells (>=1)
                lifecycle = 'cursor',    -- 'cursor' | 'persistent'
            },
        },
    },
}
require'keymap'.setup()
require'instance_move'.setup()
require'highlight'.setup()
C_CPP_HeaderCorrection()
