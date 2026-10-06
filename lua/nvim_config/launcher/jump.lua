local M = {}

local registry = require('nvim_config.launcher.registry')
local running_processes = registry.processes
local api = vim.api
local pr = require('nvim_config.prjroot')
local util_buffer = require('nvim_config.util.buffer')
local util_serialize = require('nvim_config.util.serialize')

function M.GetMatches(buf)
    buf = buf == 0 and api.nvim_get_current_buf() or buf
    local proc = running_processes[buf]
    if proc and proc.matches then return proc.matches end
    local ok, matches = pcall(api.nvim_buf_get_var, buf, 'launcher_matches')
    return ok and matches or {}
end

function M.NextMatch()
    local matches = M.GetMatches(0)
    local cur_line = api.nvim_win_get_cursor(0)[1]
    for _, m in ipairs(matches) do
        if m.lnum > cur_line then
            api.nvim_win_set_cursor(0, { m.lnum, 0 })
            return
        end
    end
    -- Wrap around
    if #matches > 0 then
        api.nvim_win_set_cursor(0, { matches[1].lnum, 0 })
    end
end

function M.PrevMatch()
    local matches = M.GetMatches(0)
    local cur_line = api.nvim_win_get_cursor(0)[1]
    for i = #matches, 1, -1 do
        local m = matches[i]
        if m.lnum < cur_line then
            api.nvim_win_set_cursor(0, { m.lnum, 0 })
            return
        end
    end
    -- Wrap around
    if #matches > 0 then
        api.nvim_win_set_cursor(0, { matches[#matches].lnum, 0 })
    end
end

local function ResolveLauncherFilename(filename, bases)
    local normalized = util_serialize.normalize_path_separator(filename)
    for _, base in ipairs(bases) do
        local path = base and (base .. '/' .. normalized) or normalized
        local full = vim.fn.fnamemodify(path, ':p')
        if util_buffer.IsExist(full) then
            return full
        end
    end
    return nil
end

local function SearchLauncherFileCandidates(prjroot, filename)
    if not prjroot or vim.fn.executable('rg') ~= 1 then
        return {}
    end
    local suffix = util_serialize.normalize_path_separator(filename)
    while suffix:match('^%.%./') do
        suffix = suffix:sub(4)
    end
    local candidates = vim.fn.systemlist({ 'rg', '--files', '-g', '**/' .. suffix, prjroot })
    if #candidates == 0 then
        local basename = vim.fn.fnamemodify(suffix, ':t')
        candidates = vim.fn.systemlist({ 'rg', '--files', '-g', '**/' .. basename, prjroot })
    end
    return candidates
end

-- Never target a window showing the launcher buffer (lc_parent_win may point at it).
local function FindSafeJumpWindow(exclude_buf)
    local candidates = { vim.b.lc_parent_win, vim.fn.win_getid(vim.fn.winnr('#')) }
    for _, w in ipairs(candidates) do
        if w and w ~= 0 and api.nvim_win_is_valid(w) and api.nvim_win_get_buf(w) ~= exclude_buf then
            return w
        end
    end
    for _, w in ipairs(api.nvim_list_wins()) do
        if api.nvim_win_get_buf(w) ~= exclude_buf then
            return w
        end
    end
    return nil
end

local function OpenLauncherCandidateQuickfix(candidates, match)
    local items = {}
    for _, path in ipairs(candidates) do
        table.insert(items, {
            filename = path,
            lnum = tonumber(match.row) or 1,
            col = match.column and tonumber(match.column) or 1,
            text = path,
        })
    end
    vim.fn.setqflist({}, ' ', {
        title = 'launcher: select file for ' .. match.filename,
        items = items,
    })
    vim.cmd('copen')
end

function M.Jump()
    local matches = M.GetMatches(0)
    local cur_line = api.nvim_win_get_cursor(0)[1]
    local match = nil
    if matches then
        for _, m in ipairs(matches) do
            if m.lnum == cur_line then
                match = m
                break
            end
        end
    end

    if not match then
        -- Not in matches: parse the current line directly
        local line = api.nvim_get_current_line()
        local prjroot = vim.b.prjroot_folder or pr.GetCurrentProjectRoot()
        local c = pr.GetPrjrootConfig(prjroot)
        local obj = vim.b.lc_object
        if c and c.launchers and c.launchers[obj] and c.launchers[obj].patterns then
            for _, pcfg in pairs(c.launchers[obj].patterns) do
                local m = { line:match(pcfg.pattern) }
                if #m > 0 and pcfg.extract then
                    match = {}
                    for idx, field in ipairs(pcfg.extract) do
                        if field ~= '' and m[idx] then
                            match[field] = m[idx]
                        end
                    end
                    if pcfg.base_dir then
                        match.base_dir = pcfg.base_dir(match, line)
                    end
                    break
                end
            end
        end
        -- Legacy jmp pattern
        if not match and c and c.launchers and c.launchers[obj] and c.launchers[obj].jmp then
            local jmp = c.launchers[obj].jmp
            local m = { line:match(jmp.pattern) }
            if jmp.file and m[jmp.file] then
                match = {
                    filename = m[jmp.file],
                    row = jmp.row and m[jmp.row] or 1,
                    column = jmp.col and m[jmp.col] or 1
                }
            end
        end
    end

    if match and match.filename then
        local launcher_buf = api.nvim_get_current_buf()
        local prjroot = vim.b.prjroot_folder or pr.GetCurrentProjectRoot()
        local filename = ResolveLauncherFilename(match.filename, { nil, match.base_dir, prjroot })
        local candidates

        if not filename then
            candidates = SearchLauncherFileCandidates(prjroot, match.filename)
            if #candidates == 1 then
                filename = vim.fn.fnamemodify(candidates[1], ':p')
            elseif #candidates == 0 then
                vim.notify('launcher: cannot resolve file: ' .. match.filename, vim.log.levels.WARN)
                return
            end
        end

        -- Switch windows only when opening something, never into the launcher.
        local target_win = FindSafeJumpWindow(launcher_buf)
        if target_win then
            api.nvim_set_current_win(target_win)
        else
            vim.cmd('vsplit')
        end

        if filename then
            local edit_cmd = string.format('edit +%s %s', match.row or 1, vim.fn.fnameescape(filename))
            vim.cmd(edit_cmd)
            if match.column then
                api.nvim_win_set_cursor(0, { tonumber(match.row or 1), tonumber(match.column) - 1 })
            end
        else
            OpenLauncherCandidateQuickfix(candidates, match)
        end
    end
end


return M
