local wrap_text = require('nvim_config.rendermark.wrap.text')
local table_state = require('nvim_config.rendermark.table_state')
local html = require('nvim_config.rendermark.html')
local M = {}
local table_rows = table_state.rows
local dw = wrap_text.dw
local slice_concat = wrap_text.slice_concat
local wrap_indices = wrap_text.wrap_indices
local char_items = wrap_text.char_items
local push_chunk = wrap_text.push_chunk

local function hl_chunk(text, hl)
    return hl and { text, hl } or { text }
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
-- continuations are virt_lines. The cursor row stays raw.
function M.render_table(buf, t_start, t_end, avail, cursor_lnum, inline, config, ns)
    local lines = vim.api.nvim_buf_get_lines(buf, t_start, t_end + 1, false)
    if #lines < 2 then
        return
    end

    local aligns = M.parse_aligns(lines[2])
    local image = require('nvim_config.rendermark.image')
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
                        push_chunk(chunks, it.c, wrap_text.with_base(config.hl, it.hl))
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
    vlines(t_start, { { hl_chunk(top, config.hl) } }, true)
    if t_start + 1 ~= cursor_lnum then
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
    if d_lnum + 1 ~= cursor_lnum then
        overlay(d_lnum, { hl_chunk(#data > 0 and sep or bot, config.hl) })
    end

    -- Data rows, each followed by a separator (bottom border for the last).
    for i, cells in ipairs(data) do
        local lnum0 = t_start + 1 + i
        local below = (i == #data) and bot or sep
        if lnum0 + 1 ~= cursor_lnum then
            local block = row_block(cells, lnum0)
            overlay(lnum0, block[1])
            local rest = {}
            for k = 2, #block do
                rest[#rest + 1] = block[k]
            end
            rest[#rest + 1] = { hl_chunk(below, config.hl) }
            vlines(lnum0, rest, false)
        else
            vlines(lnum0, { { hl_chunk(below, config.hl) } }, false)
        end
    end
end

return M
