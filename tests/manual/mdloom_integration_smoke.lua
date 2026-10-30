-- Run with this checkout's real init.lua, isolated XDG state/cache/runtime, and
-- MDLOOM_INTEGRATION_ROOT pointing to a disposable directory. Requires mdloom,
-- installed plugins, Java and PlantUML (RENDERMARK_PLANTUML_JAR). Headless Java
-- may need JAVA_TOOL_OPTIONS=-Djava.awt.headless=true when DISPLAY is unavailable.
local api = vim.api
local base = vim.fs.normalize(assert(vim.env.MDLOOM_INTEGRATION_ROOT, 'MDLOOM_INTEGRATION_ROOT is required'))
local root = vim.fs.joinpath(base, 'ws')
local bin = assert(vim.fn.exepath('mdloom') ~= '' and vim.fn.exepath('mdloom'), 'mdloom on PATH required')
local roots = { root }
local function write(path, text)
    vim.fn.mkdir(vim.fs.dirname(path), 'p')
    local f = assert(io.open(path, 'wb')); f:write(text); f:close()
end
local function read(path)
    local f = assert(io.open(path, 'rb')); local text = f:read('*a'); f:close(); return text
end
local function path(name) return vim.fs.joinpath(root, name) end
local function wait(what, condition)
    assert(vim.wait(15000, condition, 40), 'timed out: ' .. what)
end
local function text(buf) return table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), '\n') end
local function edit(name)
    vim.cmd.edit(vim.fn.fnameescape(path(name)))
    local buf, client = api.nvim_get_current_buf()
    wait('mdloom attach ' .. name, function()
        client = vim.lsp.get_clients({ bufnr = buf, name = 'mdloom' })[1]
        return client and client.initialized and not client:is_stopped()
    end)
    return buf, client
end
local function request(buf, method, params)
    local client = assert(vim.lsp.get_clients({ bufnr = buf, name = 'mdloom' })[1])
    local response = assert(client:request_sync(method, params, 10000, buf), method .. ' timed out')
    assert(not response.err, method .. ': ' .. vim.inspect(response.err))
    if response.result ~= vim.NIL then return response.result end
end
local function at(buf, row, col)
    return { textDocument = { uri = vim.uri_from_bufnr(buf) }, position = { line = row, character = col } }
end
local function actions(buf, row)
    return request(buf, 'textDocument/codeAction', { textDocument = { uri = vim.uri_from_bufnr(buf) },
        range = { start = { line = row, character = 0 }, ['end'] = { line = row, character = 0 } },
        context = { diagnostics = {} } }) or {}
end
local function diagnostic(buf, code)
    for _, item in ipairs(vim.diagnostic.get(buf)) do if item.code == code then return item end end
end
local function pass(name) print('PASS ' .. name) end
local function save_all() vim.cmd('silent wall') end
local function daemon(dir, command)
    return vim.system({ bin, 'daemon', command }, { cwd = dir, text = true }):wait(15000)
end
local function stop()
    for _, client in ipairs(vim.lsp.get_clients({ name = 'mdloom' })) do client:stop() end
    vim.wait(5000, function() return #vim.lsp.get_clients({ name = 'mdloom' }) == 0 end, 20)
    for _, dir in ipairs(roots) do daemon(dir, 'stop') end
end

local ok, err = xpcall(function()
    vim.fn.mkdir(path('.mdloom'), 'p')
    vim.fn.mkdir(path('.git'), 'p') -- coderunner and mdloom share this test root.
    write(path('b.md'), '# Target\n\n## Heading\n\nbody\n')
    write(path('a.md'), '# Source\n\n[b](b.md)\n[[b#Heading]]\n[missing](new-markdown.md)\n[[new-wiki]]\n\n```python {#run}\nprint("hello")\n```\n')
    write(path('complete.md'), '[[b]]\n[b](b.md#)\n')
    vim.cmd.cd(vim.fn.fnameescape(root))
    local a, client = edit('a.md')
    assert(package.loaded['pckr'] and package.loaded['oil'], 'real plugins must be loaded')
    assert(client.server_capabilities.codeLensProvider == nil, 'mdloom must not advertise codeLens')
    assert(api.nvim_buf_get_keymap(a, 'n') and vim.fn.maparg('gW', 'n') ~= '', 'gW mapping')
    wait('initial definition', function()
        local result = request(a, 'textDocument/definition', at(a, 2, 5)) or {}
        return #result == 1 and vim.uri_to_fname(result[1].uri) == path('b.md')
    end)
    for _, action in ipairs(actions(a, 8)) do
        assert(not action.title:match('^Run') and not action.title:match('^Render')
            and not action.title:match('^Export'), vim.inspect(action))
    end
    local health_ok, health_err = pcall(require('vim.lsp.health').check)
    assert(health_ok, health_err)
    pass('real init/pckr/oil/mdloom attach; health; no codeLens or execution Code Actions; gW binding')

    local definition = request(a, 'textDocument/definition', at(a, 3, 6))
    assert(definition[1].range.start.line == 2, vim.inspect(definition))
    local hover = request(a, 'textDocument/hover', at(a, 3, 6))
    assert(hover and vim.inspect(hover):find('Heading', 1, true), vim.inspect(hover))
    local b = edit('b.md')
    local refs = at(b, 2, 4); refs.context = { includeDeclaration = false }
    assert(#request(b, 'textDocument/references', refs) >= 1, 'heading references')
    assert(#request(b, 'workspace/symbol', { query = 'Heading' }) >= 1, 'workspace symbols')
    local completion = edit('complete.md')
    local links = request(completion, 'textDocument/completion', at(completion, 0, 3))
    local headings = request(completion, 'textDocument/completion', at(completion, 1, 9))
    assert(#(links.items or links) > 0, vim.inspect(links))
    assert(vim.inspect(headings):find('Heading', 1, true), vim.inspect(headings))
    pass('link/heading completion; definition; references; hover; workspace symbols')

    api.nvim_set_current_buf(a)
    wait('missing link diagnostics', function() return diagnostic(a, 'broken-link') and diagnostic(a, 'unresolved-wikilink') end)
    for _, item in ipairs({ { row = 4, name = 'new-markdown.md' }, { row = 5, name = 'new-wiki.md' } }) do
        api.nvim_win_set_cursor(0, { item.row + 1, 0 })
        vim.lsp.buf.code_action({ apply = true, filter = function(action) return action.title == 'Create ' .. item.name end })
        wait('create action ' .. item.name, function() return vim.uv.fs_stat(path(item.name)) ~= nil end)
    end
    pass('diagnostics; standard and wiki missing-document Code Actions create files')

    api.nvim_set_current_buf(b)
    local rename = at(b, 2, 4); rename.newName = 'Renamed'
    local rename_edit = assert(request(b, 'textDocument/rename', rename))
    vim.lsp.util.apply_workspace_edit(rename_edit, client.offset_encoding)
    assert(text(b):find('## Renamed', 1, true) and text(a):find('[[b#Renamed]]', 1, true), text(a))
    save_all()
    pass('heading rename updates the other document; wall saves edits')

    api.nvim_set_current_buf(b)
    local confirm = vim.fn.confirm
    vim.fn.confirm = function() return 2 end -- explicit No to the command's wall prompt.
    local moved, move_err = pcall(vim.cmd, 'MdloomMove moved/b.md')
    vim.fn.confirm = confirm
    assert(moved, move_err)
    assert(vim.uv.fs_stat(path('moved/b.md')) and not vim.uv.fs_stat(path('b.md')))
    assert(text(a):find('(moved/b.md)', 1, true), text(a))
    save_all()
    pass('MdloomMove command moves the file and updates links')

    write(path('oil.md'), '# Oil target\n')
    write(path('oil-ref.md'), '[oil](oil.md)\n')
    local oil_ref = edit('oil-ref.md')
    wait('oil source indexed', function() return #(request(oil_ref, 'textDocument/definition', at(oil_ref, 0, 8)) or {}) == 1 end)
    local oil = require('oil')
    oil.open(root)
    local oil_buf = api.nvim_get_current_buf()
    wait('oil directory loaded', function() return text(oil_buf):find(' oil.md', 1, true) ~= nil end)
    local found = false
    for row, line in ipairs(api.nvim_buf_get_lines(oil_buf, 0, -1, false)) do
        if line:match(' oil%.md$') then
            api.nvim_buf_set_lines(oil_buf, row - 1, row, false, { (line:gsub('oil%.md$', 'oil-renamed.md')) })
            found = true; break
        end
    end
    assert(found, text(oil_buf))
    local done, oil_err = false
    oil.save({ confirm = false }, function(e) done, oil_err = true, e end)
    wait('oil save', function() return done end)
    assert(not oil_err, tostring(oil_err))
    assert(vim.uv.fs_stat(path('oil-renamed.md')) and text(oil_ref):find('(oil-renamed.md)', 1, true), text(oil_ref))
    save_all()
    pass('real Oil rename sends willRenameFiles and updates links')

    write(path('table.md'), '# Table\n\n|a|b|\n|-|-|\n|x|long value|\n')
    local tbl = edit('table.md')
    api.nvim_win_set_cursor(0, { 5, 2 })
    vim.cmd('MdloomTable align')
    wait('table alignment', function() return text(tbl):find('| ---', 1, true) ~= nil end)
    require('nvim_config.rendermark').refresh()
    local table_rendered = false
    for _, ns in pairs(api.nvim_get_namespaces()) do
        for _, mark in ipairs(api.nvim_buf_get_extmarks(tbl, ns, 0, -1, { details = true })) do
            if vim.inspect(mark[4]):find('┌', 1, true) then table_rendered = true end
        end
    end
    assert(table_rendered, 'rendermark table virtual border')
    pass('MdloomTable align and rendermark table decorations')

    write(path('format.md'), 'Title\n=====\n\n* item  \n\n```python\nx  =  1\nprint(x)  \n```\n')
    local fmt = edit('format.md')
    local before = text(fmt)
    vim.lsp.buf.format({ bufnr = fmt, name = 'mdloom', timeout_ms = 10000 })
    assert(text(fmt) ~= before and text(fmt):find('x  =  1\nprint(x)  ', 1, true), text(fmt))
    vim.cmd.undo()
    assert(text(fmt) == before, text(fmt))
    pass('built-in format preserves code source; undo restores the whole edit')

    write(path('diagram.md'), '# Diagram\n\n```plantuml {#diagram}\n@startuml\nAlice -> Bob: integration\n@enduml\n```\n')
    vim.fn.mkdir(path('assets'), 'p')
    local diagram = edit('diagram.md')
    api.nvim_win_set_cursor(0, { 1, 0 })
    vim.cmd('CodeExport #diagram')
    wait('real PlantUML PNG export', function() return text(diagram):find('!%[') ~= nil end)
    save_all()
    local blocks = require('nvim_config.coderunner.blocks').get(diagram, root)
    local target = assert(blocks[1].images[1]).target
    local image_path = vim.fs.normalize(vim.fs.joinpath(root, target))
    assert(read(image_path):sub(1, 8) == '\137PNG\r\n\26\n', 'actual PNG export')
    local image_bytes = read(image_path)
    assert(vim.uv.fs_unlink(image_path))
    wait('broken exported image', function() return diagnostic(diagram, 'broken-image') ~= nil end)
    write(image_path, image_bytes)
    wait('exported image restored', function() return diagnostic(diagram, 'broken-image') == nil end)
    local new_image = path('assets/moved.png')
    local image_moved, image_err = require('mdloom').move(image_path, new_image, { save = false })
    assert(image_moved, image_err)
    assert(text(diagram):find('moved.png', 1, true), text(diagram))
    save_all()
    pass('actual coderunner PNG export; broken-image on deletion; image move updates link')

    api.nvim_set_current_buf(a)
    wait('LSP folding', function() return vim.fn.foldlevel(1) >= 1 end)
    assert(vim.wo.foldmethod == 'expr' and vim.fn.foldclosed(1) == -1)
    vim.cmd('normal! zc'); assert(vim.fn.foldclosed(1) == 1)
    vim.cmd('normal! zo'); assert(vim.fn.foldclosed(1) == -1)
    local old = client.id
    assert(daemon(root, 'stop').code == 0, 'stop test daemon')
    wait('automatic daemon reconnect', function()
        client = vim.lsp.get_clients({ bufnr = a, name = 'mdloom' })[1]
        return client and client.id ~= old and client.initialized and not client:is_stopped()
    end)
    wait('navigation after daemon restart', function()
        return #(request(a, 'textDocument/definition', at(a, 2, 8)) or {}) == 1
    end)
    pass('fold zc/zo; test daemon stop; automatic reconnect and navigation')

    local legacy = vim.fs.joinpath(base, 'legacy')
    roots[#roots + 1] = legacy
    write(vim.fs.joinpath(legacy, '.mdloom', 'config.toml'), '[runners.old]\ncmd = ["unused"]\n[renderers.old]\ncmd = ["unused"]\n')
    write(vim.fs.joinpath(legacy, 'note.md'), '# Legacy\n')
    local checked = vim.system({ bin, 'check', '--no-daemon', 'note.md' }, { cwd = legacy, text = true }):wait(15000)
    assert(checked.code == 0 and checked.stderr:find('`runners` is no longer supported', 1, true)
        and checked.stderr:find('`renderers` is no longer supported', 1, true), vim.inspect(checked))
    vim.cmd.edit(vim.fn.fnameescape(vim.fs.joinpath(legacy, 'note.md')))
    local legacy_buf = api.nvim_get_current_buf()
    wait('legacy-config LSP attach', function()
        local c = vim.lsp.get_clients({ bufnr = legacy_buf, name = 'mdloom' })[1]
        return c and c.initialized
    end)
    assert(#request(legacy_buf, 'textDocument/documentSymbol', { textDocument = { uri = vim.uri_from_bufnr(legacy_buf) } }) == 1)
    pass('removed settings warn; CLI and real LSP remain functional')
end, debug.traceback)
stop()
if not ok then error(err) end
