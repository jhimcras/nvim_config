-- Soft-wrap for markdown: 'wrap' is off and continuation rows are virt_lines.
-- The cursor line stays raw on one row, since the cursor can't enter virt_lines.
-- Inline styling is re-created from treesitter highlight queries.

local M = {}
local wrap_text = require('nvim_config.rendermark.wrap.text')
local deco = require('nvim_config.rendermark.deco')
local html = require('nvim_config.rendermark.html')
local inline_style = require('nvim_config.rendermark.wrap.inline')
local table_render = require('nvim_config.rendermark.wrap.table')
local table_state = require('nvim_config.rendermark.table_state')

local defaults = {
    markdown = true,
    left_pad = 2,        -- left reading margin (columns), via 'statuscolumn'
    right_pad = 2,       -- right reading margin (columns)
    max_width = nil,     -- text column width cap (nil = no cap)
    min_text_width = 20, -- don't wrap when the text column is narrower than this
    hl = nil,            -- highlight group for continuation rows (nil = default)
    table = true,               -- render markdown tables with wrapped cells
    table_max_col_width = 30,   -- per-column width cap (display columns)
    table_min_col_width = 5,    -- per-column floor when the table must shrink
}

local config = vim.deepcopy(defaults)
local ns = vim.api.nvim_create_namespace('markdown_visual_wrap')
local group
local saved_state = {} -- per-window saved options, keyed by window id
local table_rows = table_state.rows
M.table_row = table_state.table_row
M.table_source_rows = table_state.table_source_rows
M.split_cells_pos = table_render.split_cells_pos
M.split_cells = table_render.split_cells
M.parse_aligns = table_render.parse_aligns
M.wrap_cell = table_render.wrap_cell
M.compute_table_layout = table_render.compute_table_layout
-- Per-window fold-change detection state (see the decoration provider in M.setup).
local win_seen, win_settled = {}, {}
-- Last full render per window, for the incremental cursor path:
-- { buf, key, foreign, cursor, covered = { [row0] = true } }.
local rendered = {}
local owner = {} -- buf -> window whose render its namespaces hold
local typing = {} -- win -> generation of the pending insert-mode refresh
local TYPING_DEBOUNCE_MS = 100

local code_query -- lazy treesitter query: code blocks
local function get_code_query()
    if code_query == nil then
        local ok, q = pcall(vim.treesitter.query.parse, 'markdown',
            '[(fenced_code_block) (indented_code_block)] @cb')
        code_query = ok and q or false
    end
    return code_query or nil
end

-- Continuation indent in display columns.
function M.compute_indent(text)
    return wrap_text.compute_indent(text, deco.metrics())
end

-- Flatten overlapping intervals { s, e, hl, conceal, priority, seq } into sorted,
-- non-overlapping runs (0-based, end-exclusive bytes). Later (priority, seq) wins;
-- conceal_anchor ensures a replacement char is emitted once.
function M.flatten_runs(intervals, line_len)
    return wrap_text.flatten_runs(intervals, line_len)
end

-- Prepend the base row highlight; inline groups win.
local function with_base(hl)
    return wrap_text.with_base(config.hl, hl)
end

-- Append a chunk, merging with the previous one when the hl stack matches.
local function push_chunk(out, text, hl)
    return wrap_text.push_chunk(out, text, hl)
end

-- Chunks for byte range [sb, eb) of `line` under the flattened runs.
local function slice_chunks(out, line, runs, sb, eb)
    return wrap_text.slice_chunks(out, line, runs, sb, eb, config.hl)
end

-- Returns first_end_byte (nil if it fits), continuation lines, and their byte spans.
function M.wrap_line(text, width1, widthN, indent, runs, inserts)
    return wrap_text.wrap_line(text, width1, widthN, indent, runs, inserts)
end

local function is_markdown_buffer(buf)
    local ft = vim.bo[buf or 0].filetype
    return ft == 'markdown' or ft == 'markdown.mdx'
end

local function buffer_enabled(buf)
    return vim.g.markdown_visual_wrap_enabled ~= false and vim.b[buf].markdown_visual_wrap == true
end

-- Visible { first, last } ranges (0-based, half-open) with closed folds removed.
local function visible_segments(win, topline, botline)
    if botline - topline < vim.api.nvim_win_get_height(win) then
        return { { math.max(topline - 1, 0), botline } }
    end
    return vim.api.nvim_win_call(win, function()
        local segs, lnum = {}, topline
        while lnum <= botline do
            if vim.fn.foldclosed(lnum) == -1 then
                local s = lnum
                repeat
                    lnum = lnum + 1
                until lnum > botline or vim.fn.foldclosed(lnum) ~= -1
                segs[#segs + 1] = { s - 1, lnum - 1 }
            else
                lnum = vim.fn.foldclosedend(lnum) + 1
            end
        end
        return segs
    end)
end

-- Decorate one visible range [first, last).
local function render_range(buf, first, last, width, cursor_row, images_active)
    -- Full parse so a partly visible table keeps its node range; captures stay in range.
    local in_code, in_table, tables = {}, {}, {}
    local inline = {} -- row -> flattened inline highlight/conceal runs
    -- Foreign extmark metrics, so the break matches the displayed width.
    local img_ns = vim.api.nvim_create_namespace('rendermark_neopp_images')
    local ex_conceals, inserts = inline_style.collect_deco(buf, first, last, ns, img_ns)
    local ts_ok, parser = pcall(vim.treesitter.get_parser, buf, 'markdown')
    if ts_ok and parser then
        -- Parse markdown_inline injections in the range.
        local ok_tree, trees = pcall(function() return parser:parse({ first, last }) end)
        local tree = ok_tree and trees and trees[1]
        if tree then
            local root = tree:root()
            local cq = get_code_query()
            if cq then
                for _, node in cq:iter_captures(root, buf, first, last) do
                    local r1, _, r2, c2 = node:range()
                    if c2 == 0 then r2 = r2 - 1 end -- node ends at start of r2: exclude r2
                    for l = r1, r2 do
                        in_code[l] = true
                    end
                end
            end
            tables = table_state.find_tables(buf, root, first, last)
            for _, t in ipairs(tables) do
                for l = t[1], t[2] do
                    in_table[l] = true
                end
            end
            inline = inline_style.collect_inline(parser, buf, first, last, ex_conceals)
        end
    end

    for _, t in ipairs(tables) do
        table_render.render_table(buf, t[1], t[2], width, cursor_row, inline, config, ns)
    end

    -- rendermark.image lays out image-link lines itself.
    local image = images_active and require('nvim_config.rendermark.image') or nil

    for lnum = first, last - 1 do
        if lnum + 1 ~= cursor_row and not in_code[lnum] and not in_table[lnum]
            and not html.is_hidden(buf, lnum) then
            local text = vim.api.nvim_buf_get_lines(buf, lnum, lnum + 1, false)[1]
            if image and text and image.line_has_image_link(text) then
                -- handled by rendermark.image
            elseif text and #text > 0 then
                local indent = M.compute_indent(text)
                local r = M.wrap_line(text, width, width - indent, indent,
                    inline[lnum], inserts[lnum])
                if r.first_end_byte then
                    vim.api.nvim_buf_set_extmark(buf, ns, lnum, r.first_end_byte, {
                        end_col = #text,
                        conceal = '',
                    })
                    local indent_str = string.rep(' ', indent)
                    -- Repeat the block quote bar on continuation rows.
                    local pre = deco.prefix_chunks(text, indent)
                    local vlines = {}
                    for k = 1, #r.lines do
                        local chunks = {}
                        if pre then
                            for _, c in ipairs(pre) do
                                push_chunk(chunks, c[1], with_base(c[2]))
                            end
                        elseif indent > 0 then
                            push_chunk(chunks, indent_str, with_base(nil))
                        end
                        slice_chunks(chunks, text, inline[lnum],
                            r.spans[k][1], r.spans[k][2])
                        if #chunks == 0 then
                            chunks[1] = { '' }
                        end
                        vlines[#vlines + 1] = chunks
                    end
                    vim.api.nvim_buf_set_extmark(buf, ns, lnum, 0, { virt_lines = vlines })
                end
            end
        end
    end
end

local function paint_deco(buf, segs, rule_width, cursor_row)
    deco.clear(buf)
    for _, seg in ipairs(segs) do
        deco.render_range(buf, seg[1], seg[2], rule_width, cursor_row)
    end
end

local function text_width(win, info)
    local width = vim.api.nvim_win_get_width(win) - info.textoff - config.right_pad
    if config.max_width and config.max_width > 0 then
        width = math.min(width, config.max_width)
    end
    return width
end

-- Everything besides the cursor row that a render depends on.
local function view_key(win, buf, info, images_active)
    local m = deco.metrics()
    return table.concat({
        buf, vim.api.nvim_buf_get_changedtick(buf), info.width, info.height,
        info.textoff, info.topline, info.leftcol, tostring(vim.w[win].read_mode_active),
        tostring(images_active), m.heading, m.checkbox,
    }, ':')
end

-- Other plugins' extmarks feed collect_deco; any change there needs a full render.
local own_ns
local function foreign_sig(buf, segs)
    if not own_ns then
        own_ns = {}
        for _, name in ipairs({ 'markdown_visual_wrap', 'rendermark_deco', 'rendermark_html',
            'rendermark_html_state', 'rendermark_neopp_images' }) do
            own_ns[vim.api.nvim_create_namespace(name)] = true
        end
    end
    local parts = {}
    for _, seg in ipairs(segs) do
        local marks = vim.api.nvim_buf_get_extmarks(buf, -1, { seg[1], 0 }, { seg[2] - 1, -1 },
            { details = true })
        for _, m in ipairs(marks) do
            local d = m[4]
            if not own_ns[d.ns_id] then
                local text = {}
                for _, ch in ipairs(d.virt_text or {}) do
                    text[#text + 1] = ch[1]
                end
                parts[#parts + 1] = table.concat({
                    d.ns_id, m[2], m[3], d.end_row or '', d.end_col or '',
                    d.conceal or '', tostring(d.hl_group), d.priority or '',
                    d.virt_text_pos or '', table.concat(text),
                }, ':')
            end
        end
    end
    return table.concat(parts, '|')
end

local function remember(win, buf, key, segs, cursor_row)
    local covered = {}
    for _, seg in ipairs(segs) do
        for row = seg[1], seg[2] - 1 do covered[row] = true end
    end
    rendered[win] = {
        buf = buf, key = key, foreign = foreign_sig(buf, segs),
        cursor = cursor_row, covered = covered,
    }
    owner[buf] = win
    typing[win] = nil
end

function M.refresh(win)
    if not win or win == 0 then
        win = vim.api.nvim_get_current_win()
    end
    if not vim.api.nvim_win_is_valid(win) then
        return
    end
    local buf = vim.api.nvim_win_get_buf(win)
    if not buffer_enabled(buf) then
        return
    end
    if is_markdown_buffer(buf) then deco.visible_fences(buf, true) end

    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    table_rows[buf] = {}
    deco.clear(buf)
    rendered[win] = nil
    owner[buf] = nil

    -- Can't compensate leftcol per line; clear and bail until it's back to 0.
    local leftcol = vim.api.nvim_win_call(win, function()
        return vim.fn.winsaveview().leftcol
    end)
    if leftcol > 0 then
        html.clear(buf)
        return
    end

    local info = vim.fn.getwininfo(win)[1]
    local width = text_width(win, info)
    if width < config.min_text_width then
        return
    end

    -- read_mode wraps the cursor line too: -1 matches no line.
    local cursor_row = vim.w[win].read_mode_active and -1
        or vim.api.nvim_win_get_cursor(win)[1]
    local images_active = require('nvim_config.rendermark.image').is_active()
    -- Keep the line above topline decorated so Ctrl-Y scrolls one row at a time.
    local segs = visible_segments(win, math.max(1, info.topline - 1), info.botline)
    html.refresh(buf, cursor_row - 1, segs)
    -- Decorations first: collect_deco snapshots them for line widths.
    local rule_width = vim.api.nvim_win_get_width(win) - info.textoff
    paint_deco(buf, segs, rule_width, cursor_row)
    for _, seg in ipairs(segs) do
        render_range(buf, seg[1], seg[2], width, cursor_row, images_active)
    end
    remember(win, buf, view_key(win, buf, info, images_active), segs, cursor_row)
    win_settled[win] = true
    if images_active then require('nvim_config.rendermark.image').schedule_image_sync() end
end

local function layout_sig(buf, ranges)
    local parts = {}
    for _, r in ipairs(ranges) do
        local marks = vim.api.nvim_buf_get_extmarks(buf, -1, { r[1], 0 }, { r[2] - 1, -1 },
            { details = true, type = 'virt_lines' })
        for _, m in ipairs(marks) do
            parts[#parts + 1] = m[2] .. '=' .. #(m[4].virt_lines or {})
        end
        for row = r[1], r[2] - 1 do
            for _, img in ipairs(M.table_row(buf, row) or {}) do
                local l = img.table_layout
                parts[#parts + 1] = table.concat({ row, l.row, l.col, l.width, l.height }, ',')
            end
        end
    end
    return table.concat(parts, '|')
end

-- Cursor-only refresh: re-render the old and new cursor rows (and rows that came
-- into view), else fall back to a full refresh when anything else changed.
local function refresh_cursor(win)
    if not vim.api.nvim_win_is_valid(win) then
        return
    end
    local buf = vim.api.nvim_win_get_buf(win)
    local last = rendered[win]
    if not last or last.buf ~= buf or owner[buf] ~= win or not buffer_enabled(buf) then
        return M.refresh(win)
    end
    if is_markdown_buffer(buf) then deco.visible_fences(buf, true) end
    local cursor_row = vim.w[win].read_mode_active and -1
        or vim.api.nvim_win_get_cursor(win)[1]
    local info = vim.fn.getwininfo(win)[1]
    local images_active = require('nvim_config.rendermark.image').is_active()
    local key = view_key(win, buf, info, images_active)
    if key ~= last.key then
        -- Typing on the cursor row: the debounced refresh renders it.
        if typing[win] and cursor_row == last.cursor then
            return
        end
        return M.refresh(win)
    end
    local segs = visible_segments(win, math.max(1, info.topline - 1), info.botline)
    if foreign_sig(buf, segs) ~= last.foreign then
        return M.refresh(win)
    end

    local rows = {}
    if cursor_row ~= last.cursor then
        if last.cursor > 0 then rows[#rows + 1] = { last.cursor - 1, last.cursor } end
        if cursor_row > 0 then rows[#rows + 1] = { cursor_row - 1, cursor_row } end
    end
    -- A height change on the last render can pull undecorated rows into view.
    for _, seg in ipairs(segs) do
        for row = seg[1], seg[2] - 1 do
            if not last.covered[row] then rows[#rows + 1] = { row, row + 1 } end
        end
    end
    if #rows == 0 then
        return
    end
    local ranges = {}
    for _, r in ipairs(rows) do
        r[1], r[2] = table_state.widen(buf, r[1], r[2])
    end
    table.sort(rows, function(a, b) return a[1] < b[1] end)
    for _, r in ipairs(rows) do
        local prev = ranges[#ranges]
        if prev and r[1] <= prev[2] then
            prev[2] = math.max(prev[2], r[2])
        else
            ranges[#ranges + 1] = { r[1], r[2] }
        end
    end

    local before = images_active and layout_sig(buf, ranges)
    html.refresh(buf, cursor_row - 1, segs)
    local rule_width = vim.api.nvim_win_get_width(win) - info.textoff
    for _, r in ipairs(ranges) do
        vim.api.nvim_buf_clear_namespace(buf, ns, r[1], r[2])
        deco.clear(buf, r[1], r[2])
        deco.render_range(buf, r[1], r[2], rule_width, cursor_row)
    end
    local width = text_width(win, info)
    for _, r in ipairs(ranges) do
        render_range(buf, r[1], r[2], width, cursor_row, images_active)
        for row = r[1], r[2] - 1 do last.covered[row] = true end
    end
    last.cursor = cursor_row
    win_settled[win] = true
    if images_active and layout_sig(buf, ranges) ~= before then
        require('nvim_config.rendermark.image').schedule_image_sync()
    end
end

local pending = {} -- win -> 'full' | 'cursor'
local function schedule_refresh(win, cursor_only)
    if not win or win == 0 then
        win = vim.api.nvim_get_current_win()
    end
    if pending[win] then
        if not cursor_only then pending[win] = 'full' end
        return
    end
    pending[win] = cursor_only and 'cursor' or 'full'
    -- Double-deferred to run after foreign decorators' own scheduled callbacks.
    vim.schedule(function()
        vim.schedule(function()
            local mode = pending[win]
            pending[win] = nil
            if mode == 'cursor' then
                refresh_cursor(win)
            else
                M.refresh(win)
            end
        end)
    end)
end

-- Typing on the cursor row changes nothing else on screen until it pauses.
local function schedule_typing_refresh(win)
    local gen = (typing[win] or 0) + 1
    typing[win] = gen
    vim.defer_fn(function()
        if typing[win] == gen then
            typing[win] = nil
            schedule_refresh(win)
        end
    end, TYPING_DEBOUNCE_MS)
end

-- Crossing a code fence row repaints synchronously; the deferred refresh would flicker.
local last_cursor_row = {}

local function looks_like_fence(buf, lnum)
    local line = vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1]
    return line ~= nil and line:match('^%s*[`~][`~][`~]') ~= nil
end

-- Only the two rows change: the fence bar yields to the source under the cursor.
local function repaint_deco_now(win, buf, rows)
    local info = vim.fn.getwininfo(win)[1]
    if not info then
        return
    end
    -- Same leftcol bail as M.refresh.
    local leftcol = vim.api.nvim_win_call(win, function()
        return vim.fn.winsaveview().leftcol
    end)
    if leftcol > 0 then
        return
    end
    local cursor_row = vim.w[win].read_mode_active and -1
        or vim.api.nvim_win_get_cursor(win)[1]
    local rule_width = vim.api.nvim_win_get_width(win) - info.textoff
    for _, row in ipairs(rows) do
        deco.clear(buf, row - 1, row)
        deco.render_range(buf, row - 1, row, rule_width, cursor_row)
    end
end

-- 'statuscolumn': signs + numbers (real lines only) + reading margin.
local function build_statuscolumn(pad)
    local num = "%{(&nu||&rnu) ? (v:virtnum!=0 ? '' : (v:relnum==0 ? (&nu ? v:lnum : v:relnum) : (&rnu ? v:relnum : v:lnum))) : ''}"
    return '%s%=' .. num .. string.rep(' ', pad)
end

function M.apply(win)
    win = win or 0
    local w = win == 0 and vim.api.nvim_get_current_win() or win
    local buf = vim.api.nvim_win_get_buf(w)

    if saved_state[w] == nil then
        saved_state[w] = {
            wrap = vim.wo[w].wrap,
            statuscolumn = vim.wo[w].statuscolumn,
            conceallevel = vim.wo[w].conceallevel,
            scrolloff = vim.wo[w].scrolloff,
        }
    end

    vim.b[buf].markdown_visual_wrap = true
    vim.wo[w].wrap = false
    vim.wo[w].linebreak = false
    vim.wo[w].breakindent = false
    -- A cursor row whose virt_lines outgrow the window can't keep a scrolloff
    -- margin; nvim then snaps topline back and C-e/C-y stall on tall images.
    vim.wo[w].scrolloff = 0
    if config.left_pad > 0 then
        vim.wo[w].statuscolumn = build_statuscolumn(config.left_pad)
    end
    if vim.wo[w].conceallevel < 2 then
        vim.wo[w].conceallevel = 2
    end
    if is_markdown_buffer(buf) then
        deco.visible_fences(buf, true)
    elseif not vim.treesitter.highlighter.active[buf] then
        pcall(vim.treesitter.start, buf)
    end

    schedule_refresh(w)
end

function M.disable(win)
    win = win or 0
    local w = win == 0 and vim.api.nvim_get_current_win() or win
    local buf = vim.api.nvim_win_get_buf(w)

    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    table_rows[buf] = nil
    rendered[w] = nil
    owner[buf] = nil
    deco.clear(buf)
    html.clear(buf)
    vim.b[buf].markdown_visual_wrap = false
    deco.visible_fences(buf, false)

    local saved = saved_state[w]
    if saved then
        vim.wo[w].wrap = saved.wrap
        vim.wo[w].statuscolumn = saved.statuscolumn
        vim.wo[w].conceallevel = saved.conceallevel
        vim.wo[w].scrolloff = saved.scrolloff
        saved_state[w] = nil
    end
    if require('nvim_config.rendermark.image').is_active() then
        require('nvim_config.rendermark.image').schedule_image_sync()
    end
end

function M.toggle()
    if vim.b.markdown_visual_wrap then
        M.disable(0)
    else
        M.apply(0)
    end
end

local function apply_current_window()
    if vim.g.markdown_visual_wrap_enabled == false then
        return
    end
    -- Skip floating previews (LSP hover etc.); nvim styles those itself.
    if vim.api.nvim_win_get_config(0).relative ~= '' then
        return
    end
    if is_markdown_buffer(0) then
        M.apply(0)
    elseif saved_state[vim.api.nvim_get_current_win()] then
        -- 'statuscolumn' is window-local; don't leak it to other buffers.
        M.disable(0)
    end
end

function M.setup(opts)
    config = vim.tbl_deep_extend('force', vim.deepcopy(defaults), opts or {})
    table_state.set_enabled(config.table)
    vim.g.markdown_visual_wrap_enabled = config.markdown

    group = vim.api.nvim_create_augroup('markdown_visual_wrap', { clear = true })
    vim.api.nvim_create_autocmd('User', {
        group = group,
        pattern = 'ReadModeChanged',
        callback = function(event)
            local data = event.data
            if data and vim.api.nvim_win_is_valid(data.win)
                and vim.api.nvim_win_get_buf(data.win) == data.buf then
                pcall(M.refresh, data.win)
            end
        end,
    })
    vim.api.nvim_create_autocmd('User', {
        group = group,
        pattern = 'MarkdownDetailsChanged',
        callback = function(event)
            local data = event.data
            if data and vim.api.nvim_win_is_valid(data.win)
                and vim.api.nvim_win_get_buf(data.win) == data.buf then
                M.refresh(data.win)
            end
        end,
    })
    vim.api.nvim_create_autocmd('BufWipeout', {
        group = group,
        callback = function(a) table_rows[a.buf] = nil end,
    })

    vim.api.nvim_create_user_command('MarkdownWrapToggle', function()
        if vim.g.markdown_visual_wrap_enabled == false then
            vim.g.markdown_visual_wrap_enabled = true
            if is_markdown_buffer(0) then
                M.apply(0)
            end
        else
            vim.g.markdown_visual_wrap_enabled = false
            M.disable(0)
        end
    end, {})

    if not config.markdown then
        return
    end

    vim.api.nvim_create_autocmd('FileType', {
        group = group,
        pattern = { 'markdown', 'markdown.mdx' },
        callback = apply_current_window,
    })

    vim.api.nvim_create_autocmd({ 'BufWinEnter', 'WinEnter' }, {
        group = group,
        callback = apply_current_window,
    })

    -- Table dimensions depend on image availability and the GUI's cell metrics.
    vim.api.nvim_create_autocmd('User', {
        group = group,
        pattern = { 'NeoppReady', 'NeoppMetrics' },
        callback = function()
            for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
                if buffer_enabled(vim.api.nvim_win_get_buf(win)) then schedule_refresh(win) end
            end
        end,
    })

    -- Folds fire no autocmd, so detect them here: botline changed, topline didn't.
    vim.api.nvim_set_decoration_provider(
        vim.api.nvim_create_namespace('markdown_visual_wrap_watch'), {
            on_win = function(_, win, buf, top, bot)
                if not buffer_enabled(buf) then
                    return
                end
                local seen = win_seen[win]
                win_seen[win] = { top, bot }
                -- Only record the first draw after a refresh, or they re-trigger.
                if win_settled[win] then
                    win_settled[win] = nil
                    return
                end
                if seen and seen[1] == top and seen[2] ~= bot then
                    schedule_refresh(win)
                end
            end,
        })

    vim.api.nvim_create_autocmd('WinClosed', {
        group = group,
        callback = function(a)
            local win = tonumber(a.match)
            win_seen[win], win_settled[win] = nil, nil
            last_cursor_row[win] = nil
            rendered[win], typing[win] = nil, nil
        end,
    })

    vim.api.nvim_create_autocmd({
        'WinScrolled', 'WinResized', 'VimResized',
        'TextChanged', 'TextChangedI',
        'CursorMoved', 'CursorMovedI',
        'InsertEnter', 'InsertLeave',
    }, {
        group = group,
        callback = function(a)
            local buf = vim.api.nvim_get_current_buf()
            if not buffer_enabled(buf) then
                return
            end
            local win = vim.api.nvim_get_current_win()
            if a.event == 'CursorMoved' or a.event == 'CursorMovedI' then
                local row = vim.api.nvim_win_get_cursor(win)[1]
                local prev = last_cursor_row[win]
                if html.skip_hidden(win, prev) then
                    row = vim.api.nvim_win_get_cursor(win)[1]
                end
                last_cursor_row[win] = row
                if prev ~= row
                    and (looks_like_fence(buf, row) or (prev and looks_like_fence(buf, prev))) then
                    repaint_deco_now(win, buf, { row, prev })
                end
                schedule_refresh(win, true)
            elseif a.event == 'TextChangedI' and rendered[win]
                and rendered[win].cursor == vim.api.nvim_win_get_cursor(win)[1] then
                schedule_typing_refresh(win)
            else
                schedule_refresh(win)
            end
        end,
    })
end

return M
