-- Isolate XDG_CACHE_HOME/XDG_STATE_HOME, then run:
-- nvim --headless -u tests/minimal_init.lua -i NONE -l tests/manual/coderunner_smoke.lua
local H = require('tests.spec.coderunner.helpers')
local api = vim.api
local runner = require('nvim_config.coderunner.run')
local render = require('nvim_config.coderunner.render')
local blocks = require('nvim_config.coderunner.blocks')
local cache = require('nvim_config.coderunner.cache')
local namespace = require('nvim_config.coderunner.diagnostics').namespace
assert(vim.fn.executable('python3') == 1 and vim.fn.executable('plantuml') == 1, 'python3 and plantuml required')
local root, buf = H.workspace()
local function source(text)
    if not buf then buf = H.buffer(root, text) else
        api.nvim_set_current_buf(buf)
        api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(text:gsub('\n$', ''), '\n', { plain = true }))
        H.write(root .. '/note.md', text)
    end
    api.nvim_set_current_buf(buf); vim.bo[buf].filetype = 'markdown'
end
local function setup(auto)
    local renderer = { 'plantuml', '-t{format}', '-pipe' }
    if vim.env.CODERUNNER_SMOKE_JAVA then
        renderer = { vim.env.CODERUNNER_SMOKE_JAVA, '-Djava.awt.headless=true', '-jar',
            assert(vim.env.CODERUNNER_SMOKE_JAR), '-t{format}', '-pipe' }
    end
    require('nvim_config.coderunner').setup({ auto_render = auto, auto_render_debounce = '20ms', max_jobs = 1,
        create_attachments_dir = 'always', runners = {
            python = { match = { 'python' }, ext = 'py', cmd = { 'python3', '{file}' } },
        }, renderers = {
            plantuml = { match = { 'plantuml' }, input = 'stdin', output = 'stdout', formats = { 'svg' },
                cmd = renderer },
        } })
end
local function run(command)
    api.nvim_set_current_buf(buf); vim.cmd(command)
    local job = assert(runner.last(buf)); H.wait(function() return job.result end, 10000)
    return job
end
local function close_result()
    local mappings = api.nvim_buf_get_keymap(0, 'n')
    for _, mapping in ipairs(mappings) do if mapping.lhs == 'q' then mapping.callback(); return end end
    error('missing result q mapping')
end
local function block() return assert(blocks.get(buf, root))[1] end
local function rendered()
    H.wait(function() return render.lookup(block()).status ~= 'pending' end, 30000)
    assert(render.lookup(block()).status == 'ready', vim.inspect(render.lookup(block())))
    return render.lookup(block()).path
end
local function diagnostic(code)
    require('nvim_config.coderunner.diagnostics').refresh(buf)
    for _, d in ipairs(vim.diagnostic.get(buf, { namespace = namespace })) do if d.code == code then return d end end
end
local ok, err = xpcall(function()
    source('```python {#run}\nprint("hello")\n```\n'); setup(false)
    local job = run('CodeRun #run'); assert(job.result.stdout == 'hello\n')
    assert(api.nvim_win_get_config(0).relative ~= ''); close_result()
    assert(runner.get(job.id)); vim.cmd('CodeOutput'); assert(api.nvim_win_get_config(0).relative ~= '')
    close_result(); vim.cmd('CodeRelease'); assert(not runner.get(job.id))
    job = run('CodeRun! #run'); close_result(); assert(block().output.code == 'hello\n')
    vim.cmd('undo'); assert(not block().output); runner.release(job.id)
    source('```python {#run}\nprint("```")\nraise RuntimeError("smoke")\n```\n')
    job = run('CodeRun! #run'); close_result()
    assert(job.status == 'failed' and block().output.info == 'output {.error}')
    local opening = api.nvim_buf_get_lines(buf, block().output.start_row, block().output.start_row + 1, false)[1]
    assert(opening:sub(1, 4) == '````'); runner.release(job.id)
    print('PASS Python run/view/q/reopen/release/output/undo/failure/long fence')
    source('```plantuml {#diagram}\n@startuml\nAlice -> Bob: hello\n@enduml\n```\n'); setup(true)
    local calls, command_run = 0, require('nvim_config.coderunner.command').run
    require('nvim_config.coderunner.command').run = function(...) calls = calls + 1; return command_run(...) end
    vim.cmd('CodeRender #diagram'); local path = rendered(); assert(cache.read(path):find('<svg', 1, true))
    vim.cmd('CodeRender #diagram'); rendered(); assert(calls == 1, 'second render must hit cache')
    vim.cmd('CodeExport #diagram'); H.wait(function() return #block().images == 1 end, 30000)
    local target = root .. '/' .. block().images[1].target
    assert(cache.read(target) == cache.read(path))
    api.nvim_buf_set_lines(buf, 2, 3, false, { 'Alice -> Carol: changed' }); vim.cmd('silent write!')
    H.wait(function() local found = render.lookup(block()); return found.status == 'ready' and not found.stale end, 30000)
    assert(calls == 2); assert(diagnostic('stale-export'))
    vim.cmd('CodeExport #diagram'); H.wait(function() return not diagnostic('stale-export') end, 30000)
    assert(cache.read(target) == cache.read(render.lookup(block()).path))
    H.write(target, 'outdated'); vim.cmd('CodeExportAll')
    H.wait(function() return not diagnostic('stale-export') end, 30000)
    assert(cache.read(target) == cache.read(render.lookup(block()).path))
    api.nvim_buf_set_lines(buf, 2, 3, false, { 'this is totally invalid syntax !!!' }); vim.cmd('silent write!')
    H.wait(function() return render.lookup(block()).status == 'failed' end, 30000)
    assert(diagnostic('render-failed'))
    api.nvim_buf_set_lines(buf, 2, 3, false, { 'Alice -> Carol: changed' }); vim.cmd('silent write!')
    H.wait(function() return render.lookup(block()).status == 'ready' and not diagnostic('render-failed') end, 30000)
    require('nvim_config.coderunner.command').run = command_run
    print('PASS PlantUML SVG/cache/auto save/export/stale/export all/render failure/recovery')
    vim.cmd('silent write!')
    local orphan = cache.image(cache.paths(root), 'plantuml', string.rep('a', 64), 'svg')
    H.write(orphan, '<svg/>'); vim.cmd('CodeGc dry-run'); assert(cache.read(orphan))
    vim.cmd('CodeGc'); assert(not cache.read(orphan)); assert(cache.read(render.lookup(block()).path))
    print('PASS GC dry-run/removal/current protection; max_jobs=1')
end, debug.traceback)
if buf and api.nvim_buf_is_valid(buf) then api.nvim_buf_delete(buf, { force = true }) end
vim.fn.delete(cache.paths(root).dir, 'rf'); vim.fn.delete(root, 'rf')
if not ok then error(err) end
