local M = {}
local api, uv = vim.api, vim.uv
local blocks = require('nvim_config.coderunner.blocks')
local cache = require('nvim_config.coderunner.cache')
local render = require('nvim_config.coderunner.render')
local runner = require('nvim_config.coderunner.run')
local fs = { read = cache.read, stat = uv.fs_lstat, realpath = uv.fs_realpath,
    list = function(path) return vim.fn.readdir(path) end }
local serial = 0
local function inside(path, root)
    path, root = vim.fs.normalize(path), vim.fs.normalize(root)
    return path == root or path:sub(1, #root + 1) == root .. '/'
end
local function document(block)
    return vim.fs.normalize(vim.fs.joinpath(block.root, block.path))
end
local function absolute(path, base)
    if path:sub(1, 1) == '/' or path:match('^%a:') then return vim.fs.normalize(path) end
    return vim.fs.normalize(vim.fs.joinpath(base, path))
end
local function safe(path, root, io)
    local realroot = io.realpath(root)
    if not realroot then return nil, 'workspace root is unavailable' end
    local cursor = path
    while not io.stat(cursor) do
        local parent = vim.fs.dirname(cursor)
        if not parent or parent == cursor then return nil, 'cannot resolve attachment path' end
        cursor = parent
    end
    local real = io.realpath(cursor)
    if not real or not inside(real, realroot) then return nil, 'attachment path escapes workspace root' end
    local stat = io.stat(path)
    if stat and stat.type == 'link' then return nil, 'attachment symlink is not writable' end
    return true
end
function M.folder(block, setting, io)
    io = io or fs
    if type(setting) ~= 'string' or setting == '' or setting:find('\\', 1, true)
        or setting:sub(1, 1) == '/' or setting:match('^%a:') then return nil, 'invalid attachment folder' end
    for part in setting:gmatch('[^/]+') do if part == '..' then return nil, 'invalid attachment folder' end end
    local base = setting:sub(1, 2) == './' and vim.fs.dirname(document(block)) or block.root
    local folder = absolute(setting, base)
    if not inside(folder, vim.fs.normalize(block.root)) then return nil, 'attachment path escapes workspace root' end
    local ok, err = safe(folder, block.root, io)
    if not ok then return nil, err end
    local stat = io.stat(folder)
    if stat and stat.type ~= 'directory' then return nil, 'attachment folder is not a directory' end
    return folder
end
local function decode(target)
    return (target:gsub('%%(%x%x)', function(h) return string.char(tonumber(h, 16)) end))
end
function M.adjacent(block, folder, io)
    io = io or fs
    for _, image in ipairs(block.images or {}) do
        local target = decode(image.target)
        if not target:match('^%a[%w+.-]*:') and target:sub(1, 1) ~= '/' and not target:find('\\', 1, true) then
            local path
            if image.kind == 'wiki' and not target:find('/', 1, true) then
                local matches = {}
                for _, name in ipairs(io.stat(folder) and io.list(folder) or {}) do
                    if name == target or vim.fn.fnamemodify(name, ':r') == target then
                        if name:match('%.png$') or name:match('%.svg$') then matches[#matches + 1] = name end
                    end
                end
                if #matches > 1 then return nil, 'ambiguous basename wiki image: ' .. target end
                if #matches == 1 then path = folder .. '/' .. matches[1]
                elseif target:match('%.png$') or target:match('%.svg$') then path = folder .. '/' .. target end
            else path = absolute(target, vim.fs.dirname(document(block))) end
            if path and inside(path, folder) then
                local ok, err = safe(path, block.root, io)
                if not ok then return nil, err end
                return { path = path, image = image, format = path:match('%.([^.]+)$') }
            end
        end
    end
end
local function relative(base, path)
    local left, right = vim.split(base, '/', { plain = true }), vim.split(path, '/', { plain = true })
    local n = 1
    while left[n] and left[n] == right[n] do n = n + 1 end
    local parts = {}
    for _ = n, #left do parts[#parts + 1] = '..' end
    for i = n, #right do parts[#parts + 1] = right[i] end
    return table.concat(parts, '/')
end
local function filename(s) return (s:gsub('[/\\%c:*?"<>|]', '-')) end
local function text_lines(text)
    local lines = vim.split(text:gsub('\r\n', '\n'), '\n', { plain = true })
    if lines[#lines] == '' then table.remove(lines) end
    return lines
end
local function signature(list)
    local out = {}
    for _, b in ipairs(list) do out[#out + 1] = { b.lang, b.id, b.code } end
    return out
end
-- All filesystem observations are supplied through opts.fs; the returned plan
-- only describes edits and never writes files or modifies a buffer.
function M.plan(block, opts)
    opts = opts or {}
    local io = assert(opts.fs, 'export.plan requires filesystem observations')
    if block.duplicate then return nil, 'duplicate-code-id: ' .. block.id end
    if block.lang == 'output' or not block.closed then return nil, 'cannot export this fence' end
    local folder, err = M.folder(block, opts.attachments or './assets', io)
    if not folder then return nil, err end
    if not io.stat(folder) then return nil, 'attachment folder does not exist' end
    local existing; existing, err = M.adjacent(block, folder, io)
    if err then return nil, err end
    if opts.existing_only and not existing then return nil, 'no adjacent export' end
    local format = opts.format or (existing and existing.format) or 'png'
    if format ~= 'png' and format ~= 'svg' then return nil, 'unsupported export format' end
    if existing and existing.format ~= format then return nil, 'adjacent image format does not match requested format' end
    local bytes = opts.bytes
    if type(bytes) ~= 'string' or bytes == '' then return nil, 'no current rendered image' end
    local target, action
    if existing then target, action = existing.path, 'update'
    else
        local stem = filename(vim.fn.fnamemodify(document(block), ':t:r')) .. '-'
            .. filename(block.id or (block.lang .. '-' .. block.ordinal))
        local candidates, used = {}, {}
        for _, name in ipairs(io.list(folder)) do
            local suffix = name:sub(#stem + 1)
            if name:sub(1, #stem) == stem and (suffix == '.' .. format or suffix:match('^%-%d+%.' .. format .. '$')) then
                candidates[#candidates + 1] = name; used[name] = true
            end
        end
        table.sort(candidates)
        for _, name in ipairs(candidates) do
            local path = folder .. '/' .. name
            if io.stat(path).type == 'file' and io.read(path) == bytes then target, action = path, 'reuse'; break end
        end
        if not target then
            local n, name = 1, stem .. '.' .. format
            while used[name] or io.stat(folder .. '/' .. name) do
                n = n + 1; name = stem .. '-' .. n .. '.' .. format
            end
            target, action = folder .. '/' .. name, 'new'
        end
    end
    local ok; ok, err = safe(target, block.root, io)
    if not ok then return nil, err end
    if io.stat(target) and io.stat(target).type ~= 'file' then return nil, 'export target is not a regular file' end
    local plan = { action = action, target = target, folder = folder, bytes = bytes,
        before = io.read(target), edits = {}, block = block }
    if not existing then
        local rel = relative(vim.fs.dirname(document(block)), target):gsub('\\', '/')
        local encoded = rel:gsub('[^%w/._~-]', function(c) return string.format('%%%02X', c:byte()) end)
        local link = opts.link_style == 'wiki' and ('![[' .. encoded .. ']]') or ('![](' .. encoded .. ')')
        local prefix = block.close_prefix or ''
        plan.edits = { { first = block.end_row + 1, last = block.end_row + 1, lines = { prefix, prefix .. link } } }
        local lines = opts.lines
        if not lines then return nil, 'document lines are required for new export' end
        local after = vim.deepcopy(lines)
        for i = #plan.edits[1].lines, 1, -1 do table.insert(after, block.end_row + 2, plan.edits[1].lines[i]) end
        local before_blocks; before_blocks, err = blocks.parse(table.concat(lines, '\n') .. '\n', { root = block.root, path = document(block) })
        if not before_blocks then return nil, err end
        local after_blocks; after_blocks, err = blocks.parse(table.concat(after, '\n') .. '\n', { root = block.root, path = document(block) })
        if not after_blocks then return nil, err end
        if not vim.deep_equal(signature(before_blocks), signature(after_blocks)) then return nil, 'link insertion would change code blocks' end
        local attached = false
        for _, b in ipairs(after_blocks) do
            if b.key == block.key then
                for _, image in ipairs(b.images) do if decode(image.target) == rel then attached = true end end
            end
        end
        if not attached then return nil, 'new image would not be adjacent to code block' end
    end
    return plan
end
local function ensure_folder(block, cfg)
    local folder, err = M.folder(block, cfg.attachments)
    if not folder then return nil, err end
    if uv.fs_lstat(folder) then return folder end
    if cfg.create_attachments_dir == 'never' then return nil, 'attachment folder does not exist' end
    if cfg.create_attachments_dir == 'ask' and vim.fn.confirm('Create attachment folder ' .. folder .. '?', '&Yes\n&No', 2) ~= 1 then
        return nil, 'attachment folder creation declined'
    end
    local ok, message = pcall(vim.fn.mkdir, folder, 'p')
    if not ok then return nil, tostring(message) end
    return M.folder(block, cfg.attachments)
end
function M.apply(buf, plan, tick)
    if not api.nvim_buf_is_loaded(buf) then return nil, 'document is closed' end
    if not vim.bo[buf].modifiable then return nil, 'document is not modifiable' end
    if tick and api.nvim_buf_get_changedtick(buf) ~= tick then return nil, 'document changed during export' end
    local ok, err = safe(plan.target, plan.block.root, fs)
    if not ok then return nil, err end
    if cache.read(plan.target) ~= plan.before then return nil, 'export target changed during export' end
    if plan.action ~= 'reuse' then
        serial = serial + 1
        local temporary = plan.folder .. '/.coderunner-export-' .. uv.os_getpid() .. '-' .. serial
        local copied
        if plan.source then copied, err = uv.fs_copyfile(plan.source, temporary, { excl = true })
        else
            local fd; fd, err = uv.fs_open(temporary, 'wx', 438)
            if fd then copied, err = uv.fs_write(fd, plan.bytes, 0); uv.fs_close(fd) end
        end
        if not copied then return nil, err end
        if cache.read(temporary) ~= plan.bytes then uv.fs_unlink(temporary); return nil, 'rendered image changed during copy' end
        if plan.action == 'new' or not uv.fs_lstat(plan.target) then ok, err = uv.fs_link(temporary, plan.target)
        else ok, err = uv.fs_rename(temporary, plan.target) end
        uv.fs_unlink(temporary)
        if not ok then return nil, err end
    end
    if #plan.edits > 0 then
        local edit = plan.edits[1]
        ok, err = pcall(api.nvim_buf_set_lines, buf, edit.first, edit.last, false, edit.lines)
        if not ok then return nil, 'image saved; link insertion failed: ' .. tostring(err) end
    end
    return { action = plan.action, path = plan.target }
end
local function prepare(buf, block, opts, callback)
    local cfg, status = require('nvim_config.coderunner').resolve(block.root, opts.explicit ~= false)
    if not require('nvim_config.coderunner.trust').can_select(status) then callback(nil, 'workspace configuration must be loaded with :CodeRunnerLoad'); return end
    local folder, err = ensure_folder(block, cfg)
    if not folder then callback(nil, err); return end
    local adjacent; adjacent, err = M.adjacent(block, folder)
    if err then callback(nil, err); return end
    if opts.existing_only and not adjacent then callback(nil, 'no adjacent export'); return end
    local format = opts.format or (adjacent and adjacent.format)
    if adjacent and opts.format and opts.format ~= adjacent.format then callback(nil, 'adjacent image format does not match requested format'); return end
    local desc; desc, err = render.describe(block, { format = format, explicit = false, batch = opts.batch })
    if not desc then callback(nil, err); return end
    local image_stat, dir_stat = uv.fs_lstat(desc.path), uv.fs_lstat(desc.paths.images)
    if image_stat and image_stat.type ~= 'file' or not dir_stat or dir_stat.type ~= 'directory' then
        callback(nil, 'render cache image is not a regular file inside cache'); return
    end
    local before = adjacent and cache.read(adjacent.path)
    local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
    local tick = api.nvim_buf_get_changedtick(buf)
    local job
    job, err = render.start(block, { format = format, explicit = false, batch = opts.batch, buf = buf }, function(completed)
        if completed.result.status ~= 'ready' then callback(nil, completed.result.error or completed.result.status); return end
        if not api.nvim_buf_is_loaded(buf) or api.nvim_buf_get_changedtick(buf) ~= tick then callback(nil, 'document changed during export'); return end
        if adjacent and cache.read(adjacent.path) ~= before then callback(nil, 'export target changed during export'); return end
        local source = completed.result.path
        local paths = cache.paths(block.root)
        local stat, real = uv.fs_lstat(source), uv.fs_realpath(source)
        if not stat or stat.type ~= 'file' or not real or not inside(real, uv.fs_realpath(paths.images) or paths.images) then
            callback(nil, 'render cache image is not a regular file inside cache'); return
        end
        cache.use(source, 1)
        local plan, message = M.plan(block, { fs = fs, attachments = cfg.attachments,
            format = completed.format, link_style = cfg.link_style, bytes = cache.read(source),
            lines = lines, existing_only = opts.existing_only })
        if not plan then cache.use(source, -1); callback(nil, message); return end
        plan.source, plan.tick = source, tick
        callback(plan)
    end)
    if not job then callback(nil, err) end
    return job
end
function M.start(buf, selector, opts, callback)
    buf = buf == 0 and api.nvim_get_current_buf() or buf
    opts, callback = opts or {}, callback or function() end
    if api.nvim_buf_get_name(buf) == '' then callback(nil, 'save the document before exporting'); return nil, 'save the document before exporting' end
    local block, err = runner.select(buf, selector, runner.root(buf))
    if not block then callback(nil, err); return nil, err end
    return prepare(buf, block, opts, function(plan, message)
        if not plan then callback(nil, message); return end
        local result; result, message = M.apply(buf, plan, plan.tick)
        cache.use(plan.source, -1)
        require('nvim_config.coderunner.diagnostics').refresh(buf)
        callback(result, message)
    end)
end
function M.all(buf, callback)
    buf = buf == 0 and api.nvim_get_current_buf() or buf
    callback = callback or function() end
    if api.nvim_buf_get_name(buf) == '' then callback({ applied = {}, failed = { { error = 'save the document before exporting' } } }); return end
    local root = runner.root(buf)
    local cfg, status = require('nvim_config.coderunner').resolve(root, false)
    if not require('nvim_config.coderunner.trust').can_select(status) then
        callback({ applied = {}, failed = { { error = 'workspace configuration must be loaded with :CodeRunnerLoad' } } }); return
    end
    local list, err = blocks.get(buf, root)
    local report, plans, targets = { applied = {}, failed = {} }, {}, {}
    if not list then callback({ applied = {}, failed = { { error = err } } }); return end
    for _, block in ipairs(list) do
        local folder, message = M.folder(block, cfg.attachments)
        local adjacent
        if folder then adjacent, message = M.adjacent(block, folder) end
        if message then report.failed[#report.failed + 1] = { key = block.key, error = message }
        elseif adjacent then targets[#targets + 1] = block end
    end
    local function next_plan(i)
        if i > #targets then
            for _, plan in ipairs(plans) do
                local result, message = M.apply(buf, plan, plan.tick)
                cache.use(plan.source, -1)
                if result then report.applied[#report.applied + 1] = result
                else report.failed[#report.failed + 1] = { key = plan.block.key, error = message } end
            end
            require('nvim_config.coderunner.diagnostics').refresh(buf)
            callback(report); return
        end
        prepare(buf, targets[i], { existing_only = true, explicit = false, batch = true }, function(plan, message)
            if plan then plans[#plans + 1] = plan
            else report.failed[#report.failed + 1] = { key = targets[i].key, error = message } end
            next_plan(i + 1)
        end)
    end
    next_plan(1)
end
function M.stale(block, cfg)
    local folder = M.folder(block, cfg.attachments)
    if not folder then return end
    local adjacent = M.adjacent(block, folder)
    if not adjacent then return end
    local current = render.lookup(block, { format = adjacent.format })
    if not current.path or current.stale or current.status == 'none' then return end
    local bytes = cache.read(current.path)
    if bytes and bytes ~= cache.read(adjacent.path) then return adjacent.image end
end
function M.setup()
    local function report(result, err)
        if not result then vim.notify('coderunner: ' .. tostring(err), vim.log.levels.ERROR) end
    end
    api.nvim_create_user_command('CodeExport', function(args) M.start(0, args.args ~= '' and args.args or nil, {}, report) end, { nargs = '?' })
    api.nvim_create_user_command('CodeExportAll', function()
        M.all(0, function(result)
            for _, item in ipairs(result.failed) do vim.notify('coderunner: ' .. tostring(item.key or '') .. ': ' .. item.error, vim.log.levels.ERROR) end
        end)
    end, {})
end
return M
