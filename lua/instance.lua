-- Detect the process hosting the current nvim and spawn a new instance of the
-- same kind. GUI clients (neopp, neovide, nvim-qt, ...) all launch `nvim
-- --embed` as a child, so our parent process *is* the GUI; for a TUI the parent
-- is the nvim TUI wrapper itself.
local env = require 'env'

local M = {}

-- Parents that are not a UI host: seeing one of these means we're a plain TUI
-- (or a bare `nvim --listen` started from a shell).
local NOT_UI = {
    nvim = true, bash = true, zsh = true, fish = true, sh = true, dash = true,
    cmd = true, powershell = true, pwsh = true, tmux = true, systemd = true,
    init = true, login = true,
}

local TERMINALS = {
    alacritty = true, kitty = true, wezterm = true, ['wezterm-gui'] = true,
    foot = true, ghostty = true, xterm = true, konsole = true,
    ['gnome-terminal-server'] = true, st = true, urxvt = true,
}

local function basename(path)
    local base = path:match('([^/\\]+)$') or path
    return (base:lower():gsub('%.exe$', ''))
end

-- Resolves our parent's executable, plus a detail table describing the attempt
-- so :NewInstance! can show why it failed.
function M.parent_exe()
    if env.os.win then
        -- Ask for the parent's path in one shot: uv.os_getppid() is not reliable
        -- everywhere on Windows, and Win32_Process knows our parent from our own
        -- pid. PowerShell can take seconds to start cold, hence the long wait.
        local script = string.format(
            '$p = Get-CimInstance Win32_Process -Filter "ProcessId=%d"; '
            .. 'if ($p) { (Get-Process -Id $p.ParentProcessId).Path }',
            vim.uv.os_getpid())
        local ok, res = pcall(function()
            return vim.system({
                'powershell', '-NoProfile', '-NonInteractive', '-Command', script,
            }, { text = true }):wait(15000)
        end)
        if not ok then
            return nil, { how = 'powershell', error = tostring(res) }
        end
        local out = vim.trim(res.stdout or '')
        local detail = {
            how = 'powershell',
            code = res.code,
            stdout = out,
            stderr = vim.trim(res.stderr or ''),
        }
        if res.code ~= 0 or out == '' then return nil, detail end
        return out, detail
    end

    local ppid = vim.uv.os_getppid()
    local detail = { how = '/proc', ppid = ppid }
    if not ppid then return nil, detail end
    local exe = vim.uv.fs_readlink('/proc/' .. ppid .. '/exe')
    return exe, detail
end

function M.detect()
    local exe, detail = M.parent_exe()
    if not exe then
        return { kind = 'tui', detail = detail }
    end
    local base = basename(exe)
    if NOT_UI[base] then
        return { kind = 'tui', name = base, detail = detail }
    end
    return { kind = 'gui', exe = exe, name = base, detail = detail }
end

-- Walk up the process tree looking for a known terminal emulator. Unix only.
local function terminal_from_ancestry()
    local pid = vim.uv.os_getppid()
    for _ = 1, 8 do
        local stat = io.open('/proc/' .. pid .. '/stat')
        if not stat then return nil end
        local line = stat:read('*l')
        stat:close()
        if not line then return nil end
        -- comm is parenthesised and may contain spaces; ppid follows the state field.
        local comm, ppid = line:match('%((.*)%)%s+%S+%s+(%d+)')
        if not comm then return nil end
        if TERMINALS[comm:lower()] then
            return vim.uv.fs_readlink('/proc/' .. pid .. '/exe')
        end
        pid = tonumber(ppid)
        if not pid or pid <= 1 then return nil end
    end
    return nil
end

function M.find_terminal()
    local from_env = os.getenv('TERMINAL')
    if from_env and from_env ~= '' then
        local path = vim.fn.exepath(from_env)
        if path ~= '' then return path end
    end
    local from_tree = terminal_from_ancestry()
    if from_tree then return from_tree end
    local prog = os.getenv('TERM_PROGRAM')
    if prog and prog ~= '' then
        local path = vim.fn.exepath(prog)
        if path ~= '' then return path end
    end
    return nil
end

-- Pure: builds the argv for a new instance. ctx is injected by M.new().
function M.build_argv(detected, file, ctx)
    local function argv(...)
        local out = { ... }
        if file then table.insert(out, file) end
        return out
    end

    if detected.kind == 'gui' then
        if not detected.exe then
            return nil, 'GUI 실행파일 경로를 찾지 못했습니다'
        end
        return argv(detected.exe)
    end

    if ctx.tmux and ctx.tmux ~= '' then
        return argv('tmux', 'new-window', '--', ctx.nvim)
    end

    if ctx.win then
        if ctx.wt and ctx.wt ~= '' then
            return argv('wt.exe', '-w', '-1', ctx.nvim)
        end
        return argv('cmd.exe', '/c', 'start', '', ctx.nvim)
    end

    if ctx.term_exe then
        local base = basename(ctx.term_exe)
        if base == 'kitty' then
            return argv(ctx.term_exe, ctx.nvim)
        elseif base == 'wezterm' or base == 'wezterm-gui' then
            return argv(ctx.term_exe, 'start', '--', ctx.nvim)
        end
        return argv(ctx.term_exe, '-e', ctx.nvim)
    end

    return nil, '터미널 에뮬레이터를 찾지 못했습니다'
end

function M.context(detected)
    local ctx = {
        win = env.os.win,
        tmux = os.getenv('TMUX'),
        wt = os.getenv('WT_SESSION'),
        nvim = vim.v.progpath,
    }
    if detected.kind == 'tui' and not env.os.win and not (ctx.tmux and ctx.tmux ~= '') then
        ctx.term_exe = M.find_terminal()
    end
    return ctx
end

-- nvim_echo with history, so the message survives a GUI that swallows
-- vim.notify and can always be recovered with :messages.
local function report(msg)
    vim.api.nvim_echo({ { 'NewInstance: ' .. msg, 'ErrorMsg' } }, true, {})
end

function M.new(file)
    local detected = M.detect()
    local ctx = M.context(detected)

    local args, err = M.build_argv(detected, file, ctx)
    if not args then
        report(err .. '  (자세한 내용은 :NewInstance!)')
        return
    end

    -- jobstart throws on a non-executable command and returns <= 0 on bad
    -- arguments; both must be reported or the command fails silently.
    local ok, job = pcall(vim.fn.jobstart, args, { detach = true })
    if not ok then
        report(string.format('실행 실패: %s  --  %s  (자세한 내용은 :NewInstance!)',
            tostring(job), table.concat(args, ' ')))
    elseif job <= 0 then
        report(string.format('실행 실패 (jobstart=%d): %s  (자세한 내용은 :NewInstance!)',
            job, table.concat(args, ' ')))
    end
end

-- :NewInstance! — dumps everything the detection relied on to :messages.
function M.diagnose()
    local detected = M.detect()
    local ctx = M.context(detected)
    local args, err = M.build_argv(detected, nil, ctx)
    return table.concat({
        'NewInstance diagnostics',
        'nvim pid : ' .. vim.uv.os_getpid(),
        'progpath : ' .. vim.v.progpath,
        'detect   : ' .. vim.inspect(detected),
        'context  : ' .. vim.inspect(ctx),
        'argv     : ' .. (args and vim.inspect(args) or ('nil  -- ' .. tostring(err))),
    }, '\n')
end

return M
