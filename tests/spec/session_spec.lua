local session = require('nvim_config.session')
local original_stdpath = vim.fn.stdpath
local test_data_dir = vim.fn.tempname()
vim.fn.mkdir(test_data_dir, 'p')
vim.fn.stdpath = function(what)
    if what == 'data' then
        return test_data_dir
    end
    return original_stdpath(what)
end

local function make_sessions_dir()
    local dir = vim.fn.stdpath('data') .. '/sessions'
    vim.fn.mkdir(dir, 'p')
    return dir
end

describe('session.SessionList', function()
    local sessions_dir
    local test_files

    before_each(function()
        sessions_dir = make_sessions_dir()
        test_files = {}
    end)

    after_each(function()
        for _, f in ipairs(test_files) do
            vim.fn.delete(f)
        end
    end)

    local function touch(name)
        local path = sessions_dir .. '/' .. name
        local f = assert(io.open(path, 'w'))
        f:close()
        table.insert(test_files, path)
    end

    -- Collect only test-owned names from a SessionList result
    local function owned(list)
        local names = {}
        for _, n in ipairs(list) do
            if n:match('^__test__') then
                table.insert(names, n)
            end
        end
        table.sort(names)
        return names
    end

    it('excludes .qf.lua auxiliary files', function()
        touch('__test__session')
        touch('__test__session.qf.lua')

        assert.same({'__test__session'}, owned(session.SessionList('')))
    end)

    it('excludes .loc.*.lua auxiliary files', function()
        touch('__test__session')
        touch('__test__session.loc.99999.lua')

        assert.same({'__test__session'}, owned(session.SessionList('')))
    end)

    it('excludes plain .lua files', function()
        touch('__test__session')
        touch('__test__config.lua')

        assert.same({'__test__session'}, owned(session.SessionList('')))
    end)

    it('returns multiple session files when arglead is empty', function()
        touch('__test__alpha')
        touch('__test__beta')
        touch('__test__alpha.qf.lua')

        assert.same({'__test__alpha', '__test__beta'}, owned(session.SessionList('')))
    end)

    it('filters by prefix: only names starting with arglead are returned', function()
        touch('__test__foo')
        touch('__test__foobar')
        touch('__test__baz')

        assert.same({'__test__foo', '__test__foobar'}, owned(session.SessionList('__test__foo')))
    end)

    it('prefix that matches nothing returns empty', function()
        touch('__test__something')

        assert.same({}, owned(session.SessionList('__test__nothing_matches_xyz')))
    end)

    it('nil arglead behaves like empty string', function()
        touch('__test__x')

        local names = owned(session.SessionList(nil))
        assert.truthy(vim.tbl_contains(names, '__test__x'))
    end)
end)

describe('session.SaveSession', function()
    it('saves a session and updates tabline without error', function()
        local session_name = '__test__new_session'
        local sessions_dir = vim.fn.stdpath('data') .. '/sessions'
        vim.fn.mkdir(sessions_dir, 'p')
        local session_path = sessions_dir .. '/' .. session_name

        -- Mock vim.cmd and vim.notify to avoid side effects
        local original_cmd = vim.cmd
        local original_notify = vim.notify
        local original_go = vim.go
        vim.cmd = setmetatable({}, { __index = original_cmd, __call = function() end })
        vim.notify = function() end
        vim.go = { tabline = '' }

        -- Ensure tabline module is loaded and has TabLine function
        package.loaded['nvim_config.tabline'] = package.loaded['nvim_config.tabline'] or {
            TabLine = function() return 'mock_tabline' end
        }

        local status, err = pcall(session.SaveSession, session_name)
        
        -- Restore originals
        vim.cmd = original_cmd
        vim.notify = original_notify
        vim.go = original_go

        if not status then
            error('SaveSession failed: ' .. tostring(err))
        end
        
        assert.is_true(status)
    end)
end)

describe('launcher session highlights', function()
    it('saves and restores ANSI and custom color highlights', function()
        local launcher = require('nvim_config.launcher')
        local name = '__test__launcher_highlights'
        local dir = make_sessions_dir()
        local previous = vim.api.nvim_get_current_buf()
        local buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_win_set_buf(0, buf)
        vim.bo[buf].buftype = 'nofile'
        vim.bo[buf].filetype = 'launcher'
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'red blue', 'custom' })
        vim.b[buf].lc_object = 'build'
        vim.b[buf].lc_command = 'make'
        vim.b[buf].launcher_status = 'done'
        local ns = vim.api.nvim_create_namespace('launcher_highlights')
        vim.hl.range(buf, ns, 'AnsiRed', { 0, 0 }, { 0, 3 }, {})
        vim.hl.range(buf, ns, 'LauncherHL_BB0000', { 1, 0 }, { 1, 6 }, {})

        session.SaveSession(name)
        local file = string.format('%s/%s.launcher.lua.%d.lua', dir, name, vim.api.nvim_get_current_win())
        local saved = vim.json.decode(table.concat(vim.fn.readfile(file), '\n'))
        assert.are.same({ { 0, 0, 3, 'AnsiRed' }, { 1, 0, 6, 'LauncherHL_BB0000' } }, saved.highlights)

        vim.api.nvim_set_hl(0, 'LauncherHL_BB0000', {})
        local restored = launcher.Restore(saved)
        assert.are.same(saved.content, vim.api.nvim_buf_get_lines(restored, 0, -1, false))
        assert.are.same(saved.highlights, launcher.GetHighlights(restored))
        assert.are.equal(0xBB0000, vim.api.nvim_get_hl(0, { name = 'LauncherHL_BB0000' }).fg)

        vim.api.nvim_win_set_buf(0, previous)
        vim.api.nvim_buf_delete(restored, { force = true })
        vim.api.nvim_buf_delete(buf, { force = true })
        for _, path in ipairs(vim.fn.glob(dir .. '/' .. name .. '*', false, true)) do
            vim.fn.delete(path)
        end
    end)
end)

describe('session cmdheight round trip', function()
    local sessions_dir
    local session_name = '__test__cmdheight'

    local function save_and_load(saved_cmdheight, before_load)
        vim.o.cmdheight = saved_cmdheight
        session.SaveSession(session_name)
        vim.o.cmdheight = before_load
        session.OpenSession(session_name)
    end

    before_each(function()
        sessions_dir = make_sessions_dir()
        pcall(vim.cmd, 'silent! tabonly!')
        pcall(vim.cmd, 'silent! only!')
        -- OpenSession bails out behind a confirm() prompt when a buffer is
        -- modified, and confirm() answers 0 in a headless run.
        for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
            pcall(function() vim.bo[bufnr].modified = false end)
        end
    end)

    after_each(function()
        vim.o.cmdheight = 1
        for _, f in ipairs(vim.fn.glob(sessions_dir .. '/' .. session_name .. '*', false, true)) do
            vim.fn.delete(f)
        end
    end)

    it('normalises cmdheight after loading a session', function()
        -- Nothing in the session script restores cmdheight, so a value inflated
        -- before the load used to survive it.
        save_and_load(1, 7)
        assert.are.equal(1, vim.o.cmdheight)
    end)

    it('normalises cmdheight left inflated when the session was saved', function()
        save_and_load(5, 7)
        assert.are.equal(1, vim.o.cmdheight)
    end)
end)

describe('session command completion', function()
    it('resolves SaveSession completion through the session module', function()
        local original = session.SessionList
        session.SessionList = function() return { 'completion-session' } end
        session.setup()
        local ok, completions = pcall(vim.fn.getcompletion, 'SaveSession ', 'cmdline')
        session.SessionList = original
        assert.is_true(ok)
        assert.are.same({ 'completion-session' }, completions)
    end)
end)

describe('session cmdheight fix on VimEnter', function()
    after_each(function()
        vim.o.cmdheight = 1
        vim.v.this_session = ''
    end)

    it('normalises cmdheight on VimEnter when started with a session', function()
        session.setup()
        vim.o.cmdheight = 7
        vim.v.this_session = '/tmp/__test__fake_session'
        vim.api.nvim_exec_autocmds('VimEnter', {})
        assert.are.equal(1, vim.o.cmdheight)
    end)

    it('leaves cmdheight untouched on VimEnter without a session', function()
        session.setup()
        vim.o.cmdheight = 7
        vim.v.this_session = ''
        vim.api.nvim_exec_autocmds('VimEnter', {})
        assert.are.equal(7, vim.o.cmdheight)
    end)

    it('normalises cmdheight on VimResized when started with a session', function()
        session.setup()
        vim.o.cmdheight = 7
        vim.v.this_session = '/tmp/__test__fake_session'
        vim.api.nvim_exec_autocmds('VimResized', {})
        assert.are.equal(1, vim.o.cmdheight)
    end)

    it('normalises cmdheight on TabEnter', function()
        session.setup()
        vim.o.cmdheight = 7
        vim.api.nvim_exec_autocmds('TabEnter', {})
        assert.are.equal(1, vim.o.cmdheight)
    end)

    it('normalises cmdheight on VimResized without a session', function()
        session.setup()
        vim.o.cmdheight = 7
        vim.v.this_session = ''
        vim.api.nvim_exec_autocmds('VimResized', {})
        assert.are.equal(1, vim.o.cmdheight)
    end)
end)

describe('session QuitPre exit guard', function()
    local launcher = require('nvim_config.launcher')
    local original_confirm
    local original_get_running_processes
    local original_cmd
    local confirm_msg
    local confirm_choices
    local confirm_default
    local confirm_result

    local function cleanup_buffers()
        for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
            if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr) then
                pcall(function()
                    vim.bo[bufnr].modified = false
                end)
            end
        end
        for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
            if vim.api.nvim_buf_is_valid(bufnr) and bufnr ~= vim.api.nvim_get_current_buf() then
                pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
            end
        end
    end

    local function setup_exit_guard()
        pcall(vim.api.nvim_del_user_command, 'SaveSession')
        pcall(vim.api.nvim_del_user_command, 'RemoveSession')
        pcall(vim.api.nvim_del_user_command, 'CloseSession')
        pcall(vim.api.nvim_del_user_command, 'SessionQuitAll')
        session.setup()

        for _, au in ipairs(vim.api.nvim_get_autocmds({ event = 'QuitPre', group = 'ExitGuard' })) do
            if au.callback then
                return au.callback
            end
        end
        error('ExitGuard QuitPre callback not found')
    end

    local function make_modified_unnamed_buffer()
        local bufnr = vim.api.nvim_create_buf(true, false)
        vim.api.nvim_set_current_buf(bufnr)
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'draft' })
        vim.bo[bufnr].modified = true
        return bufnr
    end

    local function make_running_launcher(filetype, modified)
        local bufnr = vim.api.nvim_create_buf(true, false)
        vim.bo[bufnr].filetype = filetype
        vim.b[bufnr].lc_object = 'Hidden build'
        vim.bo[bufnr].modified = modified or false
        local stopped = false
        launcher.RegisterProcess(bufnr, {
            type = filetype == 'terminal' and 'terminal' or 'general',
            obj = 'Hidden build',
            buf = bufnr,
            terminate = function(signal) stopped = signal == 15 end,
        })
        session.get_running_processes = original_get_running_processes
        return bufnr, function() return stopped end
    end

    before_each(function()
        cleanup_buffers()
        confirm_msg = nil
        confirm_choices = nil
        confirm_default = nil
        confirm_result = 1
        original_confirm = vim.fn.confirm
        original_get_running_processes = session.get_running_processes
        original_cmd = vim.cmd
        vim.fn.confirm = function(msg, choices, default)
            confirm_msg = msg
            confirm_choices = choices
            confirm_default = default
            return confirm_result
        end
        session.get_running_processes = function()
            return {}
        end
        vim.cmd = function(cmd)
            if cmd ~= 'redraw' then
                original_cmd(cmd)
            end
        end
    end)

    after_each(function()
        vim.fn.confirm = original_confirm
        session.get_running_processes = original_get_running_processes
        vim.cmd = original_cmd
        for buf in pairs(launcher.running_processes) do
            launcher.UnregisterProcess(buf)
        end
        pcall(vim.cmd, 'silent! tabonly!')
        pcall(vim.cmd, 'silent! only!')
        cleanup_buffers()
    end)

    it('clears a modified unnamed buffer when Ignore is selected for :qa', function()
        local callback = setup_exit_guard()
        local bufnr = make_modified_unnamed_buffer()

        callback()

        assert.is_false(vim.bo[bufnr].modified)
        assert.truthy(confirm_msg:find('Global Unsaved buffers:\n  %[No Name%]', 1))
        assert.truthy(confirm_msg:find('Ignore and Continue?', 1, true))
        assert.same('&Ignore\n&Cancel', confirm_choices)
        assert.same(2, confirm_default)
    end)

    it('preserves a modified unnamed buffer after Cancel and guards the next quit attempt', function()
        local callback = setup_exit_guard()
        local bufnr = make_modified_unnamed_buffer()

        confirm_result = 2
        local ok = pcall(callback)

        assert.is_true(ok)
        assert.is_true(vim.bo[bufnr].modified)
        assert.same('&Ignore\n&Cancel', confirm_choices)

        confirm_result = 1
        callback()

        assert.is_false(vim.bo[bufnr].modified)
    end)

    it('SessionQuitAll returns cleanly on Cancel and preserves changes', function()
        setup_exit_guard()
        local bufnr = make_modified_unnamed_buffer()

        confirm_result = 2
        local ok = pcall(vim.cmd, 'SessionQuitAll')

        assert.is_true(ok)
        assert.is_true(vim.bo[bufnr].modified)
        assert.same('&Ignore\n&Cancel', confirm_choices)
    end)

    it('uses stop-oriented confirmation and terminates running processes', function()
        local terminated = false
        session.get_running_processes = function()
            return {
                {
                    obj = 'Build',
                    terminate = function(signal)
                        terminated = signal == 15
                    end,
                },
            }
        end
        local callback = setup_exit_guard()

        callback()

        assert.is_true(terminated)
        assert.truthy(confirm_msg:find('Other running processes:\n  Build', 1, true))
        assert.truthy(confirm_msg:find('Stop and Continue?', 1, true))
        assert.same('&Stop and Continue\n&Cancel', confirm_choices)
        assert.same(2, confirm_default)
    end)

    it('uses combined wording for running processes and unsaved buffers', function()
        session.get_running_processes = function()
            return {
                {
                    obj = 'Build',
                    terminate = function() end,
                },
            }
        end
        local callback = setup_exit_guard()
        local bufnr = make_modified_unnamed_buffer()

        callback()

        assert.is_false(vim.bo[bufnr].modified)
        assert.truthy(confirm_msg:find('Other running processes:\n  Build', 1, true))
        assert.truthy(confirm_msg:find('Global Unsaved buffers:\n  %[No Name%]', 1))
        assert.truthy(confirm_msg:find('Stop processes, ignore unsaved changes, and continue?', 1, true))
        assert.same('&Stop and Ignore\n&Cancel', confirm_choices)
        assert.same(2, confirm_default)
    end)

    it('guards a hidden launcher in a clean buffer on programmatic :qa', function()
        setup_exit_guard()
        local buf, stopped = make_running_launcher('launcher', false)
        confirm_result = 2

        vim.cmd('qa')

        assert.truthy(confirm_msg:find('Hidden build', 1, true))
        assert.same('&Stop and Continue\n&Cancel', confirm_choices)
        assert.same(2, confirm_default)
        assert.is_not_nil(launcher.running_processes[buf])
        assert.is_false(stopped())
    end)

    it('guards all programmatic quit-all and write-quit aliases', function()
        setup_exit_guard()
        local buf, stopped = make_running_launcher('launcher', false)
        confirm_result = 2

        for _, command in ipairs({ 'qa', 'qall', 'quita', 'quitall', 'wqa', 'wqall', 'xa', 'xall' }) do
            confirm_msg = nil
            vim.cmd(command)
            assert.truthy(confirm_msg and confirm_msg:find('Hidden build', 1, true), command)
            assert.is_not_nil(launcher.running_processes[buf])
            assert.is_false(stopped())
        end
    end)

    it('guards a terminal launcher on another tab and preserves a modified buffer on Cancel', function()
        setup_exit_guard()
        local buf, stopped = make_running_launcher('terminal', true)
        vim.cmd('tabnew')
        confirm_result = 2

        vim.cmd('qall')

        assert.truthy(confirm_msg:find('Hidden build', 1, true))
        assert.same('&Stop and Ignore\n&Cancel', confirm_choices)
        assert.is_true(vim.bo[buf].modified)
        assert.is_false(stopped())
        assert.is_not_nil(launcher.running_processes[buf])
    end)

    it('includes hidden launcher and external processes when Stop is selected', function()
        local callback = setup_exit_guard()
        local buf, stopped = make_running_launcher('launcher', false)
        local external_stopped = false
        launcher.RegisterProcess('external-test', {
            obj = 'External build',
            terminate = function(signal) external_stopped = signal == 15 end,
        })

        callback()

        assert.truthy(confirm_msg:find('Hidden build', 1, true))
        assert.truthy(confirm_msg:find('External build', 1, true))
        assert.is_true(stopped())
        assert.is_true(external_stopped)
    end)

    it('lets bang quit-all commands exit without confirmation or unsaved-buffer blocking', function()
        local script_path = vim.fn.tempname() .. '.lua'
        local log_path = vim.fn.tempname()
        local script = string.format([[
            local session = require('nvim_config.session')
            local launcher = require('nvim_config.launcher')
            session.setup()
            local buf = vim.api.nvim_create_buf(true, false)
            vim.bo[buf].filetype = 'launcher'
            launcher.RegisterProcess(buf, { obj = 'Build', terminate = function() end })
            vim.api.nvim_set_current_buf(buf)
            local confirms = 0
            vim.fn.confirm = function() confirms = confirms + 1; return 2 end
            vim.api.nvim_create_autocmd('VimLeavePre', {
                callback = function() vim.fn.writefile({ tostring(confirms) }, %q) end,
            })
            vim.bo[buf].modified = %s
            vim.cmd(%q)
            vim.fn.writefile({ 'did not exit' }, %q)
            vim.cmd('qa!')
        ]], log_path, '%s', '%s', log_path)

        for _, command in ipairs({ 'qa!', 'qall!', 'wqa!', 'xa!' }) do
            local dirty = command == 'qa!' or command == 'qall!'
            vim.fn.writefile(vim.split(script:format(tostring(dirty), command), '\n'), script_path)
            vim.fn.delete(log_path)
            vim.fn.system({ 'nvim', '--headless', '-u', 'NONE', '--cmd', 'set rtp^=' .. vim.fn.getcwd(), '-c', 'luafile ' .. script_path })
            assert.same({ '0' }, vim.fn.readfile(log_path), command)
        end

        vim.fn.delete(script_path)
        vim.fn.delete(log_path)
    end)
end)


describe('session list size caps', function()
    local lists = require('nvim_config.session.lists')
    local dir, name

    before_each(function()
        dir = make_sessions_dir()
        name = '__test__caps'
    end)

    after_each(function()
        vim.cmd('silent! cclose')
        vim.fn.setqflist({}, 'f')
        for _, path in ipairs(vim.fn.glob(dir .. '/' .. name .. '*', false, true)) do
            vim.fn.delete(path)
        end
    end)

    local function read_json(path)
        return vim.json.decode(table.concat(vim.fn.readfile(path), '\n'))
    end

    local function launcher_bufs(obj)
        return vim.tbl_filter(function(b)
            return vim.bo[b].filetype == 'launcher' and vim.b[b].lc_object == obj
        end, vim.api.nvim_list_bufs())
    end

    it('saves the first 20000 quickfix items as JSON and clamps selection', function()
        local file = vim.fn.tempname()
        local items = {}
        for i = 1, 20005 do items[i] = { filename = file, lnum = i, text = 'item ' .. i } end
        vim.fn.setqflist({}, ' ', { title = 'big', items = items })
        vim.fn.setqflist({}, 'r', { idx = 20003 })
        vim.cmd('copen')
        lists.save(dir .. '/' .. name)
        vim.cmd('cclose')

        local saved = read_json(dir .. '/' .. name .. '.qf.lua')
        assert.equals(20000, #saved.items)
        assert.equals('item 20000', saved.items[20000].text)
        assert.equals(20000, saved.selection)
    end)

    it('saves the last 10000 launcher lines with shifted highlights and matches', function()
        local buf = vim.api.nvim_create_buf(false, true)
        local previous = vim.api.nvim_get_current_buf()
        vim.api.nvim_win_set_buf(0, buf)
        vim.bo[buf].filetype = 'launcher'
        local lines = {}
        for i = 1, 10005 do lines[i] = 'line ' .. i end
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
        local ns = vim.api.nvim_create_namespace('launcher_highlights')
        vim.hl.range(buf, ns, 'AnsiRed', { 2, 0 }, { 2, 4 }, {})        -- dropped
        vim.hl.range(buf, ns, 'AnsiRed', { 10004, 0 }, { 10004, 4 }, {}) -- last line
        vim.b[buf].launcher_matches = { { lnum = 3 }, { lnum = 10005, file = 'a.c' } }
        lists.save(dir .. '/' .. name)
        local file = string.format('%s/%s.launcher.lua.%d.lua', dir, name, vim.api.nvim_get_current_win())
        vim.api.nvim_win_set_buf(0, previous)
        vim.api.nvim_buf_delete(buf, { force = true })

        local saved = read_json(file)
        assert.equals(10000, #saved.content)
        assert.equals('line 6', saved.content[1])
        assert.equals('line 10005', saved.content[10000])
        assert.are.same({ { 9999, 0, 4, 'AnsiRed' } }, saved.highlights)
        assert.are.same({ { lnum = 10000, file = 'a.c' } }, saved.matches)
    end)

    it('opens a legacy Lua launcher file too big for dofile, keeping the last 10000 lines', function()
        local lines, highlights = {}, {}
        for i = 1, 70000 do
            lines[i] = ('legacy line %d'):format(i)
            highlights[i] = { i - 1, 0, 6, 'AnsiRed' }  -- unique numbers push past the constant limit
        end
        local src = 'return ' .. vim.inspect({ kind = 'launcher', content = lines, highlights = highlights,
                                              obj = 'legacy', status = 'done', filetype = 'launcher',
                                              origin = { tab_nr = 1, winidx = 1 }, prjroot = vim.fn.getcwd() })
        assert.is_nil((loadstring(src)))  -- the case the piecewise loader exists for
        local path = string.format('%s/%s.launcher.lua.1000.lua', dir, name)
        local fd = assert(io.open(path, 'w'))
        fd:write(src)
        fd:close()

        lists.restore(dir .. '/' .. name)

        local bufs = launcher_bufs('legacy')
        assert.equals(1, #bufs)
        local restored = vim.api.nvim_buf_get_lines(bufs[1], 0, -1, false)
        assert.equals(10000, #restored)
        assert.equals('legacy line 60001', restored[1])
        assert.equals('legacy line 70000', restored[10000])
        local restored_hl = require('nvim_config.launcher').GetHighlights(bufs[1])
        assert.equals(10000, #restored_hl)
        assert.are.same({ 0, 0, 6, 'AnsiRed' }, restored_hl[1])
        assert.are.same({ 9999, 0, 6, 'AnsiRed' }, restored_hl[10000])
        vim.cmd('enew')
        vim.api.nvim_buf_delete(bufs[1], { force = true })
    end)

    it('restores a launcher whose origin matches no window without treating it as a loclist', function()
        local fd = assert(io.open(string.format('%s/%s.launcher.lua.1001.lua', dir, name), 'w'))
        fd:write(vim.json.encode({ kind = 'launcher', content = { 'orphan output' }, obj = 'orphan',
                                   status = 'done', filetype = 'launcher', prjroot = vim.fn.getcwd(),
                                   origin = { tab_nr = 99, winidx = 1 } }))
        fd:close()
        local file = vim.fn.tempname()
        fd = assert(io.open(dir .. '/' .. name .. '.qf.lua', 'w'))
        fd:write(vim.json.encode({ kind = 'qf', title = 'with orphan', items = { { filename = file, lnum = 1, text = 'q' } } }))
        fd:close()
        fd = assert(io.open(dir .. '/' .. name .. '.qfwins.lua', 'w'))
        fd:write('[]')  -- no placeholders, so restore keeps the current blank window
        fd:close()
        local wins_before = #vim.api.nvim_list_wins()

        lists.restore(dir .. '/' .. name)

        assert.equals('with orphan', vim.fn.getqflist({ title = 0 }).title)
        assert.equals(1, #launcher_bufs('orphan'))
        for _, winid in ipairs(vim.api.nvim_list_wins()) do
            assert.equals(0, vim.fn.getwininfo(winid)[1].loclist)
        end
        assert.equals(wins_before + 1, #vim.api.nvim_list_wins())  -- only the quickfix window
        vim.api.nvim_buf_delete(launcher_bufs('orphan')[1], { force = true })
    end)

    it('opens a legacy Lua quickfix file, keeping the first 20000 items', function()
        local file = vim.fn.tempname()
        local items = {}
        for i = 1, 20010 do items[i] = { filename = file, lnum = i, text = 'old ' .. i } end
        local fd = assert(io.open(dir .. '/' .. name .. '.qf.lua', 'w'))
        fd:write('return ' .. vim.inspect({ kind = 'qf', title = 'legacy', items = items, selection = 20005 }))
        fd:close()

        lists.restore(dir .. '/' .. name)

        local qf = vim.fn.getqflist({ items = 0, idx = 0, title = 0 })
        assert.equals('legacy', qf.title)
        assert.equals(20000, #qf.items)
        assert.equals('old 20000', qf.items[20000].text)
        assert.equals(20000, qf.idx)
    end)
end)
