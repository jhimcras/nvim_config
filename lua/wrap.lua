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

-- Pure wrap computation. Given a line and the available widths, returns:
--   first_end_byte : 0-based byte offset where the first display row ends, i.e.
--                    where the real line should be concealed (nil if it fits).
--   lines          : continuation rows (strings, already indented) for virt_lines.
-- Breaks at spaces when possible, otherwise per-character (handles CJK / long words).
function M.wrap_line(text, width1, widthN, indent)
    local chars = vim.fn.split(text, '\\zs')
    if #chars == 0 then
        return { first_end_byte = nil, lines = {} }
    end

    -- byte offset (0-based) of the start of each char; byte_at[#chars+1] = #text
    local byte_at = {}
    local acc = 0
    for i, c in ipairs(chars) do
        byte_at[i] = acc
        acc = acc + #c
    end
    byte_at[#chars + 1] = acc

    local indent_str = string.rep(' ', indent)
    local lines = {}
    local first_end_byte = nil

    local line_no = 1
    local line_start = 1   -- char index where the current display row starts
    local cur_w = 0
    local last_space = nil -- char index of the last space seen on the current row

    local function budget()
        return line_no == 1 and width1 or widthN
    end

    local function emit(stop_exclusive)
        if line_no == 1 then
            first_end_byte = byte_at[stop_exclusive]
        else
            local s = slice_concat(chars, line_start, stop_exclusive - 1):gsub('%s+$', '')
            lines[#lines + 1] = indent_str .. s
        end
    end

    local i = 1
    while i <= #chars do
        local c = chars[i]
        local cw = dw(c)
        -- A space is a break opportunity: the content before it already fits, so
        -- record it before the overflow check (handles a space landing exactly at
        -- the budget boundary).
        if c:match('%s') then
            last_space = i
        end
        if cur_w + cw > budget() and i > line_start then
            local stop, next_start
            if last_space and last_space >= line_start then
                stop = last_space        -- end row before the space (space dropped)
                next_start = last_space + 1
                while next_start <= #chars and chars[next_start]:match('%s') do
                    next_start = next_start + 1
                end
            else
                stop = i                 -- hard break (CJK / over-long word)
                next_start = i
            end
            emit(stop)
            line_no = line_no + 1
            line_start = next_start
            last_space = nil
            cur_w = 0
            i = next_start
        else
            cur_w = cur_w + cw
            i = i + 1
        end
    end

    if line_no > 1 then
        local s = slice_concat(chars, line_start, #chars):gsub('%s+$', '')
        lines[#lines + 1] = indent_str .. s
    end

    return { first_end_byte = first_end_byte, lines = lines }
end

-- Split a table row into trimmed cell strings, dropping the outer pipes and
-- unescaping "\|" so an escaped pipe stays inside its cell.
function M.split_cells(line)
    line = vim.trim(line)
    local lead = line:sub(1, 1) == '|'
    local trail = line:sub(-1) == '|'
    local cells, cur = {}, {}
    local i = 1
    while i <= #line do
        local ch = line:sub(i, i)
        if ch == '\\' and line:sub(i + 1, i + 1) == '|' then
            cur[#cur + 1] = '|'
            i = i + 2
        elseif ch == '|' then
            cells[#cells + 1] = table.concat(cur)
            cur = {}
            i = i + 1
        else
            cur[#cur + 1] = ch
            i = i + 1
        end
    end
    cells[#cells + 1] = table.concat(cur)
    if trail then table.remove(cells) end
    if lead then table.remove(cells, 1) end
    for k, c in ipairs(cells) do
        cells[k] = vim.trim(c)
    end
    return cells
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
    local line_start = 1
    local cur_w = 0
    local last_space = nil
    local function push(stop_exclusive)
        local parts = {}
        for k = line_start, stop_exclusive - 1 do
            parts[#parts + 1] = chars[k]
        end
        lines[#lines + 1] = (table.concat(parts):gsub('%s+$', ''))
    end
    local i = 1
    while i <= #chars do
        local c = chars[i]
        local cw = dw(c)
        if c:match('%s') then
            last_space = i
        end
        if cur_w + cw > width and i > line_start then
            local stop, next_start
            if last_space and last_space >= line_start then
                stop = last_space
                next_start = last_space + 1
                while next_start <= #chars and chars[next_start]:match('%s') do
                    next_start = next_start + 1
                end
            else
                stop = i
                next_start = i
            end
            push(stop)
            line_start = next_start
            last_space = nil
            cur_w = 0
            i = next_start
        else
            cur_w = cur_w + cw
            i = i + 1
        end
    end
    push(#chars + 1)
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

local function pad_cell(s, width, align)
    local extra = width - dw(s)
    if extra <= 0 then
        return s
    end
    if align == 'right' then
        return string.rep(' ', extra) .. s
    elseif align == 'center' then
        local l = math.floor(extra / 2)
        return string.rep(' ', l) .. s .. string.rep(' ', extra - l)
    end
    return s .. string.rep(' ', extra)
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
local function render_table(buf, t_start, t_end, avail, cursor_lnum, hl_chunk)
    local lines = vim.api.nvim_buf_get_lines(buf, t_start, t_end + 1, false)
    if #lines < 2 then
        return
    end

    local header = M.split_cells(lines[1])
    local aligns = M.parse_aligns(lines[2])
    local data = {}
    for i = 3, #lines do
        data[#data + 1] = M.split_cells(lines[i])
    end

    local all_rows = { header }
    for _, d in ipairs(data) do
        all_rows[#all_rows + 1] = d
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

    local function row_block(cells)
        local cols, height = {}, 1
        for c = 1, N do
            cols[c] = M.wrap_cell(cells[c] or '', widths[c])
            if #cols[c] > height then height = #cols[c] end
        end
        local out = {}
        for k = 1, height do
            local segs = {}
            for c = 1, N do
                segs[c] = ' ' .. pad_cell(cols[c][k] or '', widths[c], aligns[c]) .. ' '
            end
            out[k] = '│' .. table.concat(segs, '│') .. '│'
        end
        return out
    end

    local function overlay(lnum0, str)
        local raw = lines[lnum0 - t_start + 1] or ''
        if #raw > 0 then
            vim.api.nvim_buf_set_extmark(buf, ns, lnum0, 0, { end_col = #raw, conceal = '' })
        end
        vim.api.nvim_buf_set_extmark(buf, ns, lnum0, 0,
            { virt_text = { { str } }, virt_text_pos = 'overlay' })
    end
    local function vlines(lnum0, strs, above)
        if #strs == 0 then
            return
        end
        local vl = {}
        for _, s in ipairs(strs) do
            vl[#vl + 1] = { hl_chunk(s) }
        end
        vim.api.nvim_buf_set_extmark(buf, ns, lnum0, 0,
            { virt_lines = vl, virt_lines_above = above or nil })
    end

    -- Header: top border above, content overlaid, wrapped continuations below.
    vlines(t_start, { top }, true)
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
        overlay(d_lnum, #data > 0 and sep or bot)
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
            rest[#rest + 1] = below
            vlines(lnum0, rest, false)
        else
            vlines(lnum0, { below }, false)
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

    local cursor_row = vim.api.nvim_win_get_cursor(win)[1]
    local first = math.max(info.topline - 1, 0)
    local last = info.botline
    local hl_chunk = function(s)
        return config.hl and { s, config.hl } or { s }
    end

    -- Detect code blocks (read verbatim, exempt from wrapping) and pipe tables
    -- (rendered as a boxed grid) with treesitter. A full parse keeps table node
    -- ranges complete even when a table is only partly on screen; the captures are
    -- still limited to the visible range. The parser/tree are cached.
    local in_code, in_table, tables = {}, {}, {}
    local ts_ok, parser = pcall(vim.treesitter.get_parser, buf, 'markdown')
    if ts_ok and parser then
        local ok_tree, trees = pcall(function() return parser:parse() end)
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
        end
    end

    for _, t in ipairs(tables) do
        render_table(buf, t[1], t[2], width, cursor_row, hl_chunk)
    end

    for lnum = first, last - 1 do
        if lnum + 1 ~= cursor_row and not in_code[lnum] and not in_table[lnum] then
            local text = vim.api.nvim_buf_get_lines(buf, lnum, lnum + 1, false)[1]
            if text and #text > 0 then
                local indent = M.compute_indent(text)
                local r = M.wrap_line(text, width, width - indent, indent)
                if r.first_end_byte then
                    vim.api.nvim_buf_set_extmark(buf, ns, lnum, r.first_end_byte, {
                        end_col = #text,
                        conceal = '',
                    })
                    local vlines = {}
                    for _, s in ipairs(r.lines) do
                        vlines[#vlines + 1] = { hl_chunk(s) }
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
    local num = "%{(&nu||&rnu) ? (v:virtnum==0 ? (v:relnum==0 ? v:lnum : v:relnum) : '') : ''}"
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
