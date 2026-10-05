-- Soft-wrap for markdown: 'wrap' is off and continuation rows are virt_lines.
-- The cursor line stays raw on one row, since the cursor can't enter virt_lines.
-- Inline styling is re-created from treesitter highlight queries.

local M = {}
local wrap_text = require('rendermark.wrap.text')
local deco = require('rendermark.deco')
local html = require('rendermark.html')

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
local table_rows = {} -- buf -> source row -> images positioned in the rendered grid

function M.table_row(buf, row)
    local rows = table_rows[buf]
    return rows and rows[row]
end
-- Per-window fold-change detection state (see the decoration provider in M.setup).
local win_seen, win_settled = {}, {}
-- Last full render per window, for the incremental cursor path:
-- { buf, key, foreign, cursor, covered = { [row0] = true } }.
local rendered = {}
local owner = {} -- buf -> window whose render its namespaces hold
local typing = {} -- win -> generation of the pending insert-mode refresh
local TYPING_DEBOUNCE_MS = 100

local function dw(s)
    return wrap_text.dw(s)
end

local function hl_chunk(s)
    return config.hl and { s, config.hl } or { s }
end

local code_query -- lazy treesitter query: code blocks
local function get_code_query()
    if code_query == nil then
        local ok, q = pcall(vim.treesitter.query.parse, 'markdown',
            '[(fenced_code_block) (indented_code_block)] @cb')
        code_query = ok and q or false
    end
    return code_query or nil
end

local table_query -- lazy treesitter query: pipe tables
local function get_table_query()
    if table_query == nil then
        local ok, q = pcall(vim.treesitter.query.parse, 'markdown', '(pipe_table) @t')
        table_query = ok and q or false
    end
    return table_query or nil
end

-- Continuation indent in display columns.
function M.compute_indent(text)
    return wrap_text.compute_indent(text, deco.metrics())
end

local function slice_concat(t, a, b)
    return wrap_text.slice_concat(t, a, b)
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

-- Inline highlight/conceal runs per row for [first, last), from all language trees'
-- highlight captures plus extra_conceals.
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

-- Display metrics from foreign extmarks over [first, last), keyed by row:
--   conceals[row] = conceal ranges and hl_group highlights
--   inserts[row]  = { b = byte_col, w = width } of inline virt_text
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

-- Break items { w, sp } into inclusive index ranges per row, trailing space trimmed.
-- Breaks at spaces, else per item (CJK / long words).
local function wrap_indices(items, width1, widthN)
    return wrap_text.wrap_indices(items, width1, widthN)
end

local function char_items(chars)
    return wrap_text.char_items(chars)
end

-- Returns first_end_byte (nil if it fits), continuation lines, and their byte spans.
function M.wrap_line(text, width1, widthN, indent, runs, inserts)
    return wrap_text.wrap_line(text, width1, widthN, indent, runs, inserts)
end

-- Split a table row into trimmed cells, unescaping "\|". Each char keeps its
-- source byte offset: { text, chars = { { c, b }, ... } }.
function M.split_cells_pos(line)
    local chars = vim.fn.split(line, '\\zs')
    local pos = {}
    local acc = 0
    for i, c in ipairs(chars) do
        pos[i] = acc
        acc = acc + #c
    end

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

-- Column alignments from the delimiter row.
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

-- Wrap a cell to `width` columns; always >= 1 row.
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

-- Column widths capped at `cap`; leftover budget goes back to capped columns, and
-- overflow shrinks proportionally down to `min`.
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

-- Map a cell's chars through inline runs into display items { c, w, hl, sp },
-- dropping concealed chars.
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
            if ch.image then
                items[#items + 1] = ch.image
            else
                add(ch.c, nil)
            end
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
        if ch.image then
            items[#items + 1] = ch.image
        elseif not (r and ch.b >= r.s) then
            add(ch.c, nil)
        elseif r.conceal == '' then
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

-- Wrap display items to `width` columns.
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

-- Render a pipe table as a boxed grid: source rows are overlaid, borders and
-- continuations are virt_lines. Row `raw_lnum` (the insert-mode cursor) stays raw.
local function render_table(buf, t_start, t_end, avail, raw_lnum, cursor_lnum, inline)
    local lines = vim.api.nvim_buf_get_lines(buf, t_start, t_end + 1, false)
    if #lines < 2 then
        return
    end

    local aligns = M.parse_aligns(lines[2])
    local image = require('rendermark.image')
    local cell_w = tonumber(vim.g.neopp_cell_width_px) or 10
    local cell_h = tonumber(vim.g.neopp_cell_height_px) or 18
    local max_rows = tonumber(vim.g.neopp_image_max_height_rows) or 30
    local zoom = tonumber(vim.g.neopp_font_zoom_scale) or 1
    local active = image.is_active()
    for row = t_start, t_end do
        table_rows[buf][row] = {}
    end

    local function image_chars(cell, row)
        if not active then return cell.chars end
        local images = {}
        image.scan_markdown_image_text(buf, row, cell.text, images)
        local chars, offset, index = {}, 0, 1
        for _, ch in ipairs(cell.chars) do
            local img = images[index]
            if img and offset >= img.byte_end_col then
                index = index + 1
                img = images[index]
            end
            if img and not img.error and offset >= img.byte_col and offset < img.byte_end_col then
                if offset == img.byte_col then
                    local placed = vim.deepcopy(img)
                    placed.col, placed.byte_col = ch.b, ch.b
                    local w, h = image.compute_image_display_size(placed, avail * cell_w, max_rows, cell_h, zoom)
                    chars[#chars + 1] = { b = ch.b, image = {
                        c = string.rep(' ', math.ceil(w / cell_w)), w = math.ceil(w / cell_w),
                        image = placed, display_w = w, display_h = h,
                    } }
                end
            else
                chars[#chars + 1] = ch
            end
            offset = offset + #ch.c
        end
        return chars
    end

    local function styled_row(lnum0)
        local row = {}
        for c, cell in ipairs(M.split_cells_pos(lines[lnum0 - t_start + 1])) do
            row[c] = styled_cell(image_chars(cell, lnum0), inline[lnum0], html.table_breaks(buf, lnum0))
        end
        return row
    end
    local header = styled_row(t_start)
    local data = {}
    for lnum0 = t_start + 2, t_end do
        data[#data + 1] = styled_row(lnum0)
    end

    -- Layout from the conceal-stripped text.
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

    local function row_block(cells, lnum0)
        local cols, height = {}, 1
        for c = 1, N do
            local items = cells[c] or {}
            for _, it in ipairs(items) do
                if it.image then
                    it.display_w, it.display_h = image.compute_image_display_size(
                        it.image, widths[c] * cell_w, max_rows, cell_h, zoom)
                    it.w = math.ceil(it.display_w / cell_w)
                    it.c = string.rep(' ', it.w)
                end
            end
            cols[c] = {}
            for _, row in ipairs(wrap_items(items, widths[c])) do
                local h = 1
                for _, it in ipairs(row) do
                    if it.image then h = math.max(h, math.ceil(it.display_h / cell_h)) end
                end
                cols[c][#cols[c] + 1] = row
                for _ = 2, h do
                    local blank = {}
                    for _, it in ipairs(row) do
                        blank[#blank + 1] = { c = string.rep(' ', it.w), w = it.w }
                    end
                    cols[c][#cols[c] + 1] = blank
                end
            end
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
                local col = 2 + lpad
                for prev = 1, c - 1 do col = col + widths[prev] + 3 end
                for _, it in ipairs(row) do
                    if it.image then
                        local img = vim.deepcopy(it.image)
                        img.table_layout = { row = k - 1, col = col,
                            width = it.display_w, height = it.display_h }
                        table_rows[buf][lnum0][#table_rows[buf][lnum0] + 1] = img
                        local label = image._stub_active and ('[img: ' .. vim.fn.fnamemodify(img.path, ':t') .. ']') or ''
                        label = vim.fn.strcharpart(label, 0, it.w)
                        push_chunk(chunks, label .. string.rep(' ', math.max(0, it.w - dw(label))), config.hl)
                    else
                        push_chunk(chunks, it.c, with_base(it.hl))
                    end
                    col = col + it.w
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
        -- Conceal yields on the cursor row: blank out raw text past the grid.
        if lnum0 + 1 == cursor_lnum then
            local shown = 0
            for _, ch in ipairs(chunks) do shown = shown + dw(ch[1]) end
            local extra = dw(raw) - shown
            if extra > 0 then
                chunks = vim.list_extend(vim.deepcopy(chunks), { hl_chunk(string.rep(' ', extra)) })
            end
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
    if t_start + 1 ~= raw_lnum then
        local block = row_block(header, t_start)
        overlay(t_start, block[1])
        local cont = {}
        for k = 2, #block do
            cont[#cont + 1] = block[k]
        end
        vlines(t_start, cont, false)
    end

    -- Delimiter row: separator, or bottom border if there is no data.
    local d_lnum = t_start + 1
    if d_lnum + 1 ~= raw_lnum then
        overlay(d_lnum, { hl_chunk(#data > 0 and sep or bot) })
    end

    -- Data rows, each followed by a separator (bottom border for the last).
    for i, cells in ipairs(data) do
        local lnum0 = t_start + 1 + i
        local below = (i == #data) and bot or sep
        if lnum0 + 1 ~= raw_lnum then
            local block = row_block(cells, lnum0)
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

-- Pipe tables touching [first, last) as { first_row, last_row } (0-based, inclusive).
local function find_tables(buf, root, first, last)
    local tables = {}
    local tq = config.table and get_table_query() or nil
    if not tq then
        return tables
    end
    for _, node in tq:iter_captures(root, buf, first, last) do
        local r1, _, r2, c2 = node:range()
        if c2 == 0 then r2 = r2 - 1 end
        -- Trim trailing pipe-less prose the grammar absorbs into the table.
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
    end
    return tables
end

-- Rows of [first, last) inside tables this module draws, rendered yet or not.
-- Their images belong to the table layout, never to the inline image renderer.
function M.table_source_rows(buf, first, last)
    local rows = {}
    if not config.table or not buffer_enabled(buf) then
        return rows
    end
    local ok, parser = pcall(vim.treesitter.get_parser, buf, 'markdown')
    if not ok or not parser then
        return rows
    end
    local ok_tree, trees = pcall(function() return parser:parse({ first, last }) end)
    local tree = ok_tree and trees and trees[1]
    if not tree then
        return rows
    end
    for _, t in ipairs(find_tables(buf, tree:root(), first, last)) do
        for l = t[1], t[2] do
            rows[l] = true
        end
    end
    return rows
end

-- Decorate one visible range [first, last).
local function render_range(buf, first, last, width, cursor_row, images_active)
    -- Full parse so a partly visible table keeps its node range; captures stay in range.
    local in_code, in_table, tables = {}, {}, {}
    local inline = {} -- row -> flattened inline highlight/conceal runs
    -- Foreign extmark metrics, so the break matches the displayed width.
    local img_ns = vim.api.nvim_create_namespace('rendermark_neopp_images')
    local ex_conceals, inserts = collect_deco(buf, first, last, ns, img_ns)
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
            tables = find_tables(buf, root, first, last)
            for _, t in ipairs(tables) do
                for l = t[1], t[2] do
                    in_table[l] = true
                end
            end
            inline = collect_inline(parser, buf, first, last, ex_conceals)
        end
    end

    -- Tables stay rendered under a normal-mode cursor, so scrolling keeps their images.
    local mode = vim.api.nvim_get_mode().mode
    local table_cursor = mode:match('^[iR]') and cursor_row or -1
    for _, t in ipairs(tables) do
        render_table(buf, t[1], t[2], width, table_cursor, cursor_row, inline)
    end

    -- rendermark.image lays out image-link lines itself.
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
    local images_active = require('rendermark.image').is_active()
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
    if images_active then require('rendermark.image').schedule_image_sync() end
end

-- Rows [first, last) widened to whole pipe tables, which render_table draws at once.
local function widen_to_tables(buf, first, last)
    local tq = config.table and get_table_query() or nil
    local ok, parser = pcall(vim.treesitter.get_parser, buf, 'markdown')
    if not tq or not ok or not parser then
        return first, last
    end
    -- The text is unchanged since the last full render parsed it.
    local tree = parser:trees()[1]
    if not tree then
        return first, last
    end
    repeat
        local grown = false
        for _, node in tq:iter_captures(tree:root(), buf, first, last) do
            local r1, _, r2, c2 = node:range()
            if c2 == 0 then r2 = r2 - 1 end
            if r1 < first then first, grown = r1, true end
            if r2 + 1 > last then last, grown = r2 + 1, true end
        end
    until not grown
    return first, last
end

-- Row heights and table image placement, which image positions depend on.
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
    local images_active = require('rendermark.image').is_active()
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
        r[1], r[2] = widen_to_tables(buf, r[1], r[2])
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
        require('rendermark.image').schedule_image_sync()
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
    if require('rendermark.image').is_active() then
        require('rendermark.image').schedule_image_sync()
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
    vim.g.markdown_visual_wrap_enabled = config.markdown

    group = vim.api.nvim_create_augroup('markdown_visual_wrap', { clear = true })
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
