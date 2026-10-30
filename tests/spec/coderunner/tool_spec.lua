local H = require('tests.spec.coderunner.helpers')
local function run(...)
    return vim.system(H.tool(...), { stdin = '한글\n' }):wait(5000)
end

describe('coderunner fake tool', function()
    local root
    before_each(function() root = H.workspace() end)
    after_each(function() vim.fn.delete(root, 'rf') end)

    it('echoes input files and stdin and writes output bytes', function()
        local input = H.write(root .. '/input', 'hello\n')
        assert.equals('hello\n', run('echo', input).stdout)
        assert.equals('한글\n', run('stdin').stdout)
        assert.equals(0, run('write', root .. '/image', '<svg/>').code)
        assert.same({ '<svg/>' }, vim.fn.readfile(root .. '/image'))
    end)

    it('preserves binary bytes through files and stdin', function()
        local bytes = '\137PNG\r\n\26\n\0\255' .. string.rep('x', 8192)
        local input = H.write(root .. '/binary-input', bytes)
        for _, argv in ipairs({ H.tool('echo', input), H.tool('stdin') }) do
            local result = vim.system(argv, { stdin = bytes }):wait(5000)
            assert.equals(0, result.code)
            assert.equals(bytes, result.stdout)
            assert.equals('', result.stderr)
        end
    end)

    it('reports literal argv, inherited env, cwd and stdin', function()
        local result = vim.system(H.tool('dump', '; rm -rf', '$(x)', ''), {
            cwd = root, env = { CODERUNNER_TEST_VAR = 'ok' }, stdin = '한글\n',
        }):wait(5000)
        assert.equals(0, result.code)
        local report = vim.json.decode(result.stdout)
        assert.same({ '; rm -rf', '$(x)', '' }, report.args)
        assert.equals(root, report.cwd)
        assert.equals('ok', report.var)
        assert.equals('한글\n', report.stdin)
        assert.is_string(report.path)
    end)

    it('supports failure, sleep and simultaneous large output', function()
        assert.equals(7, run('exit', '7').code)
        assert.equals(0, run('sleep-ms', '10').code)
        local result = run('flood', '131073')
        assert.equals(0, result.code)
        assert.equals(string.rep('o', 131073), result.stdout)
        assert.equals(string.rep('e', 131073), result.stderr)
    end)

    it('spawns a descendant in wait and leader-exit modes', function()
        for _, mode in ipairs({ 'wait', 'exit' }) do
            local pidfile = root .. '/' .. mode .. '.pid'
            local job = vim.system(H.tool('spawn', pidfile, mode))
            local ok, err = pcall(function()
                H.wait(function() return vim.uv.fs_stat(pidfile) ~= nil end)
                local pid = tonumber(vim.fn.readfile(pidfile)[1])
                assert.is_number(pid)
                assert.is_truthy(vim.uv.kill(pid, 0))
                -- C0 verifies the fixture; C3 will verify executor tree cleanup.
                assert(vim.uv.kill(pid, 'sigkill'))
            end)
            job:kill('sigkill')
            job:wait(5000)
            assert(ok, err)
        end
    end)
end)
