-- Browser-like soft-wrap for markdown using virtual lines.
--
-- Instead of Neovim's native `wrap` (which looks unnatural with breakindent and
-- concealed prefix icons), this renders long lines with `wrap = false` and draws
-- the wrapped continuation rows as extmark `virt_lines`, applied only to markdown
-- buffers.
--
-- Hard constraint: the cursor can never enter a virtual line, and with
-- `wrap = false` the cursor's own line scrolls horizontally to follow it. So the
-- active (cursor) line is always shown raw on a single row; every other visible
-- line is decorated as soft-wrapped. See docs/known limitations in the plan.
--
-- Continuation rows and table cells re-create inline styling (bold, italic,
-- `code`, links, ...) from the treesitter highlight queries, including their
-- conceal of syntax markers, so they match real buffer lines rendered at
-- conceallevel=2. Known limitation: render-markdown decorations added via
-- extmarks (link icons, checkbox glyphs) cannot be reproduced there, so e.g.
-- [text](url) shows as plain "text" without the icon inside virtual rows.

local M = {}

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

-- List marker, including an optional task checkbox: "- ", "* ", "+ ", "1.", "12)",
-- "  - nested", "- [ ] task", etc.
local list_pat = [[^\s*\%(\d\+[.)]\|[-*+]\)\s\+\%(\[.\]\s\+\)\?]]

local function dw(s)
    return vim.fn.strdisplaywidth(s)
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

-- Continuation indent (display columns) for a logical line, so wrapped rows hang
-- under the line's text the way a browser renders it.
function M.compute_indent(text)
    local marker = vim.fn.matchstr(text, list_pat)
    if marker ~= '' then
        return dw(marker)
    end
    local heading = text:match('^%s*#+%s+')
    if heading then
        return dw(heading)
    end
    local quote = text:match('^%s*>[%s>]*')
    if quote then
        return dw(quote)
    end
    return dw(text:match('^%s*') or '')
end

local function slice_concat(t, a, b)
    local r = {}
    for k = a, b do
        r[#r + 1] = t[k]
    end
    return table.concat(r)
end

-- Flatten possibly-overlapping highlight/conceal intervals of one line into
-- sorted, non-overlapping runs. Each interval is
--   { s, e, hl = group|nil, conceal = nil|string, priority, seq }
-- (byte offsets, 0-based, end-exclusive). Each resulting run is
--   { s, e, hl = {group,...}|nil, conceal = nil|string, conceal_anchor = byte }
-- The hl stack is ordered by (priority, seq) so later groups win attribute
-- conflicts; conceal_anchor marks the interval start so a non-empty replacement
-- char is emitted exactly once even when the run is sliced.
-- Exported only so it can be unit-tested without treesitter.
function M.flatten_runs(intervals, line_len)
    if not intervals or #intervals == 0 then
        return nil
    end
    local points, seen = {}, {}
    local function add_point(p)
        p = math.max(0, math.min(p, line_len))
        if not seen[p] then
            seen[p] = true
            points[#points + 1] = p
        end
    end
    for _, iv in ipairs(intervals) do
        add_point(iv.s)
        add_point(iv.e)
    end
    table.sort(points)

    local runs = {}
    for k = 1, #points - 1 do
        local s, e = points[k], points[k + 1]
        local active = {}
        for _, iv in ipairs(intervals) do
            if iv.s < e and iv.e > s then
                active[#active + 1] = iv
            end
        end
        if #active > 0 then
            table.sort(active, function(a, b)
                if (a.priority or 100) ~= (b.priority or 100) then
                    return (a.priority or 100) < (b.priority or 100)
                end
                return (a.seq or 0) < (b.seq or 0)
            end)
            local hl, conceal, anchor = {}, nil, nil
            for _, iv in ipairs(active) do
                if iv.hl then
                    hl[#hl + 1] = iv.hl
                end
                if iv.conceal ~= nil then
                    conceal, anchor = iv.conceal, iv.s
                end
            end
            runs[#runs + 1] = {
                s = s,
                e = e,
                hl = #hl > 0 and hl or nil,
                conceal = conceal,
                conceal_anchor = anchor,
            }
        end
    end
    return runs
end

-- Prepend the base continuation-row highlight (config.hl) to a run's hl stack;
-- inline groups come later, so they win attribute conflicts over the base.
local function with_base(hl)
    if not config.hl then
        return hl
    end
    local stack = { config.hl }
    if hl then
        if type(hl) == 'table' then
            vim.list_extend(stack, hl)
        else
            stack[#stack + 1] = hl
        end
    end
    return stack
end

-- Append a virt_text chunk, merging into the previous chunk when the hl stack is
-- identical (keeps extmark payloads small; refresh runs on CursorMoved).
local function push_chunk(out, text, hl)
    if text == '' then
        return
    end
    local prev = out[#out]
    if prev and vim.deep_equal(prev[2], hl) then
        prev[1] = prev[1] .. text
    else
        out[#out + 1] = hl ~= nil and { text, hl } or { text }
    end
end

-- Emit virt_text chunks for the raw byte range [sb, eb) of `line`, applying the
-- flattened runs: styled slices keep their hl stacks, conceal-"" slices are
-- dropped, and a non-empty conceal replacement is emitted once at its anchor.
-- runs == nil falls back to a single plain chunk.
local function slice_chunks(out, line, runs, sb, eb)
    if not runs then
        push_chunk(out, line:sub(sb + 1, eb), with_base(nil))
        return
    end
    local pos = sb
    for _, r in ipairs(runs) do
        if pos >= eb then
            break
        end
        if r.e > pos and r.s < eb then
            if r.s > pos then -- uncovered gap before this run
                push_chunk(out, line:sub(pos + 1, math.min(r.s, eb)), with_base(nil))
                pos = math.min(r.s, eb)
            end
            local s, e = math.max(r.s, pos), math.min(r.e, eb)
            if r.conceal == '' then
                -- concealed: dropped
            elseif r.conceal then
                if r.conceal_anchor >= s and r.conceal_anchor < e then
                    push_chunk(out, r.conceal, with_base(r.hl))
                end
            else
                push_chunk(out, line:sub(s + 1, e), with_base(r.hl))
            end
            pos = e
        end
    end
    if pos < eb then
        push_chunk(out, line:sub(pos + 1, eb), with_base(nil))
    end
end

-- Inline treesitter highlight/conceal runs for rows [first, last), keyed by row
-- (0-based). Walks every language tree (markdown + injected markdown_inline) and
-- collects highlight-query captures, so virtual continuation rows and table cells
-- can re-create the styling that real buffer lines get from the highlighter.
local function collect_inline(parser, buf, first, last)
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
    local marks = {}
    for row, list in pairs(intervals) do
        marks[row] = M.flatten_runs(list, line_len(row))
    end
    return marks
end

-- Core charwise break loop shared by wrap_line, wrap_cell and styled table cells.
-- items[i] = { w = display width, sp = true for breakable whitespace }.
-- Returns inclusive index ranges { {s, e}, ... }, one per display row, with
-- trailing whitespace trimmed from each row (e < s for an all-space row).
-- Breaks at spaces when possible, otherwise per item (handles CJK / long words).
local function wrap_indices(items, width1, widthN)
    local ranges = {}
    local line_start = 1   -- item index where the current display row starts
    local cur_w = 0
    local last_space = nil -- index of the last space seen on the current row
    local budget = width1

    local function push(stop_exclusive)
        local e = stop_exclusive - 1
        while e >= line_start and items[e].sp do
            e = e - 1
        end
        ranges[#ranges + 1] = { line_start, e }
    end

    local i = 1
    while i <= #items do
        local it = items[i]
        -- A space is a break opportunity: the content before it already fits, so
        -- record it before the overflow check (handles a space landing exactly at
        -- the budget boundary).
        if it.sp then
            last_space = i
        end
        if cur_w + it.w > budget and i > line_start then
            local stop, next_start
            if last_space and last_space >= line_start then
                stop = last_space        -- end row before the space (space dropped)
                next_start = last_space + 1
                while next_start <= #items and items[next_start].sp do
                    next_start = next_start + 1
                end
            else
                stop = i                 -- hard break (CJK / over-long word)
                next_start = i
            end
            push(stop)
            budget = widthN
            line_start = next_start
            last_space = nil
            cur_w = 0
            i = next_start
        else
            cur_w = cur_w + it.w
            i = i + 1
        end
    end

    -- line_start passes the end when only trailing spaces remained after the
    -- last break; don't emit an empty ghost row for them.
    if line_start <= #items then
        push(#items + 1)
    end
    return ranges
end

local function char_items(chars)
    local items = {}
    for i, c in ipairs(chars) do
        items[i] = { w = dw(c), sp = c:match('%s') ~= nil }
    end
    return items
end

-- Pure wrap computation. Given a line and the available widths, returns:
--   first_end_byte : 0-based byte offset where the first display row ends, i.e.
--                    where the real line should be concealed (nil if it fits).
--   lines          : continuation rows (strings, already indented) for virt_lines.
--   spans          : per continuation row, its { start, end } raw byte range in
--                    `text` (0-based, end-exclusive, after trailing-space trim).
function M.wrap_line(text, width1, widthN, indent)
    local chars = vim.fn.split(text, '\\zs')
    if #chars == 0 then
        return { first_end_byte = nil, lines = {}, spans = {} }
    end

    -- byte offset (0-based) of the start of each char; byte_at[#chars+1] = #text
    local byte_at = {}
    local acc = 0
    for i, c in ipairs(chars) do
        byte_at[i] = acc
        acc = acc + #c
    end
    byte_at[#chars + 1] = acc

    local ranges = wrap_indices(char_items(chars), width1, widthN)
    if #ranges < 2 then
        return { first_end_byte = nil, lines = {}, spans = {} }
    end

    local indent_str = string.rep(' ', indent)
    local lines, spans = {}, {}
    for k = 2, #ranges do
        local s, e = ranges[k][1], ranges[k][2]
        lines[#lines + 1] = indent_str .. slice_concat(chars, s, e)
        spans[#spans + 1] = { byte_at[s], byte_at[e + 1] }
    end
    return { first_end_byte = byte_at[ranges[1][2] + 1], lines = lines, spans = spans }
end

-- Split a table row into trimmed cells, dropping the outer pipes and unescaping
-- "\|" so an escaped pipe stays inside its cell. Each cell carries its chars with
-- their 0-based source byte offsets, so inline highlights/conceals (byte ranges on
-- the raw line) can be mapped onto the rendered cell:
--   { text = 'a|b', chars = { { c = 'a', b = 2 }, ... } }
-- An unescaped "\|" maps to the pipe's byte (the backslash is the concealed part).
function M.split_cells_pos(line)
    local chars = vim.fn.split(line, '\\zs')
    local pos = {}
    local acc = 0
    for i, c in ipairs(chars) do
        pos[i] = acc
        acc = acc + #c
    end

    -- surrounding whitespace (vim.trim equivalent, kept as index bounds)
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

-- Wrap one cell's text to `width` display columns, returning the display rows.
-- Breaks at spaces, hard-breaks long words / CJK. Always returns at least one row.
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

-- Column widths for a table. `rows` is a list of cell-arrays (header + data, not
-- the delimiter). "Cap then distribute": each column is capped at `cap`; leftover
-- budget goes to capped columns up to their natural width; if even the capped
-- widths overflow, columns shrink proportionally down to `min`.
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

-- Map one cell's source chars (from split_cells_pos) through the line's inline
-- runs: returns display items { c, w, hl, sp } with conceal-"" chars dropped and
-- a non-empty conceal replacement emitted once at its anchor. Layout, wrapping
-- and padding all use these display items, so the grid stays aligned regardless
-- of how many marker chars were concealed.
local function styled_cell(chars, runs)
    local items = {}
    local function add(c, hl)
        items[#items + 1] = { c = c, w = dw(c), hl = hl, sp = c:match('%s') ~= nil }
    end
    if not runs then
        for _, ch in ipairs(chars) do
            add(ch.c, nil)
        end
        return items
    end
    local ri = 1
    local emitted = {} -- conceal anchors already replaced
    for _, ch in ipairs(chars) do
        while ri <= #runs and runs[ri].e <= ch.b do
            ri = ri + 1
        end
        local r = runs[ri]
        if not (r and ch.b >= r.s) then
            add(ch.c, nil)
        elseif r.conceal == '' then
            -- concealed: dropped
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
    for _, r in ipairs(wrap_indices(items, width, width)) do
        local row = {}
        for k = r[1], r[2] do
            row[#row + 1] = items[k]
        end
        rows[#rows + 1] = row
    end
    return rows
end

local function table_border(left, mid, right, widths)
    local parts = {}
    for c = 1, #widths do
        parts[c] = string.rep('─', widths[c] + 2)
    end
    return left .. table.concat(parts, mid) .. right
end

-- Render one pipe table (buffer rows t_start..t_end, 0-based) as a boxed grid with
-- wrapped cells. Each source row is reused (concealed + overlaid); the extra grid
-- lines (top/bottom border, row separators, wrapped continuations) are virt_lines.
-- The cursor's own row is left raw so the cursor can sit on real text.
-- `inline` carries the per-row inline highlight/conceal runs (collect_inline), so
-- cell content is styled and its syntax markers concealed like real lines.
local function render_table(buf, t_start, t_end, avail, cursor_lnum, inline)
    local lines = vim.api.nvim_buf_get_lines(buf, t_start, t_end + 1, false)
    if #lines < 2 then
        return
    end

    local aligns = M.parse_aligns(lines[2])

    local function styled_row(lnum0)
        local row = {}
        for c, cell in ipairs(M.split_cells_pos(lines[lnum0 - t_start + 1])) do
            row[c] = styled_cell(cell.chars, inline[lnum0])
        end
        return row
    end
    local header = styled_row(t_start)
    local data = {}
    for lnum0 = t_start + 2, t_end do
        data[#data + 1] = styled_row(lnum0)
    end

    -- Column layout from the conceal-stripped display text.
    local function disp_row(cells)
        local r = {}
        for c, items in ipairs(cells) do
            local t = {}
            for _, it in ipairs(items) do
                t[#t + 1] = it.c
            end
            r[c] = table.concat(t)
        end
        return r
    end
    local all_rows = { disp_row(header) }
    for _, d in ipairs(data) do
        all_rows[#all_rows + 1] = disp_row(d)
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

    -- Grid rows for one source row, as virt_text chunk lists (one per display row).
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

    -- Header: top border above, content overlaid, wrapped continuations below.
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

    -- Delimiter row hosts the header/body separator (or the bottom border when the
    -- table has no data rows).
    local d_lnum = t_start + 1
    if d_lnum + 1 ~= cursor_lnum then
        overlay(d_lnum, { hl_chunk(#data > 0 and sep or bot) })
    end

    -- Data rows, each followed by a separator (or the bottom border for the last).
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

    -- Horizontal scroll (leftcol) is window-global, so it slides every line's real
    -- text, which we can't counter-compensate per line. Treat any horizontal scroll
    -- as "show raw text": with the namespace just cleared, bail out so all lines
    -- scroll uniformly. Decorations are restored on the next refresh once leftcol
    -- returns to 0.
    local leftcol = vim.api.nvim_win_call(win, function()
        return vim.fn.winsaveview().leftcol
    end)
    if leftcol > 0 then
        return
    end

    local info = vim.fn.getwininfo(win)[1]
    local width = vim.api.nvim_win_get_width(win) - info.textoff - config.right_pad
    -- A user-set max_width takes priority, but only as a cap: a narrower window
    -- still wraps at the window width.
    if config.max_width and config.max_width > 0 then
        width = math.min(width, config.max_width)
    end
    if width < config.min_text_width then
        return
    end

    -- READ mode wraps every visible line, including the one under the (hidden)
    -- cursor: a sentinel of -1 never matches a real line number, so the
    -- cursor-line exception below and in render_table is effectively disabled.
    local cursor_row = vim.b[buf].markdown_read_mode and -1
        or vim.api.nvim_win_get_cursor(win)[1]
    local first = math.max(info.topline - 1, 0)
    local last = info.botline

    -- Detect code blocks (read verbatim, exempt from wrapping) and pipe tables
    -- (rendered as a boxed grid) with treesitter. A full parse keeps table node
    -- ranges complete even when a table is only partly on screen; the captures are
    -- still limited to the visible range. The parser/tree are cached.
    local in_code, in_table, tables = {}, {}, {}
    local inline = {} -- row -> flattened inline highlight/conceal runs
    local ts_ok, parser = pcall(vim.treesitter.get_parser, buf, 'markdown')
    if ts_ok and parser then
        -- The ranged parse additionally parses injections (markdown_inline) in the
        -- visible range; the top-level markdown tree is still the full document.
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
                    -- The markdown grammar absorbs trailing pipe-less prose lines into
                    -- the table node. Trim to the contiguous run of rows that contain a
                    -- '|' so absorbed prose stays normal, wrappable text.
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
            inline = collect_inline(parser, buf, first, last)
        end
    end

    for _, t in ipairs(tables) do
        render_table(buf, t[1], t[2], width, cursor_row, inline)
    end

    -- Lines with image links are laid out by rendermark.image (images as a band +
    -- bottom-aligned gap text); don't double-wrap them here or the continuation rows
    -- stack below the image. Only skip when the image pipeline is actually active.
    local image = require('rendermark.image')
    local images_active = image.is_active()

    for lnum = first, last - 1 do
        if lnum + 1 ~= cursor_row and not in_code[lnum] and not in_table[lnum] then
            local text = vim.api.nvim_buf_get_lines(buf, lnum, lnum + 1, false)[1]
            if images_active and text and image.line_has_image_link(text) then
                -- handled by rendermark.image
            elseif text and #text > 0 then
                local indent = M.compute_indent(text)
                local r = M.wrap_line(text, width, width - indent, indent)
                if r.first_end_byte then
                    vim.api.nvim_buf_set_extmark(buf, ns, lnum, r.first_end_byte, {
                        end_col = #text,
                        conceal = '',
                    })
                    local indent_str = string.rep(' ', indent)
                    local vlines = {}
                    for k = 1, #r.lines do
                        local chunks = {}
                        if indent > 0 then
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

local pending = {}
local function schedule_refresh(win)
    if not win or win == 0 then
        win = vim.api.nvim_get_current_win()
    end
    if pending[win] then
        return
    end
    pending[win] = true
    vim.schedule(function()
        pending[win] = nil
        M.refresh(win)
    end)
end

-- A non-empty 'statuscolumn' replaces the default number column entirely, so we
-- rebuild signs + number/relativenumber ourselves and append the reading margin.
-- Numbers render only on real lines (v:virtnum == 0), not on wrapped/virtual ones.
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
    -- The decorated rows re-create inline styles from the treesitter highlight
    -- queries; real lines need the treesitter highlighter itself for the same
    -- styling and marker conceal. Nothing else attaches it for markdown (nvim's
    -- runtime ftplugin only auto-starts it for a few filetypes, and the
    -- nvim-treesitter highlight module does not in this setup).
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
    -- Don't decorate floating preview windows (LSP hover, signature help, etc.).
    -- Their narrow, fixed width plus the left_pad statuscolumn make stylize_markdown's
    -- full-width separator rules wrap and long lines truncate; Neovim's built-in
    -- markdown stylize already handles these floats (render-markdown.nvim likewise
    -- skips them via the nofile buftype override).
    if vim.api.nvim_win_get_config(0).relative ~= '' then
        return
    end
    if is_markdown_buffer(0) then
        M.apply(0)
    elseif saved_state[vim.api.nvim_get_current_win()] then
        -- The window's 'statuscolumn' (window-local) leaks to non-markdown
        -- buffers shown in the same window; restore it when leaving markdown.
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

    vim.api.nvim_create_autocmd({
        'WinScrolled', 'WinResized', 'VimResized',
        'TextChanged', 'TextChangedI',
        'CursorMoved', 'CursorMovedI',
        'InsertEnter', 'InsertLeave',
    }, {
        group = group,
        callback = function()
            if buffer_enabled(vim.api.nvim_get_current_buf()) then
                schedule_refresh(0)
            end
        end,
    })
end

return M
