-- Browser-like soft-wrap for markdown: 'wrap' is off and continuation rows are
-- drawn as extmark virt_lines, which looks better than native wrap with
-- breakindent and concealed prefix icons.
--
-- The cursor can never enter a virtual line, so the cursor's own line is always
-- shown raw on one row; every other visible line is decorated as soft-wrapped.
--
-- Continuation rows and table cells re-create inline styling and marker conceal
-- from the treesitter highlight queries. Extmark decorations cannot be replayed
-- there, so deco hands back the block-quote bar explicitly (deco.prefix_chunks).

local M = {}
local wrap_text = require('rendermark.wrap.text')
local deco = require('rendermark.deco')
local html = require('rendermark.html')

local defaults = {
    markdown = true,
    left_pad = 2,        -- left reading margin (columns), via 'statuscolumn'
    right_pad = 2,       -- right reading margin (columns)
    max_width = nil,     -- cap the text column at this width; the window width is
                         -- used instead when it is narrower (nil = no cap)
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
-- Fold-change detection state per window (see the decoration provider in M.setup):
-- last topline/botline drawn, plus a flag to swallow the first draw after a refresh.
local win_seen, win_settled = {}, {}

local function dw(s)
    return wrap_text.dw(s)
end

local function hl_chunk(s)
    return config.hl and { s, config.hl } or { s }
end

local code_query -- lazily compiled treesitter query for markdown code blocks
local function get_code_query()
    if code_query == nil then
        local ok, q = pcall(vim.treesitter.query.parse, 'markdown',
            '[(fenced_code_block) (indented_code_block)] @cb')
        code_query = ok and q or false
    end
    return code_query or nil
end

local table_query -- lazily compiled treesitter query for markdown pipe tables
local function get_table_query()
    if table_query == nil then
        local ok, q = pcall(vim.treesitter.query.parse, 'markdown', '(pipe_table) @t')
        table_query = ok and q or false
    end
    return table_query or nil
end

-- Continuation indent (display columns), so wrapped rows hang under the text.
function M.compute_indent(text)
    return wrap_text.compute_indent(text, deco.metrics())
end

local function slice_concat(t, a, b)
    return wrap_text.slice_concat(t, a, b)
end

-- Flatten overlapping intervals { s, e, hl, conceal, priority, seq } of one line
-- into sorted, non-overlapping runs { s, e, hl = {group,...}, conceal,
-- conceal_anchor } (byte offsets, 0-based, end-exclusive). The hl stack is ordered
-- by (priority, seq) so later groups win; conceal_anchor marks the interval start
-- so a replacement char is emitted once even when the run is sliced.
-- Exported for unit tests.
function M.flatten_runs(intervals, line_len)
    return wrap_text.flatten_runs(intervals, line_len)
end

-- Prepend the base row highlight (config.hl); inline groups come later and win.
local function with_base(hl)
    return wrap_text.with_base(config.hl, hl)
end

-- Append a virt_text chunk, merging into the previous one when the hl stack
-- matches, to keep extmark payloads small.
local function push_chunk(out, text, hl)
    return wrap_text.push_chunk(out, text, hl)
end

-- Emit chunks for byte range [sb, eb) of `line` under the flattened runs:
-- conceal-"" slices are dropped, a replacement char is emitted once at its anchor.
-- runs == nil falls back to a single plain chunk.
local function slice_chunks(out, line, runs, sb, eb)
    return wrap_text.slice_chunks(out, line, runs, sb, eb, config.hl)
end

-- Inline highlight/conceal runs for rows [first, last), keyed by 0-based row, from
-- the highlight-query captures of every language tree (markdown + markdown_inline),
-- so virtual rows can re-create what the highlighter gives real lines.
-- extra_conceals (from collect_deco) is merged in, so inline[row] is the union.
local function collect_inline(parser, buf, first, last, extra_conceals)
    local row_lines = vim.api.nvim_buf_get_lines(buf, first, last, false)
    local function line_len(row)
        return #(row_lines[row - first + 1] or '')
    end
    local intervals = {} -- row -> interval list for M.flatten_runs
    local seq = 0
    parser:for_each_tree(function(tree, ltree)
        local lang = ltree:lang()
        local ok, q = pcall(vim.treesitter.query.get, lang, 'highlights')
        if not ok or not q then
            return
        end
        for id, node, metadata in q:iter_captures(tree:root(), buf, first, last) do
            local name = q.captures[id]
            if name ~= 'spell' and name ~= 'nospell' and name:sub(1, 1) ~= '_' then
                local m = metadata[id]
                local conceal = metadata.conceal
                if m and m.conceal ~= nil then
                    conceal = m.conceal
                end
                local hl = name ~= 'conceal' and ('@' .. name .. '.' .. lang) or nil
                if hl or conceal then
                    local r1, c1, r2, c2 = node:range()
                    local prio = tonumber(metadata.priority or (m and m.priority)) or 100
                    seq = seq + 1
                    for row = math.max(r1, first), math.min(r2, last - 1) do
                        local s = row == r1 and c1 or 0
                        local e = row == r2 and math.min(c2, line_len(row)) or line_len(row)
                        if e > s then
                            local list = intervals[row] or {}
                            intervals[row] = list
                            list[#list + 1] = {
                                s = s, e = e, hl = hl,
                                conceal = conceal, priority = prio, seq = seq,
                            }
                        end
                    end
                end
            end
        end
    end)
    if extra_conceals then
        for row, list in pairs(extra_conceals) do
            local dst = intervals[row] or {}
            intervals[row] = dst
            for _, iv in ipairs(list) do
                dst[#dst + 1] = iv
            end
        end
    end
    local marks = {}
    for row, list in pairs(intervals) do
        marks[row] = M.flatten_runs(list, line_len(row))
    end
    return marks
end

-- Display metrics from foreign-namespace extmarks (rendermark.deco) over rows
-- [first, last). Returns two row-keyed tables:
--   conceals[row] = conceal ranges AND plain hl_group highlights, merged into
--                   collect_inline so wrapped rows keep their width and styling
--   inserts[row]  = { b = byte_col, w = displaywidth } for inline virt_text icons,
--                   which ADD width at a byte position
-- own_ns/img_ns are skipped.
local function collect_deco(buf, first, last, own_ns, img_ns)
    local conceals, inserts = {}, {}
    local ok, marks = pcall(vim.api.nvim_buf_get_extmarks, buf, -1,
        { first, 0 }, { last, -1 }, { details = true })
    if not ok then
        return conceals, inserts
    end
    local seq = 0
    for _, m in ipairs(marks) do
        local row, col, d = m[2], m[3], m[4]
        local nsid = d.ns_id
        if nsid ~= own_ns and nsid ~= img_ns then
            if d.conceal ~= nil and d.end_col and d.end_col > col
                and (d.end_row == nil or d.end_row == row) then
                seq = seq + 1
                local list = conceals[row] or {}
                conceals[row] = list
                list[#list + 1] = {
                    s = col, e = d.end_col, hl = nil,
                    conceal = d.conceal,
                    priority = tonumber(d.priority) or 200,
                    seq = 1000000 + seq,
                }
            end
            if d.hl_group and d.end_col then
                seq = seq + 1
                local r2 = d.end_row or row
                for rr = math.max(row, first), math.min(r2, last - 1) do
                    local s = rr == row and col or 0
                    local e = rr == r2 and d.end_col or math.huge
                    if e > s then
                        local list = conceals[rr] or {}
                        conceals[rr] = list
                        list[#list + 1] = {
                            s = s, e = e, hl = d.hl_group,
                            conceal = nil,
                            priority = tonumber(d.priority) or 4096,
                            seq = 1000000 + seq,
                        }
                    end
                end
            end
            if d.virt_text and d.virt_text_pos == 'inline' then
                local w = 0
                for _, ch in ipairs(d.virt_text) do
                    w = w + dw(ch[1] or '')
                end
                if w > 0 then
                    local list = inserts[row] or {}
                    inserts[row] = list
                    list[#list + 1] = { b = col, w = w }
                end
            end
        end
    end
    return conceals, inserts
end

-- Core charwise break loop shared by wrap_line, wrap_cell and styled table cells.
-- items[i] = { w = display width, sp = breakable whitespace }. Returns one
-- inclusive index range per display row, trailing whitespace trimmed (e < s for an
-- all-space row). Breaks at spaces, else per item (CJK / long words).
local function wrap_indices(items, width1, widthN)
    return wrap_text.wrap_indices(items, width1, widthN)
end

local function char_items(chars)
    return wrap_text.char_items(chars)
end

-- Pure wrap computation. Returns:
--   first_end_byte : byte offset ending the first display row, i.e. where the real
--                    line is concealed (nil if it fits)
--   lines          : continuation rows (indented) for virt_lines
--   spans          : each continuation row's { start, end } byte range in `text`
function M.wrap_line(text, width1, widthN, indent, runs, inserts)
    return wrap_text.wrap_line(text, width1, widthN, indent, runs, inserts)
end

-- Split a table row into trimmed cells, dropping the outer pipes and unescaping
-- "\|". Each cell keeps its chars with source byte offsets --
-- { text = 'a|b', chars = { { c = 'a', b = 2 }, ... } } -- so the line's inline
-- highlights/conceals map onto the rendered cell. "\|" maps to the pipe's byte.
function M.split_cells_pos(line)
    local chars = vim.fn.split(line, '\\zs')
    local pos = {}
    local acc = 0
    for i, c in ipairs(chars) do
        pos[i] = acc
        acc = acc + #c
    end

    -- trim surrounding whitespace, as index bounds
    local a, b = 1, #chars
    while a <= b and chars[a]:match('%s') do a = a + 1 end
    while b >= a and chars[b]:match('%s') do b = b - 1 end
    local lead = a <= b and chars[a] == '|'
    local trail = b >= a and chars[b] == '|'

    local cells, cur = {}, {}
    local i = a
    while i <= b do
        local c = chars[i]
        if c == '\\' and i + 1 <= b and chars[i + 1] == '|' then
            cur[#cur + 1] = { c = '|', b = pos[i + 1] }
            i = i + 2
        elseif c == '|' then
            cells[#cells + 1] = cur
            cur = {}
            i = i + 1
        else
            cur[#cur + 1] = { c = c, b = pos[i] }
            i = i + 1
        end
    end
    cells[#cells + 1] = cur
    if trail then table.remove(cells) end
    if lead then table.remove(cells, 1) end

    local out = {}
    for _, cell in ipairs(cells) do
        local s, e = 1, #cell
        while s <= e and cell[s].c:match('%s') do s = s + 1 end
        while e >= s and cell[e].c:match('%s') do e = e - 1 end
        local chs, txt = {}, {}
        for k = s, e do
            chs[#chs + 1] = cell[k]
            txt[#txt + 1] = cell[k].c
        end
        out[#out + 1] = { text = table.concat(txt), chars = chs }
    end
    return out
end

-- Plain-string variant of split_cells_pos.
function M.split_cells(line)
    local out = {}
    for i, cell in ipairs(M.split_cells_pos(line)) do
        out[i] = cell.text
    end
    return out
end

-- Column alignments from the delimiter row (":---" left, "---:" right, ":--:" center).
function M.parse_aligns(delim_line)
    local aligns = {}
    for i, c in ipairs(M.split_cells(delim_line)) do
        local l = c:sub(1, 1) == ':'
        local r = c:sub(-1) == ':'
        if l and r then
            aligns[i] = 'center'
        elseif r then
            aligns[i] = 'right'
        else
            aligns[i] = 'left'
        end
    end
    return aligns
end

-- Wrap a cell to `width` columns; hard-breaks long words / CJK, always >= 1 row.
function M.wrap_cell(text, width)
    if width < 1 then width = 1 end
    local chars = vim.fn.split(text, '\\zs')
    if #chars == 0 then
        return { '' }
    end
    local lines = {}
    for _, r in ipairs(wrap_indices(char_items(chars), width, width)) do
        lines[#lines + 1] = slice_concat(chars, r[1], r[2])
    end
    return lines
end

-- Column widths for a table (`rows` = header + data cell-arrays, no delimiter).
-- Cap each column at `cap`, hand leftover budget back to capped columns up to their
-- natural width, and shrink proportionally down to `min` if even that overflows.
function M.compute_table_layout(rows, avail, cap, min)
    local N = 0
    for _, r in ipairs(rows) do
        if #r > N then N = #r end
    end
    if N == 0 then
        return {}
    end

    local natural, capped, sum_capped = {}, {}, 0
    for c = 1, N do
        local w = 1
        for _, r in ipairs(rows) do
            local cw = dw(r[c] or '')
            if cw > w then w = cw end
        end
        natural[c] = w
        capped[c] = math.min(w, cap)
        sum_capped = sum_capped + capped[c]
    end

    local budget = avail - (3 * N + 1) -- 2 padding/col + (N+1) vertical bars
    if budget < N * min then
        budget = N * min
    end

    local widths = {}
    for c = 1, N do
        widths[c] = capped[c]
    end

    if sum_capped <= budget then
        local leftover = budget - sum_capped
        local deficit, total_deficit = {}, 0
        for c = 1, N do
            deficit[c] = natural[c] - capped[c]
            total_deficit = total_deficit + deficit[c]
        end
        local give = math.min(leftover, total_deficit)
        if give > 0 then
            local alloc, frac, used = {}, {}, 0
            for c = 1, N do
                local exact = give * deficit[c] / total_deficit
                alloc[c] = math.floor(exact)
                frac[c] = exact - alloc[c]
                used = used + alloc[c]
            end
            local order = {}
            for c = 1, N do order[c] = c end
            table.sort(order, function(a, b) return frac[a] > frac[b] end)
            for k = 1, give - used do
                alloc[order[k]] = alloc[order[k]] + 1
            end
            for c = 1, N do
                widths[c] = capped[c] + math.min(alloc[c], deficit[c])
            end
        end
    else
        local function total()
            local s = 0
            for c = 1, N do s = s + widths[c] end
            return s
        end
        while total() > budget do
            local idx, mx = nil, min
            for c = 1, N do
                if widths[c] > mx then mx, idx = widths[c], c end
            end
            if not idx then break end
            widths[idx] = widths[idx] - 1
        end
    end
    return widths
end

-- Map a cell's source chars through the line's inline runs into display items
-- { c, w, hl, sp }, dropping conceal-"" chars. Layout, wrapping and padding use
-- these, so the grid stays aligned however many markers were concealed.
local function styled_cell(chars, runs, breaks)
    local items = {}
    local function add(c, hl)
        items[#items + 1] = { c = c, w = dw(c), hl = hl, sp = c:match('%s') ~= nil }
    end
    if not runs then
        for _, ch in ipairs(chars) do
            if breaks and breaks[ch.b] then
                items[#items + 1] = { c = '', w = 0, br = true }
            end
            add(ch.c, nil)
        end
        return items
    end
    local ri = 1
    local emitted = {} -- conceal anchors already replaced
    for _, ch in ipairs(chars) do
        if breaks and breaks[ch.b] then
            items[#items + 1] = { c = '', w = 0, br = true }
        end
        while ri <= #runs and runs[ri].e <= ch.b do
            ri = ri + 1
        end
        local r = runs[ri]
        if not (r and ch.b >= r.s) then
            add(ch.c, nil)
        elseif r.conceal == '' then
            -- concealed
        elseif r.conceal then
            if not emitted[r.conceal_anchor] then
                emitted[r.conceal_anchor] = true
                add(r.conceal, r.hl)
            end
        else
            add(ch.c, r.hl)
        end
    end
    return items
end

-- Wrap styled display items to `width` columns; rows of item lists.
local function wrap_items(items, width)
    if width < 1 then width = 1 end
    if #items == 0 then
        return { {} }
    end
    local rows = {}
    local segment = {}
    local function append_segment()
        if #segment == 0 then
            rows[#rows + 1] = {}
        else
            for _, r in ipairs(wrap_indices(segment, width, width)) do
                local row = {}
                for k = r[1], r[2] do
                    row[#row + 1] = segment[k]
                end
                rows[#rows + 1] = row
            end
        end
    end
    for _, item in ipairs(items) do
        if item.br then
            append_segment()
            segment = {}
        else
            segment[#segment + 1] = item
        end
    end
    append_segment()
    return rows
end

local function table_border(left, mid, right, widths)
    local parts = {}
    for c = 1, #widths do
        parts[c] = string.rep('─', widths[c] + 2)
    end
    return left .. table.concat(parts, mid) .. right
end

-- Render a pipe table (rows t_start..t_end, 0-based) as a boxed grid with wrapped
-- cells: each source row is concealed and overlaid, the extra grid lines (borders,
-- separators, continuations) are virt_lines. The cursor's row stays raw.
-- `inline` (collect_inline) styles the cell content like real lines.
local function render_table(buf, t_start, t_end, avail, cursor_lnum, inline)
    local lines = vim.api.nvim_buf_get_lines(buf, t_start, t_end + 1, false)
    if #lines < 2 then
        return
    end

    local aligns = M.parse_aligns(lines[2])

    local function styled_row(lnum0)
        local row = {}
        for c, cell in ipairs(M.split_cells_pos(lines[lnum0 - t_start + 1])) do
            row[c] = styled_cell(cell.chars, inline[lnum0], html.table_breaks(buf, lnum0))
        end
        return row
    end
    local header = styled_row(t_start)
    local data = {}
    for lnum0 = t_start + 2, t_end do
        data[#data + 1] = styled_row(lnum0)
    end

    -- Column layout from the conceal-stripped text.
    local function disp_rows(cells)
        local rows = { {} }
        for c, items in ipairs(cells) do
            local part = 1
            for _, it in ipairs(items) do
                if it.br then
                    part = part + 1
                    rows[part] = rows[part] or {}
                else
                    rows[part][c] = (rows[part][c] or '') .. it.c
                end
            end
        end
        for _, row in ipairs(rows) do
            for c = 1, #cells do row[c] = row[c] or '' end
        end
        return rows
    end
    local all_rows = disp_rows(header)
    for _, d in ipairs(data) do
        vim.list_extend(all_rows, disp_rows(d))
    end
    local widths = M.compute_table_layout(all_rows, avail,
        config.table_max_col_width, config.table_min_col_width)
    local N = #widths
    if N == 0 then
        return
    end
    for c = 1, N do
        aligns[c] = aligns[c] or 'left'
    end

    local top = table_border('┌', '┬', '┐', widths)
    local sep = table_border('├', '┼', '┤', widths)
    local bot = table_border('└', '┴', '┘', widths)

    -- Grid rows for one source row, as virt_text chunk lists.
    local function row_block(cells)
        local cols, height = {}, 1
        for c = 1, N do
            cols[c] = wrap_items(cells[c] or {}, widths[c])
            if #cols[c] > height then height = #cols[c] end
        end
        local out = {}
        for k = 1, height do
            local chunks = {}
            push_chunk(chunks, '│', config.hl)
            for c = 1, N do
                local row = cols[c][k] or {}
                local used = 0
                for _, it in ipairs(row) do
                    used = used + it.w
                end
                local extra = math.max(widths[c] - used, 0)
                local lpad, rpad = 0, extra
                if aligns[c] == 'right' then
                    lpad, rpad = extra, 0
                elseif aligns[c] == 'center' then
                    lpad = math.floor(extra / 2)
                    rpad = extra - lpad
                end
                push_chunk(chunks, string.rep(' ', lpad + 1), config.hl)
                for _, it in ipairs(row) do
                    push_chunk(chunks, it.c, with_base(it.hl))
                end
                push_chunk(chunks, string.rep(' ', rpad + 1), config.hl)
                push_chunk(chunks, '│', config.hl)
            end
            out[k] = chunks
        end
        return out
    end

    local function overlay(lnum0, chunks)
        local raw = lines[lnum0 - t_start + 1] or ''
        if #raw > 0 then
            vim.api.nvim_buf_set_extmark(buf, ns, lnum0, 0, { end_col = #raw, conceal = '' })
        end
        vim.api.nvim_buf_set_extmark(buf, ns, lnum0, 0,
            { virt_text = chunks, virt_text_pos = 'overlay' })
    end
    local function vlines(lnum0, rows, above)
        if #rows == 0 then
            return
        end
        vim.api.nvim_buf_set_extmark(buf, ns, lnum0, 0,
            { virt_lines = rows, virt_lines_above = above or nil })
    end

    -- Header: top border above, content overlaid, continuations below.
    vlines(t_start, { { hl_chunk(top) } }, true)
    if t_start + 1 ~= cursor_lnum then
        local block = row_block(header)
        overlay(t_start, block[1])
        local cont = {}
        for k = 2, #block do
            cont[#cont + 1] = block[k]
        end
        vlines(t_start, cont, false)
    end

    -- Delimiter row hosts the separator, or the bottom border if there is no data.
    local d_lnum = t_start + 1
    if d_lnum + 1 ~= cursor_lnum then
        overlay(d_lnum, { hl_chunk(#data > 0 and sep or bot) })
    end

    -- Data rows, each followed by a separator (bottom border for the last).
    for i, cells in ipairs(data) do
        local lnum0 = t_start + 1 + i
        local below = (i == #data) and bot or sep
        if lnum0 + 1 ~= cursor_lnum then
            local block = row_block(cells)
            overlay(lnum0, block[1])
            local rest = {}
            for k = 2, #block do
                rest[#rest + 1] = block[k]
            end
            rest[#rest + 1] = { hl_chunk(below) }
            vlines(lnum0, rest, false)
        else
            vlines(lnum0, { { hl_chunk(below) } }, false)
        end
    end
end

local function is_markdown_buffer(buf)
    local ft = vim.bo[buf or 0].filetype
    return ft == 'markdown' or ft == 'markdown.mdx'
end

local function buffer_enabled(buf)
    return vim.g.markdown_visual_wrap_enabled ~= false and vim.b[buf].markdown_visual_wrap == true
end

-- Drawn line ranges of topline..botline with closed folds cut out, as 0-indexed
-- half-open { first, last } pairs. A closed fold's first line is dropped too: it
-- draws 'foldtext', not buffer text. 'foldclosed' is current-window only, hence
-- the nvim_win_call (refresh also runs for non-current windows).
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

-- Decorate one visible range [first, last). Everything is keyed by row, so ranges
-- are independent. A table straddling a closed fold renders only the part in this
-- range; the folded part isn't drawn anyway.
local function render_range(buf, first, last, width, cursor_row, images_active)
    -- Find code blocks (exempt from wrapping) and pipe tables via treesitter. The
    -- parse is full so a partly-visible table keeps its complete node range;
    -- captures stay limited to the visible range. Parser/tree are cached.
    local in_code, in_table, tables = {}, {}, {}
    local inline = {} -- row -> flattened inline highlight/conceal runs
    -- Foreign extmark metrics: conceals merge into inline below, icon widths feed
    -- the wrap point so the break matches the displayed width.
    local img_ns = vim.api.nvim_create_namespace('rendermark_neopp_images')
    local ex_conceals, inserts = collect_deco(buf, first, last, ns, img_ns)
    local ts_ok, parser = pcall(vim.treesitter.get_parser, buf, 'markdown')
    if ts_ok and parser then
        -- Parses markdown_inline injections in the range; the markdown tree stays full.
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
            local tq = config.table and get_table_query() or nil
            if tq then
                for _, node in tq:iter_captures(root, buf, first, last) do
                    local r1, _, r2, c2 = node:range()
                    if c2 == 0 then r2 = r2 - 1 end
                    -- The grammar absorbs trailing pipe-less prose into the table node;
                    -- trim to the contiguous run of '|' rows so it stays wrappable.
                    local rows = vim.api.nvim_buf_get_lines(buf, r1, r2 + 1, false)
                    local tend = r1 + 1 -- header + delimiter
                    for k = 3, #rows do
                        if rows[k]:find('|', 1, true) then
                            tend = r1 + k - 1
                        else
                            break
                        end
                    end
                    tables[#tables + 1] = { r1, tend }
                    for l = r1, tend do
                        in_table[l] = true
                    end
                end
            end
            inline = collect_inline(parser, buf, first, last, ex_conceals)
        end
    end

    for _, t in ipairs(tables) do
        render_table(buf, t[1], t[2], width, cursor_row, inline)
    end

    -- rendermark.image lays out image-link lines itself; wrapping them here too
    -- would stack continuation rows below the image.
    local image = images_active and require('rendermark.image') or nil

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
                    -- A block quote repeats its bar so the rule isn't cut off at the
                    -- wrap. Extmark decorations can't be replayed in virt_lines, so
                    -- deco hands us the chunks.
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

-- deco owns its own namespace, so repainting it is independent of the wrap pass.
local function paint_deco(buf, segs, rule_width, cursor_row)
    deco.clear(buf)
    for _, seg in ipairs(segs) do
        deco.render_range(buf, seg[1], seg[2], rule_width, cursor_row)
    end
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

    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    deco.clear(buf)

    -- leftcol is window-global and slides every line's real text, which we can't
    -- compensate per line. Bail with the namespace cleared so everything scrolls
    -- uniformly; decorations return once leftcol is back to 0.
    local leftcol = vim.api.nvim_win_call(win, function()
        return vim.fn.winsaveview().leftcol
    end)
    if leftcol > 0 then
        html.clear(buf)
        return
    end

    local info = vim.fn.getwininfo(win)[1]
    local width = vim.api.nvim_win_get_width(win) - info.textoff - config.right_pad
    -- max_width is only a cap; a narrower window still wraps at its own width.
    if config.max_width and config.max_width > 0 then
        width = math.min(width, config.max_width)
    end
    if width < config.min_text_width then
        return
    end

    -- read_mode.lua (optional) sets read_mode_active to wrap every visible line,
    -- cursor line included: the -1 sentinel matches no real line, disabling the
    -- cursor-line exception here and in render_table.
    -- The namespace is buffer-scoped, so with the buffer in both a READ and a
    -- Normal window, the last refresh wins -- accepted.
    local cursor_row = vim.w[win].read_mode_active and -1
        or vim.api.nvim_win_get_cursor(win)[1]
    html.refresh(buf, cursor_row - 1)
    local images_active = require('rendermark.image').is_active()
    local segs = visible_segments(win, info.topline, info.botline)
    -- Decorations first for every segment: render_range's collect_deco snapshots
    -- foreign extmarks for each line's real width, so they must already be placed.
    -- The rule spans the full window width, not the capped text column.
    local rule_width = vim.api.nvim_win_get_width(win) - info.textoff
    paint_deco(buf, segs, rule_width, cursor_row)
    for _, seg in ipairs(segs) do
        render_range(buf, seg[1], seg[2], width, cursor_row, images_active)
    end
    win_settled[win] = true
end

local pending = {}
local function schedule_refresh(win)
    if not win or win == 0 then
        win = vim.api.nvim_get_current_win()
    end
    if pending[win] then
        return
    end
    pending[win] = true
    -- Double-deferred: a single vim.schedule races a foreign decorator's own
    -- schedule off the same event (autocmd registration order decides), and losing
    -- means collect_deco snapshots before the foreign highlights exist -- visible
    -- on jumps into never-rendered lines (gg/G). One more nesting level guarantees
    -- we run after every single-deferred callback already queued.
    vim.schedule(function()
        vim.schedule(function()
            pending[win] = nil
            M.refresh(win)
        end)
    end)
end

-- A code fence is the one decoration whose shape depends on the cursor: with
-- 'concealcursor' empty the fence row reappears on the cursor line and deco must
-- move its bar there (place_bar in render_code). The deferred refresh above lands a
-- frame late, which is exactly the flicker, so crossing a fence row repaints
-- synchronously inside the event; the deferred pass then changes nothing.
local last_cursor_row = {}

local function looks_like_fence(buf, lnum)
    local line = vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1]
    return line ~= nil and line:match('^%s*[`~][`~][`~]') ~= nil
end

local function repaint_deco_now(win, buf)
    local info = vim.fn.getwininfo(win)[1]
    if not info then
        return
    end
    -- Same bail as M.refresh: decorations stay off while scrolled horizontally.
    local leftcol = vim.api.nvim_win_call(win, function()
        return vim.fn.winsaveview().leftcol
    end)
    if leftcol > 0 then
        return
    end
    local cursor_row = vim.w[win].read_mode_active and -1
        or vim.api.nvim_win_get_cursor(win)[1]
    paint_deco(buf, visible_segments(win, info.topline, info.botline),
        vim.api.nvim_win_get_width(win) - info.textoff, cursor_row)
end

-- 'statuscolumn' replaces the number column entirely, so rebuild signs +
-- number/relativenumber and append the reading margin. Numbers only on real lines.
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
        }
    end

    vim.b[buf].markdown_visual_wrap = true
    vim.wo[w].wrap = false
    vim.wo[w].linebreak = false
    vim.wo[w].breakindent = false
    if config.left_pad > 0 then
        vim.wo[w].statuscolumn = build_statuscolumn(config.left_pad)
    end
    if vim.wo[w].conceallevel < 2 then
        vim.wo[w].conceallevel = 2
    end
    -- Decorated rows replay the treesitter highlight queries; real lines need the
    -- highlighter itself for the same styling. Nothing else attaches it for
    -- markdown in this setup.
    if not vim.treesitter.highlighter.active[buf] then
        pcall(vim.treesitter.start, buf)
    end

    schedule_refresh(w)
end

function M.disable(win)
    win = win or 0
    local w = win == 0 and vim.api.nvim_get_current_win() or win
    local buf = vim.api.nvim_win_get_buf(w)

    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    deco.clear(buf)
    html.clear(buf)
    vim.b[buf].markdown_visual_wrap = false

    local saved = saved_state[w]
    if saved then
        vim.wo[w].wrap = saved.wrap
        vim.wo[w].statuscolumn = saved.statuscolumn
        vim.wo[w].conceallevel = saved.conceallevel
        saved_state[w] = nil
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
    -- Skip floating preview windows (LSP hover, signature help): their fixed narrow
    -- width plus our statuscolumn wraps the separator rules and truncates lines, and
    -- nvim's own markdown stylize already handles them.
    if vim.api.nvim_win_get_config(0).relative ~= '' then
        return
    end
    if is_markdown_buffer(0) then
        M.apply(0)
    elseif saved_state[vim.api.nvim_get_current_win()] then
        -- 'statuscolumn' is window-local and would leak to non-markdown buffers.
        M.disable(0)
    end
end

function M.setup(opts)
    config = vim.tbl_deep_extend('force', vim.deepcopy(defaults), opts or {})
    vim.g.markdown_visual_wrap_enabled = config.markdown

    group = vim.api.nvim_create_augroup('markdown_visual_wrap', { clear = true })

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

    -- Opening/closing a fold fires no autocmd, yet it changes which lines are
    -- drawn. A decoration provider is the one hook running on every redraw, so use
    -- it purely as a change detector (no extmarks here).
    -- Only fold changes are acted on: the drawn range grew or shrank while topline
    -- stayed put. Scrolling and resizing move topline and are covered by the events
    -- below, so handling them here too would just double the refreshes.
    vim.api.nvim_set_decoration_provider(
        vim.api.nvim_create_namespace('markdown_visual_wrap_watch'), {
            on_win = function(_, win, buf, top, bot)
                if not buffer_enabled(buf) then
                    return
                end
                local seen = win_seen[win]
                win_seen[win] = { top, bot }
                -- A refresh's own virt_lines move botline, so the first draw after
                -- one is only recorded -- otherwise the two re-trigger each other.
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
            if a.event == 'CursorMoved' or a.event == 'CursorMovedI' then
                local win = vim.api.nvim_get_current_win()
                local row = vim.api.nvim_win_get_cursor(win)[1]
                local prev = last_cursor_row[win]
                if html.skip_hidden(win, prev) then
                    row = vim.api.nvim_win_get_cursor(win)[1]
                end
                last_cursor_row[win] = row
                if prev ~= row
                    and (looks_like_fence(buf, row) or (prev and looks_like_fence(buf, prev))) then
                    repaint_deco_now(win, buf)
                end
            end
            schedule_refresh(0)
        end,
    })
end

return M
