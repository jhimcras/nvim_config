-- PlantUML markdown block rendering.
--
-- This module never edits markdown buffer text. It exposes generated diagrams as
-- virtual markdown image links so a renderer that scans extmarks/virtual text can
-- draw them while the source block remains intact.

local M = {}

local ns = vim.api.nvim_create_namespace('rendermark_plantuml')
local group

local defaults = {
    enabled = true,
    languages = { plantuml = true, puml = true, uml = true },
    jar_path = nil,
    debounce_ms = 500,
    spinner = { '|', '/', '-', '\\' },
}

local config = vim.deepcopy(defaults)
local states = {}
local missing_notified = false
local foldtext_expr = 'v:lua.RendermarkPlantumlFoldText()'

local function normalize_bufnr(buf)
    if not buf or buf == 0 then
        return vim.api.nvim_get_current_buf()
    end
    return buf
end

local function is_markdown_buffer(buf)
    buf = normalize_bufnr(buf)
    local ft = vim.bo[buf or 0].filetype
    return ft == 'markdown' or ft == 'markdown.mdx'
end

local function normalize_path(path)
    if not path or path == '' then
        return nil
    end
    return vim.fn.fnamemodify(path, ':p')
end

local function file_exists(path)
    return path and vim.fn.filereadable(path) == 1
end

local function file_size(path)
    if not path or not file_exists(path) then
        return nil
    end
    local size = vim.fn.getfsize(path)
    return size >= 0 and size or nil
end

local function configured_jar_path()
    return config.jar_path
        or vim.g.rendermark_plantuml_jar
        or vim.env.RENDERMARK_PLANTUML_JAR
        or vim.env.PLANTUML_JAR
end

local function shell_error_text()
    local jar = configured_jar_path()
    if jar and jar ~= '' then
        return 'PlantUML disabled: Java or PlantUML jar not found. Check RENDERMARK_PLANTUML_JAR / PLANTUML_JAR.'
    end
    return 'PlantUML disabled: install plantuml or set RENDERMARK_PLANTUML_JAR to the official plantuml.jar.'
end

local function sanitize_error_text(text)
    if not text or text == '' then
        return 'render failed'
    end
    text = text:gsub('%z', '\n'):gsub('\r\n', '\n'):gsub('\r', '\n'):gsub('%s+$', '')
    if text == '' then
        return 'render failed'
    end
    return text
end

local function render_error_text(stderr)
    local text = sanitize_error_text(stderr)
    if text:find('ClassNotFoundException:%s*net%.sourceforge%.plantuml%.Run')
        or text:find('Could not find or load main class net%.sourceforge%.plantuml%.Run') then
        local jar = normalize_path(configured_jar_path()) or '<unset>'
        return 'Invalid PlantUML jar: ' .. jar .. '. Set RENDERMARK_PLANTUML_JAR to the official executable plantuml.jar.'
    end
    return text
end

function M.resolve_command()
    local jar = normalize_path(configured_jar_path())
    if jar and file_exists(jar) then
        local java = vim.fn.exepath('java')
        if java ~= '' then
            return java, { '-jar', jar, '-tpng' }
        end
    end

    local wrapper = vim.fn.exepath('plantuml')
    if wrapper ~= '' then
        return wrapper, { '-tpng' }
    end

    return nil, nil, shell_error_text()
end

local function notify_missing_once(message)
    if missing_notified then
        return
    end
    missing_notified = true
    vim.schedule(function()
        vim.notify(message, vim.log.levels.WARN)
    end)
end

local function state_for(buf)
    local st = states[buf]
    if st then
        return st
    end

    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    st = {
        temp_dir = dir,
        cache = {},
        jobs = {},
        spinner = 1,
        debounce = nil,
        spinner_timer = nil,
        float = nil,
        folds = {},
        fold_windows = {},
        saved_fold_options = {},
    }
    states[buf] = st
    return st
end

local function close_timer(timer)
    if timer then
        pcall(function()
            timer:stop()
            timer:close()
        end)
    end
end

local function close_float(st)
    if st and st.float then
        if st.float.win and vim.api.nvim_win_is_valid(st.float.win) then
            pcall(vim.api.nvim_win_close, st.float.win, true)
        end
        if st.float.buf and vim.api.nvim_buf_is_valid(st.float.buf) then
            pcall(vim.api.nvim_buf_delete, st.float.buf, { force = true })
        end
        st.float = nil
    end
end

local function restore_fold_options(st, win)
    if not st or not st.saved_fold_options then
        return
    end
    local saved = st.saved_fold_options[win]
    if saved and vim.api.nvim_win_is_valid(win) then
        vim.wo[win].foldmethod = saved.foldmethod
        vim.wo[win].foldenable = saved.foldenable
        vim.wo[win].foldtext = saved.foldtext
    end
    st.saved_fold_options[win] = nil
    if st.fold_windows then
        st.fold_windows[win] = nil
    end
end

local function with_preserved_view(win, fn)
    if not vim.api.nvim_win_is_valid(win) then
        return
    end
    return vim.api.nvim_win_call(win, function()
        local view = vim.fn.winsaveview()
        local ok, result = pcall(fn)
        pcall(vim.fn.winrestview, view)
        if not ok then
            return nil, result
        end
        return result
    end)
end

local function ensure_fold_options(st, win)
    if st.saved_fold_options[win] == nil then
        st.saved_fold_options[win] = {
            foldmethod = vim.wo[win].foldmethod,
            foldenable = vim.wo[win].foldenable,
            foldtext = vim.wo[win].foldtext,
        }
    end
    vim.wo[win].foldmethod = 'manual'
    vim.wo[win].foldenable = true
    vim.wo[win].foldtext = foldtext_expr
    st.fold_windows[win] = true
end

local function delete_fold_at(win, fold)
    with_preserved_view(win, function()
        local line_count = vim.api.nvim_buf_line_count(0)
        local lnum = fold.start_row + 1
        if lnum < 1 or lnum > line_count then
            return
        end
        if vim.fn.foldclosed(lnum) ~= -1 or vim.fn.foldlevel(lnum) > 0 then
            vim.api.nvim_win_set_cursor(win, { lnum, 0 })
            vim.cmd('silent! normal! zd')
        end
    end)
end

local function ensure_fold(win, st, fold)
    with_preserved_view(win, function()
        local line_count = vim.api.nvim_buf_line_count(0)
        local start_lnum = fold.start_row + 1
        local end_lnum = math.min(fold.end_row + 1, line_count)
        if start_lnum < 1 or start_lnum >= end_lnum then
            return
        end

        ensure_fold_options(st, win)
        local closed_start = vim.fn.foldclosed(start_lnum)
        local closed_end = vim.fn.foldclosedend(start_lnum)
        if closed_start ~= start_lnum or closed_end ~= end_lnum then
            delete_fold_at(win, fold)
            vim.cmd(('silent! %d,%dfold'):format(start_lnum, end_lnum))
        end
    end)
end

local function fold_key(fold)
    return tostring(fold.start_row)
end

local function visible_or_touched_windows(buf, st)
    local wins = {}
    for _, win in ipairs(vim.fn.win_findbuf(buf)) do
        wins[win] = true
    end
    if st and st.fold_windows then
        for win in pairs(st.fold_windows) do
            wins[win] = true
        end
    end
    return wins
end

local function reconcile_folds(buf, desired)
    local st = states[buf]
    if not st then
        return
    end

    desired = desired or {}
    local previous = st.folds or {}
    local any_desired = next(desired) ~= nil
    local wins = visible_or_touched_windows(buf, st)

    for win in pairs(wins) do
        if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf then
            for key, old in pairs(previous) do
                local new = desired[key]
                if not new or new.end_row ~= old.end_row then
                    delete_fold_at(win, old)
                end
            end
            for _, fold in pairs(desired) do
                ensure_fold(win, st, fold)
            end
            if not any_desired then
                restore_fold_options(st, win)
            end
        else
            restore_fold_options(st, win)
        end
    end

    st.folds = desired
end

local function clear_folds(buf, st)
    if not st then
        return
    end
    local wins = visible_or_touched_windows(buf, st)
    for win in pairs(wins) do
        if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf then
            for _, fold in pairs(st.folds or {}) do
                delete_fold_at(win, fold)
            end
        end
        restore_fold_options(st, win)
    end
    st.folds = {}
end

local function cleanup_buf(buf)
    local st = states[buf]
    if not st then
        return
    end
    close_timer(st.debounce)
    close_timer(st.spinner_timer)
    close_float(st)
    clear_folds(buf, st)
    for _, job in pairs(st.jobs) do
        if job.kill then
            pcall(job.kill)
        end
    end
    if st.temp_dir then
        pcall(vim.fn.delete, st.temp_dir, 'rf')
    end
    states[buf] = nil
end

local function cleanup_all()
    for buf, _ in pairs(states) do
        cleanup_buf(buf)
    end
end

local function parse_fence_info(line)
    local ticks, lang = line:match('^%s*(```+)%s*([^%s`]*)')
    if ticks then
        return ticks, (lang or ''):lower()
    end
    local tildes
    tildes, lang = line:match('^%s*(~~~+)%s*([^%s~]*)')
    if tildes then
        return tildes, (lang or ''):lower()
    end
    return nil, nil
end

local function is_closing_fence(line, fence)
    if not fence then
        return false
    end
    local ch = fence:sub(1, 1)
    local escaped = ch == '`' and '`' or '~'
    local found = line:match('^%s*(' .. escaped .. escaped .. escaped .. '+)%s*$')
    return found and #found >= #fence
end

function M.find_blocks(buf)
    buf = normalize_bufnr(buf)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local blocks = {}
    local i = 1
    while i <= #lines do
        local fence, lang = parse_fence_info(lines[i])
        if fence and config.languages[lang] then
            local start = i - 1
            local j = i + 1
            while j <= #lines and not is_closing_fence(lines[j], fence) do
                j = j + 1
            end
            if j <= #lines then
                local body = {}
                for k = i + 1, j - 1 do
                    body[#body + 1] = lines[k]
                end
                blocks[#blocks + 1] = {
                    start_row = start,
                    end_row = j - 1,
                    lang = lang,
                    text = table.concat(body, '\n') .. '\n',
                }
                i = j + 1
            else
                i = i + 1
            end
        else
            i = i + 1
        end
    end
    return blocks
end

local function block_contains_cursor(block, win)
    win = win or 0
    if not vim.api.nvim_win_is_valid(win == 0 and vim.api.nvim_get_current_win() or win) then
        return false
    end
    local row = vim.api.nvim_win_get_cursor(win)[1] - 1
    return row >= block.start_row and row <= block.end_row
end

local function block_hash(block)
    return vim.fn.sha256(block.lang .. '\n' .. block.text)
end

local function render_paths(st, hash)
    return st.temp_dir .. '/' .. hash .. '.puml', st.temp_dir .. '/' .. hash .. '.png'
end

local function image_link(path)
    return '![plantuml](' .. path:gsub('\\', '/') .. ')'
end

local function read_png_size(path)
    if not path then
        return nil
    end
    local file = io.open(path, 'rb')
    if not file then
        return nil
    end
    local header = file:read(24)
    file:close()
    if not header or #header < 24 then
        return nil
    end
    if header:sub(1, 8) ~= '\137PNG\r\n\026\n' or header:sub(13, 16) ~= 'IHDR' then
        return nil
    end
    local b = { header:byte(17, 24) }
    local width = b[1] * 0x1000000 + b[2] * 0x10000 + b[3] * 0x100 + b[4]
    local height = b[5] * 0x1000000 + b[6] * 0x10000 + b[7] * 0x100 + b[8]
    if width <= 0 or height <= 0 then
        return nil
    end
    return { width = width, height = height }
end

local function float_dimensions_for_image(size, opts)
    opts = opts or {}
    local cell_width = tonumber(opts.cell_width) or tonumber(vim.g.neopp_cell_width_px) or 10
    local cell_height = tonumber(opts.cell_height) or tonumber(vim.g.neopp_cell_height_px) or 18
    local editor_width = math.max(1, vim.o.columns)
    local editor_height = math.max(1, vim.o.lines - vim.o.cmdheight)
    local requested_max_width = tonumber(opts.max_width) or math.max(20, editor_width)
    local requested_max_height = tonumber(opts.max_height) or math.max(4, editor_height)
    local max_width = math.min(editor_width, math.max(1, requested_max_width))
    local max_height = math.min(editor_height, math.max(1, requested_max_height))
    local width = size and size.width and math.ceil(size.width / math.max(1, cell_width)) or 30
    local height = size and size.height and math.ceil(size.height / math.max(1, cell_height)) or 6
    return {
        width = math.max(1, math.min(width, max_width)),
        height = math.max(1, math.min(height, max_height)),
    }
end

local function fallback_foldtext()
    if type(_G.FoldText) == 'function' then
        local ok, text = pcall(_G.FoldText)
        if ok and text ~= nil then
            return text
        end
    end
    return vim.fn.getline(vim.v.foldstart)
end

function M.foldtext()
    local buf = vim.api.nvim_get_current_buf()
    local st = states[buf]
    local start_row = vim.v.foldstart - 1
    local fold = st and st.folds and st.folds[tostring(start_row)] or nil
    if fold and fold.end_row == vim.v.foldend - 1 and fold.text then
        return fold.text
    end
    return fallback_foldtext()
end

_G.RendermarkPlantumlFoldText = function()
    return M.foldtext()
end

local function ensure_conceal_windows(buf, conceal_cursor)
    local st = states[buf]
    if st then
        st.saved_concealcursor = st.saved_concealcursor or {}
    end
    local visible = {}
    for _, win in ipairs(vim.fn.win_findbuf(buf)) do
        if vim.api.nvim_win_is_valid(win) then
            visible[win] = true
            if vim.wo[win].conceallevel < 2 then
                vim.wo[win].conceallevel = 2
            end
            if conceal_cursor then
                if st and st.saved_concealcursor[win] == nil and vim.wo[win].concealcursor ~= 'nvic' then
                    st.saved_concealcursor[win] = vim.wo[win].concealcursor
                end
                vim.wo[win].concealcursor = 'nvic'
            elseif st and st.saved_concealcursor[win] ~= nil then
                vim.wo[win].concealcursor = st.saved_concealcursor[win]
                st.saved_concealcursor[win] = nil
            end
        end
    end
    if st and st.saved_concealcursor then
        for win in pairs(st.saved_concealcursor) do
            if not visible[win] or not vim.api.nvim_win_is_valid(win) then
                st.saved_concealcursor[win] = nil
            end
        end
    end
end

local function set_spinner(st, buf, block)
    local frames = config.spinner
    local frame = frames[((st.spinner or 1) - 1) % #frames + 1]
    vim.api.nvim_buf_set_extmark(buf, ns, block.start_row, 0, {
        virt_text = { { frame .. ' plantuml', 'DiagnosticInfo' } },
        virt_text_pos = 'overlay',
        priority = 250,
    })
end

local function conceal_line(buf, row)
    local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ''
    vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
        end_col = #line,
        conceal = '',
        priority = 240,
    })
end

local function set_image_link(buf, block, path, conceal_cursor, desired_folds)
    local text = image_link(path)
    ensure_conceal_windows(buf, conceal_cursor)
    for row = block.start_row, block.end_row do
        conceal_line(buf, row)
    end
    if desired_folds then
        local fold = {
            start_row = block.start_row,
            end_row = block.end_row,
            text = text,
        }
        desired_folds[fold_key(fold)] = fold
    end
    vim.api.nvim_buf_set_extmark(buf, ns, block.start_row, 0, {
        virt_text = { { text, 'Normal' } },
        virt_text_pos = 'overlay',
        priority = 260,
        right_gravity = false,
    })
end

local function set_error(buf, block, message)
    vim.api.nvim_buf_set_extmark(buf, ns, block.end_row, 0, {
        virt_lines = { { { ' [plantuml: ' .. message .. ']', 'WarningMsg' } } },
        virt_lines_above = false,
        priority = 230,
    })
end

local function ensure_spinner_timer(buf, st)
    if st.spinner_timer then
        return
    end
    st.spinner_timer = vim.uv.new_timer()
    st.spinner_timer:start(120, 120, vim.schedule_wrap(function()
        if not vim.api.nvim_buf_is_valid(buf) then
            cleanup_buf(buf)
            return
        end
        local has_pending = false
        for _, entry in pairs(st.cache) do
            if entry.status == 'pending' then
                has_pending = true
                break
            end
        end
        if not has_pending then
            close_timer(st.spinner_timer)
            st.spinner_timer = nil
            return
        end
        st.spinner = (st.spinner or 1) + 1
        M.refresh(buf)
    end))
end

local function mode_is_visual_or_select()
    local mode = vim.api.nvim_get_mode().mode
    return mode == 'v' or mode == 'V' or mode == '\022'
        or mode == 's' or mode == 'S' or mode == '\019'
end

local function strip_indent_space_chars(text)
    if type(text) ~= 'string' then return '' end
    return text
        :gsub('[%s]', '')
        :gsub('\194\160', '')
        :gsub('\226\128[\128-\138]', '')
        :gsub('\226\128\175', '')
        :gsub('\226\129\159', '')
        :gsub('\227\128\128', '')
end

local function text_has_indent_marker(text)
    return text == '▎' or text == '▏' or text == '▕' or text == '│' or text == '┃' or text == '|'
end

local function highlight_has(highlight, needle)
    if type(highlight) == 'string' then
        return highlight:lower():find(needle, 1, true) ~= nil
    end
    if type(highlight) == 'table' then
        for _, hl in ipairs(highlight) do
            if type(hl) == 'string' and hl:lower():find(needle, 1, true) then
                return true
            end
        end
    end
    return false
end

local function is_render_markdown_prefix(namespace, highlight)
    if type(namespace) ~= 'string' or not namespace:lower():find('render%-markdown') then
        return false
    end
    return highlight_has(highlight, 'head')
        or highlight_has(highlight, 'bullet')
        or highlight_has(highlight, 'check')
end

local function is_indent_text(text, highlight, namespace)
    if is_render_markdown_prefix(namespace, highlight) then
        return false
    end

    local rest = strip_indent_space_chars(text)
    if rest == '' then return true end
    return text_has_indent_marker(rest)
        and (highlight_has(highlight, 'indent')
            or (type(namespace) == 'string' and namespace:lower():find('indent', 1, true) ~= nil))
end

local function virt_text_width(virt_text, namespace)
    if type(virt_text) ~= 'table' then return 0 end
    local width = 0
    for _, chunk in ipairs(virt_text) do
        local text = type(chunk) == 'table' and chunk[1] or nil
        local highlight = type(chunk) == 'table' and chunk[2] or nil
        if type(text) ~= 'string' then return 0 end
        if not is_indent_text(text, highlight, namespace) then return 0 end
        width = width + vim.fn.strdisplaywidth(text)
    end
    return width
end

local function virtual_indent_width(buf, row, col)
    local ok, marks = pcall(vim.api.nvim_buf_get_extmarks, buf, -1, { row, 0 }, { row + 1, 0 }, { details = true })
    if not ok then return 0 end
    local namespaces = vim.api.nvim_get_namespaces()
    local namespace_names = {}
    for name, id in pairs(namespaces) do
        namespace_names[id] = name
    end

    local width = 0
    for _, mark in ipairs(marks) do
        local mark_row = mark[2]
        local mark_col = mark[3]
        local details = mark[4] or {}
        if mark_row == row and (mark_col <= col or (col == 0 and mark_col <= 1)) then
            local virt_width = virt_text_width(details.virt_text, namespace_names[details.ns_id])
            if virt_width > 0 and (details.virt_text_pos == 'inline'
                or details.virt_text_pos == 'overlay'
                or details.virt_text_win_col ~= nil) then
                width = width + virt_width
            end
        end
    end
    return width
end

local function float_config_for_block(win, block, width, height)
    win = win == 0 and vim.api.nvim_get_current_win() or win
    local topline = vim.api.nvim_win_call(win, function()
        return vim.fn.line('w0')
    end) - 1
    local screenpos = vim.fn.win_screenpos(win)
    local screen_row = type(screenpos) == 'table' and (screenpos[1] or 1) or 1
    local screen_col = type(screenpos) == 'table' and (screenpos[2] or 1) or 1
    local win_top = screen_row - 1
    local win_left = screen_col - 1
    local editor_height = math.max(1, vim.o.lines - vim.o.cmdheight)
    local editor_width = math.max(1, vim.o.columns)

    local buf = vim.api.nvim_win_get_buf(win)
    local anchor_row = math.max(0, block.start_row - topline)
    local block_indent = 0
    local anchor_col = 0
    local lines = vim.api.nvim_buf_get_lines(buf, block.start_row, block.start_row + 1, false)
    if lines[1] then
        local leading = lines[1]:match('^%s*') or ''
        anchor_col = #leading
        block_indent = vim.fn.strdisplaywidth(leading)
    end

    local function clamp(value, low, high)
        if high < low then
            return low
        end
        return math.max(low, math.min(value, high))
    end

    local total_width = math.max(1, math.min(width or 1, editor_width))
    local total_height = 1
    local row = clamp(win_top + anchor_row, 0, editor_height - total_height)
    local col = clamp(win_left + block_indent + virtual_indent_width(buf, block.start_row, anchor_col),
        0, editor_width - total_width)

    return {
        relative = 'editor',
        row = row,
        col = col,
        width = total_width,
        height = total_height,
        style = 'minimal',
        focusable = false,
        zindex = 70,
    }
end

local function preview_metadata(buf, source_win, block, path)
    local line = vim.api.nvim_buf_get_lines(buf, block.start_row, block.start_row + 1, false)[1] or ''
    local leading = line:match('^%s*') or ''
    return {
        buf = buf,
        win = source_win,
        start_row = block.start_row,
        anchor_col = #leading,
        path = path,
    }
end

local function open_float(buf, path, block)
    local st = state_for(buf)
    local current_win = vim.api.nvim_get_current_win()
    local text = image_link(path)
    local fwidth = math.max(1, math.min(vim.fn.strdisplaywidth(text), math.max(1, vim.o.columns)))
    local fheight = 1
    local config_for_float = float_config_for_block(current_win, block, fwidth, fheight)
    local metadata = preview_metadata(buf, current_win, block, path)

    if st.float and st.float.path == path
        and st.float.win and vim.api.nvim_win_is_valid(st.float.win)
        and st.float.buf and vim.api.nvim_buf_is_valid(st.float.buf) then
        pcall(vim.api.nvim_win_set_config, st.float.win, config_for_float)
        vim.w[st.float.win].rendermark_plantuml_preview_source = metadata
        return
    end
    close_float(st)

    local fbuf = vim.api.nvim_create_buf(false, true)
    vim.bo[fbuf].buftype = 'nofile'
    vim.bo[fbuf].bufhidden = 'wipe'
    vim.bo[fbuf].filetype = 'markdown'
    vim.api.nvim_buf_set_lines(fbuf, 0, -1, false, { image_link(path) })
    vim.bo[fbuf].modifiable = false

    local win = vim.api.nvim_open_win(fbuf, false, config_for_float)
    vim.w[win].rendermark_plantuml_preview_source = metadata
    st.float = { buf = fbuf, win = win, path = path }
end

local function finish_render(buf, hash, code, stderr, preview)
    vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(buf) then
            cleanup_buf(buf)
            return
        end
        local st = states[buf]
        if not st then
            return
        end
        st.jobs[hash] = nil
        local entry = st.cache[hash]
        if not entry then
            return
        end
        if code == 0 and file_exists(entry.png) then
            entry.status = 'ready'
            entry.error = nil
        else
            entry.status = 'error'
            entry.error = render_error_text(stderr)
        end
        entry.exit_code = code
        M.refresh(buf)
    end)
end

local function run_command(buf, hash, puml, png, preview)
    local cmd, base_args, err = M.resolve_command()
    if not cmd then
        notify_missing_once(err)
        return false
    end

    local st = state_for(buf)
    vim.fn.writefile(vim.split(st.cache[hash].text, '\n', { plain = true, trimempty = false }), puml, 'b')
    local args = vim.deepcopy(base_args)
    args[#args + 1] = puml
    local argv = vim.list_extend({ cmd }, vim.deepcopy(args))
    st.cache[hash].argv = argv

    local stderr = {}
    if vim.system then
        local job = vim.system(argv, { text = true, stderr = true }, function(obj)
            finish_render(buf, hash, obj.code, obj.stderr, preview)
        end)
        st.jobs[hash] = { kill = function() job:kill(15) end }
    else
        local ut = require('util')
        local _, kill = ut.AsyncProcess(cmd, args, st.temp_dir, {
            onread = function(_, data)
                if data then
                    stderr[#stderr + 1] = data
                end
            end,
            onexit = function(code)
                finish_render(buf, hash, code, table.concat(stderr), preview)
            end,
        })
        st.jobs[hash] = { kill = kill }
    end
    return true
end

local function ensure_render(buf, block, preview)
    local st = state_for(buf)
    local hash = block_hash(block)
    local puml, png = render_paths(st, hash)
    local entry = st.cache[hash]
    if entry then
        if preview and entry.status == 'ready' then
            open_float(buf, entry.png, block)
        end
        return entry
    end

    entry = {
        status = 'pending',
        puml = puml,
        png = png,
        text = block.text,
    }
    st.cache[hash] = entry
    if run_command(buf, hash, puml, png, preview) then
        ensure_spinner_timer(buf, st)
    else
        entry.status = 'disabled'
    end
    return entry
end

local function current_block(buf, blocks)
    local win = vim.api.nvim_get_current_win()
    if vim.api.nvim_win_get_buf(win) ~= buf then
        return nil
    end
    for _, block in ipairs(blocks) do
        if block_contains_cursor(block, win) then
            return block
        end
    end
    return nil
end

function M.refresh(buf)
    buf = normalize_bufnr(buf)
    if not vim.api.nvim_buf_is_valid(buf) or not is_markdown_buffer(buf) then
        return
    end
    if config.enabled == false then
        return
    end

    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    local blocks = M.find_blocks(buf)
    if #blocks == 0 then
        local st = states[buf]
        if st then
            close_float(st)
            reconcile_folds(buf, {})
        end
        return
    end

    local active = current_block(buf, blocks)
    local read_mode = vim.b[buf].markdown_read_mode or vim.b[buf].read_mode
    local st = state_for(buf)
    local visual_or_select = mode_is_visual_or_select()
    if read_mode or visual_or_select then
        close_float(st)
    end
    local desired_folds = {}
    local active_still_present = false
    if not read_mode then
        ensure_conceal_windows(buf, false)
    end

    for _, block in ipairs(blocks) do
        local is_active = active
            and active.start_row == block.start_row
            and active.end_row == block.end_row
        if is_active then
            active_still_present = true
        end

        local entry = ensure_render(buf, block, false)
        if is_active and visual_or_select then
            -- Leave the active source block raw while a visual/select selection is active.
        elseif is_active and not read_mode then
            if entry.status == 'ready' then
                open_float(buf, entry.png, block)
            elseif entry.status == 'pending' then
                set_spinner(st, buf, block)
            elseif entry.status == 'error' then
                set_error(buf, block, entry.error)
            end
        elseif entry.status == 'ready' then
            set_image_link(buf, block, entry.png, read_mode, desired_folds)
        elseif entry.status == 'pending' then
            set_spinner(st, buf, block)
        elseif entry.status == 'error' then
            set_error(buf, block, entry.error)
        end
    end

    reconcile_folds(buf, desired_folds)

    if not active_still_present then
        close_float(st)
    end
end

local pending_refresh = {}
local function schedule_refresh(buf)
    if pending_refresh[buf] then
        return
    end
    pending_refresh[buf] = true
    vim.schedule(function()
        pending_refresh[buf] = nil
        M.refresh(buf)
    end)
end

local function schedule_active_preview(buf)
    if not vim.api.nvim_buf_is_valid(buf) or not is_markdown_buffer(buf) then
        return
    end
    local st = state_for(buf)
    close_timer(st.debounce)
    st.debounce = vim.uv.new_timer()
    st.debounce:start(config.debounce_ms, 0, vim.schedule_wrap(function()
        close_timer(st.debounce)
        st.debounce = nil
        if not vim.api.nvim_buf_is_valid(buf) then
            cleanup_buf(buf)
            return
        end
        local block = current_block(buf, M.find_blocks(buf))
        if block then
            ensure_render(buf, block, true)
        end
        M.refresh(buf)
    end))
end

function M.clean(buf)
    buf = normalize_bufnr(buf)
    if vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    end
    cleanup_buf(buf)
end

local function quoted_argv(argv)
    if not argv then
        return '<not started>'
    end
    local parts = {}
    for _, item in ipairs(argv) do
        if item:find('%s') then
            parts[#parts + 1] = '"' .. item .. '"'
        else
            parts[#parts + 1] = item
        end
    end
    return table.concat(parts, ' ')
end

local function debug_lines(buf)
    buf = normalize_bufnr(buf)
    local cmd, args, err = M.resolve_command()
    local blocks = vim.api.nvim_buf_is_valid(buf) and M.find_blocks(buf) or {}
    local st = states[buf]
    local lines = {
        'rendermark PlantUML debug',
        '',
        'buffer: ' .. tostring(buf),
        'filetype: ' .. (vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].filetype or '<invalid>'),
        'configured jar: ' .. tostring(normalize_path(configured_jar_path()) or '<unset>'),
        'resolved command: ' .. (cmd and quoted_argv(vim.list_extend({ cmd }, vim.deepcopy(args or {}))) or tostring(err)),
        'temp dir: ' .. tostring(st and st.temp_dir or '<not created>'),
        'blocks: ' .. tostring(#blocks),
    }

    if st and st.float then
        lines[#lines + 1] = 'float path: ' .. tostring(st.float.path or '<none>')
    end

    for i, block in ipairs(blocks) do
        local hash = block_hash(block)
        local entry = st and st.cache[hash] or nil
        local puml, png = st and render_paths(st, hash) or '<not created>', '<not created>'
        if st then
            puml, png = render_paths(st, hash)
        end
        lines[#lines + 1] = ''
        lines[#lines + 1] = ('block %d: rows %d-%d lang=%s'):format(i, block.start_row + 1, block.end_row + 1, block.lang)
        lines[#lines + 1] = '  hash: ' .. hash
        lines[#lines + 1] = '  status: ' .. tostring(entry and entry.status or '<not rendered>')
        lines[#lines + 1] = '  command: ' .. quoted_argv(entry and entry.argv or nil)
        lines[#lines + 1] = '  exit code: ' .. tostring(entry and entry.exit_code or '<none>')
        lines[#lines + 1] = '  puml: ' .. puml .. ' exists=' .. tostring(file_exists(puml)) .. ' size=' .. tostring(file_size(puml) or '<none>')
        lines[#lines + 1] = '  png: ' .. png .. ' exists=' .. tostring(file_exists(png)) .. ' size=' .. tostring(file_size(png) or '<none>')
        if entry and entry.error then
            lines[#lines + 1] = '  error: ' .. entry.error
        end
    end

    return lines
end

function M.debug(buf)
    buf = normalize_bufnr(buf)
    M.refresh(buf)
    local out = vim.api.nvim_create_buf(false, true)
    vim.bo[out].buftype = 'nofile'
    vim.bo[out].bufhidden = 'wipe'
    vim.bo[out].filetype = 'text'
    vim.api.nvim_buf_set_lines(out, 0, -1, false, debug_lines(buf))
    vim.bo[out].modifiable = false
    vim.cmd('botright split')
    vim.api.nvim_win_set_buf(0, out)
end

function M.setup(opts)
    config = vim.tbl_deep_extend('force', vim.deepcopy(defaults), opts or {})
    config.jar_path = config.jar_path or vim.g.rendermark_plantuml_jar or vim.env.RENDERMARK_PLANTUML_JAR or vim.env.PLANTUML_JAR
    missing_notified = false

    group = vim.api.nvim_create_augroup('rendermark_plantuml', { clear = true })

    pcall(vim.api.nvim_del_user_command, 'RendermarkPlantumlRefresh')
    pcall(vim.api.nvim_del_user_command, 'RendermarkPlantumlClean')
    pcall(vim.api.nvim_del_user_command, 'RendermarkPlantumlDebug')
    vim.api.nvim_create_user_command('RendermarkPlantumlRefresh', function()
        M.refresh(0)
    end, {})
    vim.api.nvim_create_user_command('RendermarkPlantumlClean', function()
        M.clean(0)
    end, {})
    vim.api.nvim_create_user_command('RendermarkPlantumlDebug', function()
        M.debug(0)
    end, {})

    if config.enabled == false then
        return
    end

    local cmd, _, err = M.resolve_command()
    if not cmd then
        notify_missing_once(err)
        return
    end

    vim.api.nvim_create_autocmd('FileType', {
        group = group,
        pattern = { 'markdown', 'markdown.mdx' },
        callback = function(args)
            schedule_refresh(args.buf)
        end,
    })

    vim.api.nvim_create_autocmd({
        'BufWinEnter', 'WinEnter', 'CursorMoved', 'CursorMovedI',
        'InsertEnter', 'InsertLeave', 'ModeChanged', 'WinLeave',
    }, {
        group = group,
        callback = function(args)
            local buf = args.buf or vim.api.nvim_get_current_buf()
            if is_markdown_buffer(buf) then
                schedule_refresh(buf)
            end
        end,
    })

    vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, {
        group = group,
        callback = function(args)
            local buf = args.buf or vim.api.nvim_get_current_buf()
            if is_markdown_buffer(buf) then
                schedule_active_preview(buf)
                schedule_refresh(buf)
            end
        end,
    })

    vim.api.nvim_create_autocmd({ 'BufDelete', 'BufWipeout' }, {
        group = group,
        callback = function(args)
            cleanup_buf(args.buf)
        end,
    })

    vim.api.nvim_create_autocmd('VimLeavePre', {
        group = group,
        callback = cleanup_all,
    })
end

M._test = {
    cleanup_buf = cleanup_buf,
    debug_lines = debug_lines,
    float_dimensions_for_image = float_dimensions_for_image,
    float_config_for_block = float_config_for_block,
    image_link = image_link,
    namespace = ns,
    read_png_size = read_png_size,
    render_error_text = render_error_text,
    states = states,
}

return M
