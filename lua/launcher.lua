local M = {}

local pr = require'prjroot'
local ut = require'util'
local env = require 'env'
local api = vim.api

-- TODO: check whether the thread actually processing
local function CloseLauncherBuffer()
    if vim.b.this_buf_can_be_closed then
        vim.cmd.bwipeout { bang = true }
    else
        vim.notify('This process does not closed yet.', vim.log.levels.WARN)
    end
end

local function set_launcher_mapping(buf)
    ut.nnoremap('q', CloseLauncherBuffer, { buffer = buf })
    -- ut.nnoremap('e', [[gg/error<cr>]], { buffer = buf })
    -- ut.nnoremap('w', [[gg/warning<cr>]], { buffer = buf })
    -- ut.nnoremap('<cr>', [[<cmd>lua require'launcher'.Jump()<cr>]], { buffer = buf })
    -- ut.nnoremap('<c-c>', [[<cmd>lua require'launcher'.TerminateCurrentLauncherBuffer()<cr>]], { buffer = buf })
end

function M.Launch(cmd, args, cwd, ev, hi, position, color_mode)
    local prjroot_origin = pr.GetCurrentProjectRoot()
    local buf = ut.NewScratchBuffer(position)
    local win = api.nvim_get_current_win()
    if hi then
        for keyword, highlight_group in pairs(hi) do
            vim.fn.matchadd(highlight_group, keyword)
        end
    end
    pr.SetBufferProjectRoot(buf, prjroot_origin)
    set_launcher_mapping(buf)
    local onread = function(err, data)
        assert(not err, err)
        if data then
            local results = vim.split(data, env.new_line_char)
            local append_result = vim.schedule_wrap(function()
                local processed_lines = results
                local highlight_data = {}
                
                if color_mode == 'use' or color_mode == 'mono' then
                    local ansi = require('ansi_parser')
                    processed_lines = {}
                    for i, line in ipairs(results) do
                        local cleaned, highlights = ansi.parse_ansi(line)
                        processed_lines[i] = cleaned
                        if color_mode == 'use' then
                            highlight_data[i] = highlights
                        end
                    end
                end

                local start_line = api.nvim_buf_line_count(buf) - 1
                local last_line = api.nvim_buf_get_lines(buf, -2, -1, false)
                processed_lines[1] = last_line[1] .. processed_lines[1]
                
                -- Adjust the first line's highlights if we prepended to an existing line
                if color_mode == 'use' and #last_line[1] > 0 and highlight_data[1] then
                    for _, hl in ipairs(highlight_data[1]) do
                        hl[1] = hl[1] + #last_line[1]
                        hl[2] = hl[2] + #last_line[1]
                    end
                end

                api.nvim_buf_set_lines(buf, -2, -1, false, processed_lines)
                
                if color_mode == 'use' then
                    for i, line_highlights in ipairs(highlight_data) do
                        local lnum = start_line + i - 1
                        for _, hl in ipairs(line_highlights) do
                            api.nvim_buf_add_highlight(buf, -1, hl[3], lnum, hl[1], hl[2])
                        end
                    end
                end
                
                local buf_line_count = api.nvim_buf_line_count(buf)
                api.nvim_win_set_cursor(win, {buf_line_count,0})
            end)
            append_result()
        end
    end
    local on_exit = function(code, signal)
        local end_text = string.format('---- End [code %d] [signal %d]', code, signal)
        api.nvim_buf_set_lines(buf, -2, -1, false, {end_text})
        api.nvim_buf_set_var(buf, 'this_buf_can_be_closed', true)
    end
    --api.nvim_buf_set_lines(buf, -2, -1, false, {'---- Start', ''})
    local pid = ut.AsyncProcess(cmd, args, cwd, { env = ev, onread = onread, onexit = on_exit })
    api.nvim_buf_set_var(buf, 'launcher_pid', pid)
    return buf
end

-- WIP
function M.LaunchOnTerm(cmd, args, cwd, ev, hi, position)
    local prjroot_origin = pr.GetCurrentProjectRoot()
    local term_cmd = {}
    local env_script_file
    local concat = table.concat
    if ev then
        env_script_file = vim.fn.tempname()
        local env_script = {}
        if env.os.win then
            env_script_file = env_script_file .. '.bat'
            env_script[#env_script+1] = '@echo off'
        elseif env.os.unix then
        end
        for k, v in pairs(ev) do
            env_script[#env_script+1] = concat{'set ', k, '=', v}
        end
        vim.fn.writefile(env_script, env_script_file)
        vim.list_extend(term_cmd, {env_script_file, ' &'})
    end
    if cwd then
        term_cmd = term_cmd .. 'cd ' .. cwd
    end
    term_cmd = term_cmd .. ' & call ' .. cmd
    for _, a in ipairs(args) do
        term_cmd = term_cmd .. ' ' .. a
    end
    local delete_function = function () end
    if ev then
        if env.os.win then
            delete_function = function () vim.fn.jobstart('del ' .. env_script_file) end
        elseif env.os.unix then
        end
    end
    vim.cmd('vnew')
    local ch = vim.fn.termopen(term_cmd, { on_exit =  delete_function }) 

end

function M.TerminateCurrentLauncherBuffer()
    if vim.b.launcher_pid then
        vim.notify(string.format('Process %d has been terminated',  vim.b.launcher_pid), vim.log.levels.WARN)
        vim.uv.kill(vim.b.launcher_pid, 15) -- terminate process
    end
end

function M.LaunchObject(obj)
    local parent_win_prjroot = pr.GetCurrentProjectRoot()
    local c = pr.GetPrjrootConfig(parent_win_prjroot)
    if c and c[obj] then
        local cmd = c[obj].cmd
        local args = c[obj].args
        local hi = c[obj].highlight
        local color_mode = c[obj].color or 'use'
        local cwd = (c[obj].cwd) and c[obj].cwd:gsub([[^%.]], parent_win_prjroot) or parent_win_prjroot
        local position = (c[obj].position) or { orientation = 'vertical' }
        if not ut.IsExist(cwd) then
            vim.notify(string.format('"%s" is not exist', cwd), vim.log.levels.ERROR)
            return
        end
        local ev = c[obj].env
        if ev then
            local env_cmd = {}
            for key, val in pairs(ev) do
                env_cmd[#env_cmd+1] = string.format("%s=%s", key, val)
            end
            ev = env_cmd
        end
        if position == 'external' then
            ut.AsyncProcess(cmd, args, cwd, { env = ev })
        else
            local parent_win = vim.api.nvim_get_current_win()
            local buf = M.Launch(cmd, args, cwd, ev, hi, position, color_mode)
            --M.LaunchOnTerm(cmd, args, cwd, ev, hi, position)
            api.nvim_buf_set_name(buf, string.format("(%d) %s", buf, obj))
            api.nvim_buf_set_option(buf, 'filetype', 'launcher')
            api.nvim_buf_set_var(buf, 'lc_object', obj)
            api.nvim_buf_set_var(buf, 'lc_parent_win', parent_win)
        end
    end
end

local function BufMapping()
    local c = pr.GetCurrentConfig()
    if c then
        for key, val in pairs(c) do
            if val.key then
                ut.nnoremap(val.key, function() M.LaunchObject(key) end)
            end
        end
    end
end

-- WIP
function M.Jump()
    local c = pr.GetPrjrootConfig(vim.b.prjroot_folder)
    local obj = vim.b.lc_object
    local cwd = (c[obj].cwd) and c[obj].cwd:gsub([[^%.]], vim.b.prjroot_folder) or vim.b.prjroot_folder
    if obj and c[obj] then
        local jmp = c[obj].jmp
        if jmp and jmp.pattern then
            local cur_line = api.nvim_get_current_line()
            local m = { cur_line:match(jmp.pattern) }
            if jmp.file and m[jmp.file] then
                vim.api.nvim_set_current_win(vim.b.lc_parent_win)
                local filename = vim.fn.fnamemodify(cwd, ':p') .. m[jmp.file]
                vim.cmd('execute "edit +' .. m[jmp.row] .. ' ' .. filename .. '"')
            end
        end
    end
end

function M.GetLauncherList()
    local parent_win_prjroot = pr.GetCurrentProjectRoot()
    local c = pr.GetPrjrootConfig(parent_win_prjroot)
    if c then
        local launcher_list = {}
        for launcher_name, _ in pairs(c) do
            launcher_list[#launcher_list+1] = launcher_name
        end
        return launcher_list
    end
end

function M.setup()
    api.nvim_create_autocmd({'BufRead', 'BufNew'}, {callback = BufMapping})
    
    -- Initialize ANSI highlight groups
    local set_hl = vim.api.nvim_set_hl
    set_hl(0, 'AnsiBlack',   { fg = '#000000', bold = true })
    set_hl(0, 'AnsiRed',     { fg = '#ff5555' })
    set_hl(0, 'AnsiGreen',   { fg = '#50fa7b' })
    set_hl(0, 'AnsiYellow',  { fg = '#f1fa8c' })
    set_hl(0, 'AnsiBlue',    { fg = '#8be9fd' })
    set_hl(0, 'AnsiMagenta', { fg = '#ff79c6' })
    set_hl(0, 'AnsiCyan',    { fg = '#8be9fd' })
    set_hl(0, 'AnsiWhite',   { fg = '#f8f8f2' })
end

return M
