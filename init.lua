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
require'keymap'.setup()
require'highlight'.setup()
C_CPP_HeaderCorrection()

