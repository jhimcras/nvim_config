-- Actual Python descendants: the Neovim-based fixture reaps its own children
-- and cannot reproduce Windows taskkill's already-exited-leader failure.
-- Run from the repo with isolated XDG_STATE_HOME/XDG_CACHE_HOME:
-- nvim --headless -u tests/minimal_init.lua -i NONE -l tests/manual/coderunner_windows_process.lua
-- CODERUNNER_TEST_PYTHON may override the executable named python.
assert(vim.fn.has('win32') == 1, 'Windows required')
vim.opt.rtp:prepend(vim.fn.getcwd())
local H = require('tests.spec.coderunner.helpers')
local runner = require('nvim_config.coderunner.run')
local python = vim.env.CODERUNNER_TEST_PYTHON or vim.fn.exepath('python')
assert(python ~= '' and vim.fn.executable(python) == 1, 'Python required')
local worker = arg[1] == 'exit-editor' or arg[1] == 'kill-editor'
-- A fresh isolated state has no directory for vim.secure.trust() yet.
vim.fn.mkdir(vim.fn.stdpath('state'), 'p')
local root = worker and arg[2] or H.workspace()
local script = root .. '/tree.py'
local buf, pids = nil, {}
local function source(mode, pidfile)
    local text = '```python {#tree}\nimport runpy,sys\nsys.argv=['
        .. string.format('%q,%q,%q', script, mode, pidfile)
        .. ']\nrunpy.run_path(sys.argv[0],run_name="__main__")\n```\n'
    if not buf then buf = H.buffer(root, text) else
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(text:gsub('\n$', ''), '\n', { plain = true }))
    end
    vim.api.nvim_set_current_buf(buf)
end
local function alive(pid)
    local result = vim.system({ 'tasklist', '/FI', 'PID eq ' .. pid, '/FO', 'CSV', '/NH' }):wait()
    assert(result.code == 0, result.stderr)
    return result.stdout:find('"' .. pid .. '"', 1, true) ~= nil
end
local function load()
    require('nvim_config.coderunner').setup({ auto_render = false })
    assert(vim.secure.trust({ action = 'allow', path = root .. '/.coderunner.lua' }))
    vim.cmd('CodeRunnerLoad')
    assert(require('nvim_config.coderunner.trust').status(root).state == 'loaded')
end
local function start(mode, label)
    local pidfile = root .. '/' .. label .. '.pid'
    source(mode, pidfile)
    vim.cmd('CodeRun #tree')
    local job = assert(runner.last(buf))
    H.wait(function() return vim.uv.fs_stat(pidfile) end, 10000)
    local tree = vim.fn.readfile(pidfile)
    for _, pid in ipairs(tree) do pids[#pids + 1] = pid end
    return job, tree
end
local ok, err = xpcall(function()
    if not worker then
        H.write(script, [=[import os, sys, subprocess, time
mode, path = sys.argv[1:3]
child_code = '''import os,sys,subprocess,time
child=subprocess.Popen([sys.executable,"-c","import time; time.sleep(120)"])
with open(sys.argv[1]+".tmp","w") as f: f.write(sys.argv[2]+"\\n"+str(os.getpid())+"\\n"+str(child.pid))
os.replace(sys.argv[1]+".tmp",sys.argv[1])
time.sleep(120)
'''
subprocess.Popen([sys.executable, '-c', child_code, path, str(os.getpid())])
while not os.path.exists(path): time.sleep(0.01)
print('tree-ready', flush=True)
if mode == 'exit': sys.exit(0)
if mode == 'fail': sys.exit(7)
time.sleep(120)
]=])
        H.write(root .. '/.coderunner.lua', 'return { timeout="2s", max_jobs=1, runners={python={'
            .. 'match={"python"},ext="py",cmd={' .. string.format('%q', python) .. ',"{file}"}}}}')
    end
    source('wait', root .. '/placeholder.pid'); load()
    if worker then
        start('wait', arg[1] == 'kill-editor' and 'forced-editor' or 'editor')
        if arg[1] == 'kill-editor' then
            vim.wait(120000, function() return false end, 100)
            error('parent did not terminate test editor')
        end
        vim.cmd('qa!')
        return
    end
    for _, mode in ipairs({ 'exit', 'fail', 'cancel', 'timeout' }) do
        local job, tree = start((mode == 'exit' or mode == 'fail') and mode or 'wait', mode)
        -- Keep the source selector separate from its expected terminal status.
        if mode == 'cancel' then vim.cmd('CodeCancel') end
        H.wait(function() return job.result end, 10000)
        local expected = ({ exit = 'success', fail = 'failed', cancel = 'cancelled', timeout = 'timeout' })[mode]
        assert(job.status == expected, vim.inspect(job.result))
        for _, pid in ipairs(tree) do assert(not alive(pid), 'surviving test PID ' .. pid) end
        print('PASS CodeRun ' .. mode .. ': leader/child/grandchild dead; status=' .. job.status)
        assert(runner.release(job.id))
    end
    local result = vim.system({ vim.v.progpath, '--headless', '-u', 'NONE', '-i', 'NONE', '-l',
        vim.fn.getcwd() .. '/tests/manual/coderunner_windows_process.lua', 'exit-editor', root },
        { timeout = 15000 }):wait()
    assert(result.code == 0, result.stderr)
    for _, pid in ipairs(vim.fn.readfile(root .. '/editor.pid')) do
        pids[#pids + 1] = pid
        assert(not alive(pid), 'surviving editor-exit test PID ' .. pid)
    end
    print('PASS editor exit: leader/child/grandchild dead')
    local editor = vim.system({
        vim.v.progpath, '--headless', '-u', 'NONE', '-i', 'NONE', '-l',
        vim.fn.getcwd() .. '/tests/manual/coderunner_windows_process.lua',
        'kill-editor', root,
    }, { timeout = 15000 })
    -- Record the exact descendants before killing only the editor (no /T).
    H.wait(function()
        return vim.uv.fs_stat(root .. '/forced-editor.pid')
    end, 10000)
    local tree = vim.fn.readfile(root .. '/forced-editor.pid')
    for _, pid in ipairs(tree) do
        pids[#pids + 1] = pid
    end
    local killed = vim.system({
        'taskkill', '/F', '/PID', tostring(editor.pid),
    }):wait()
    assert(killed.code == 0, killed.stderr)
    assert(editor:wait().code ~= 0, 'forced editor exit must fail')
    for _, pid in ipairs(tree) do
        H.wait(function() return not alive(pid) end, 5000)
        assert(not alive(pid), 'surviving forced-editor test PID ' .. pid)
    end
    print('PASS forced editor exit: leader/child/grandchild dead')
end, debug.traceback)
-- Only exact PIDs published by this test; never kill all python/nvim processes.
for _, pid in ipairs(pids) do if alive(pid) then vim.system({ 'taskkill', '/F', '/T', '/PID', pid }):wait() end end
if not worker then
    if buf and vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_delete(buf, { force = true }) end
    vim.fn.delete(root, 'rf')
end
assert(ok, err)
