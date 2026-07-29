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
    local original_parent_exe

    before_each(function() original_parent_exe = instance.parent_exe end)
    after_each(function() instance.parent_exe = original_parent_exe end)

    local function detect_with(exe)
        instance.parent_exe = function() return exe, { how = 'stub' } end
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

    it('keeps the resolution detail for diagnostics', function()
        assert.are.same({ how = 'stub' }, detect_with('/usr/bin/neovide').detail)
    end)
end)

describe('instance.new', function()
    local original_parent_exe, original_jobstart, original_echo
    local echoed

    before_each(function()
        original_parent_exe = instance.parent_exe
        original_jobstart = vim.fn.jobstart
        original_echo = vim.api.nvim_echo
        echoed = {}
        instance.parent_exe = function() return '/usr/bin/neovide' end
        vim.api.nvim_echo = function(chunks) table.insert(echoed, chunks[1][1]) end
    end)

    after_each(function()
        instance.parent_exe = original_parent_exe
        vim.fn.jobstart = original_jobstart
        vim.api.nvim_echo = original_echo
    end)

    it('stays quiet when the job starts', function()
        vim.fn.jobstart = function() return 7 end
        instance.new('a.txt')
        assert.are.same({}, echoed)
    end)

    it('reports a jobstart failure instead of failing silently', function()
        vim.fn.jobstart = function() return -1 end
        instance.new('a.txt')
        assert.are.equal(1, #echoed)
        assert.is_truthy(echoed[1]:find('jobstart=-1', 1, true))
        assert.is_truthy(echoed[1]:find('/usr/bin/neovide', 1, true))
    end)

    it('reports a jobstart exception instead of failing silently', function()
        vim.fn.jobstart = function() error('E475: not executable') end
        instance.new('a.txt')
        assert.are.equal(1, #echoed)
        assert.is_truthy(echoed[1]:find('E475', 1, true))
        assert.is_truthy(echoed[1]:find('/usr/bin/neovide', 1, true))
    end)

    it('reports when no argv could be built', function()
        local original_build_argv = instance.build_argv
        instance.build_argv = function() return nil, '터미널 없음' end
        vim.fn.jobstart = function() error('jobstart must not run') end

        instance.new()
        instance.build_argv = original_build_argv

        assert.are.equal(1, #echoed)
        assert.is_truthy(echoed[1]:find('터미널 없음', 1, true))
    end)
end)

describe('instance.diagnose', function()
    it('renders every field the detection relied on', function()
        local original = instance.parent_exe
        instance.parent_exe = function() return '/usr/bin/neovide', { how = 'stub' } end
        local out = instance.diagnose()
        instance.parent_exe = original

        for _, field in ipairs{ 'nvim pid', 'progpath', 'detect', 'context', 'argv' } do
            assert.is_truthy(out:find(field, 1, true), 'missing field: ' .. field)
        end
        assert.is_truthy(out:find('/usr/bin/neovide', 1, true))
    end)
end)
