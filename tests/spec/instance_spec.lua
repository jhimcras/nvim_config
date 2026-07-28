local instance = require('instance')

describe('instance.build_argv', function()
    local function ctx(over)
        return vim.tbl_extend('force', { nvim = '/usr/bin/nvim' }, over or {})
    end

    it('reruns the detected GUI executable', function()
        local argv = instance.build_argv(
            { kind = 'gui', exe = '/home/x/workspace/neopp/build/neopp' }, nil, ctx())
        assert.are.same({ '/home/x/workspace/neopp/build/neopp' }, argv)
    end)

    it('appends the file argument', function()
        local argv = instance.build_argv(
            { kind = 'gui', exe = '/usr/bin/neovide' }, 'a.txt', ctx())
        assert.are.same({ '/usr/bin/neovide', 'a.txt' }, argv)
    end)

    it('errors when the GUI path is unknown', function()
        local argv, err = instance.build_argv({ kind = 'gui' }, nil, ctx())
        assert.is_nil(argv)
        assert.is_string(err)
    end)

    it('opens a tmux window when inside tmux', function()
        local argv = instance.build_argv(
            { kind = 'tui' }, 'a.txt', ctx{ tmux = '/tmp/tmux-1000/default,1,0' })
        assert.are.same({ 'tmux', 'new-window', '--', '/usr/bin/nvim', 'a.txt' }, argv)
    end)

    it('prefers tmux over the windows branches', function()
        local argv = instance.build_argv(
            { kind = 'tui' }, nil,
            ctx{ win = true, wt = 'abc', tmux = '/tmp/tmux', nvim = 'C:\\nvim.exe' })
        assert.are.same({ 'tmux', 'new-window', '--', 'C:\\nvim.exe' }, argv)
    end)

    it('opens a new Windows Terminal window', function()
        local argv = instance.build_argv(
            { kind = 'tui' }, nil, ctx{ win = true, wt = 'abc', nvim = 'C:\\nvim.exe' })
        assert.are.same({ 'wt.exe', '-w', '-1', 'C:\\nvim.exe' }, argv)
    end)

    it('falls back to a new console on windows', function()
        local argv = instance.build_argv(
            { kind = 'tui' }, 'a.txt', ctx{ win = true, nvim = 'C:\\nvim.exe' })
        assert.are.same({ 'cmd.exe', '/c', 'start', '', 'C:\\nvim.exe', 'a.txt' }, argv)
    end)

    it('uses -e for a generic terminal', function()
        local argv = instance.build_argv(
            { kind = 'tui' }, nil, ctx{ term_exe = '/usr/bin/alacritty' })
        assert.are.same({ '/usr/bin/alacritty', '-e', '/usr/bin/nvim' }, argv)
    end)

    it('passes the command directly to kitty', function()
        local argv = instance.build_argv(
            { kind = 'tui' }, nil, ctx{ term_exe = '/usr/bin/kitty' })
        assert.are.same({ '/usr/bin/kitty', '/usr/bin/nvim' }, argv)
    end)

    it('uses start -- for wezterm', function()
        local argv = instance.build_argv(
            { kind = 'tui' }, nil, ctx{ term_exe = '/usr/bin/wezterm-gui' })
        assert.are.same({ '/usr/bin/wezterm-gui', 'start', '--', '/usr/bin/nvim' }, argv)
    end)

    it('errors when no terminal was found', function()
        local argv, err = instance.build_argv({ kind = 'tui' }, nil, ctx())
        assert.is_nil(argv)
        assert.is_string(err)
    end)
end)

describe('instance.detect', function()
    local original_exe_of_pid, original_getppid

    before_each(function()
        original_exe_of_pid = instance.exe_of_pid
        original_getppid = vim.uv.os_getppid
        vim.uv.os_getppid = function() return 4242 end
    end)

    after_each(function()
        instance.exe_of_pid = original_exe_of_pid
        vim.uv.os_getppid = original_getppid
    end)

    local function detect_with(exe)
        instance.exe_of_pid = function() return exe end
        return instance.detect()
    end

    it('treats a neopp parent as a GUI and keeps its absolute path', function()
        local d = detect_with('/home/x/workspace/neopp/build/neopp')
        assert.are.equal('gui', d.kind)
        assert.are.equal('/home/x/workspace/neopp/build/neopp', d.exe)
        assert.are.equal('neopp', d.name)
    end)

    it('treats neovide as a GUI', function()
        assert.are.equal('gui', detect_with('/usr/bin/neovide').kind)
    end)

    it('strips .exe when classifying', function()
        local d = detect_with('C:\\Program Files\\neopp\\neopp.exe')
        assert.are.equal('gui', d.kind)
        assert.are.equal('neopp', d.name)
    end)

    it('treats an nvim parent as a TUI', function()
        assert.are.equal('tui', detect_with('/usr/bin/nvim').kind)
    end)

    it('treats a shell parent as a TUI', function()
        assert.are.equal('tui', detect_with('/bin/bash').kind)
    end)

    it('falls back to TUI when the parent cannot be resolved', function()
        local d = detect_with(nil)
        assert.are.equal('tui', d.kind)
        assert.is_nil(d.exe)
    end)
end)
