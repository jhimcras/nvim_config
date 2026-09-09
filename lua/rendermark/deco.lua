-- rendermark decorations: headings, thematic breaks, checkboxes, list bullets,
-- block quotes and fenced code blocks. This is what used to be drawn by
-- render-markdown.nvim.
--
-- Passive module by design: it owns no autocmds and no scheduling. rendermark.wrap
-- drives it from inside its own refresh (M.clear, then M.render_range per visible
-- segment, before wrap decorates the same rows). That ordering is load-bearing:
-- wrap's collect_deco snapshots every FOREIGN-namespace extmark to learn how wide a
-- line really renders, so the conceals and inline paddings placed here have to be in
-- the buffer already or the wrap points are computed against the raw text.
--
-- Two Neovim constraints shape most of the code below:
--
--   * A conceal replacement is a SINGLE character (:h nvim_buf_set_extmark). So a
--     six-column '- [ ] ' cannot collapse to '<glyph> ' with one mark; the ranges are
--     split so the glyph supplies one column and a real source space the other.
--   * The runtime markdown highlights query sets `conceal_lines ""` on
--     fenced_code_block_delimiter and on the info string's language, so both fence
--     rows are not drawn at all at conceallevel>=2 -- they have zero height and
--     virt_lines anchored to them are dropped. The block's top bar (with the
--     right-aligned language) and bottom bar are therefore virt_lines on the first
--     and last CONTENT rows, which is what the fences would have looked like anyway.
--     conceal_lines yields on the cursor line, though (unless 'concealcursor' covers
--     the mode), so a fence row under the cursor comes back and the bar has to move
--     onto it as an overlay -- see place_bar in render_code.

local M = {}

local ut = require 'util'

local defaults = {
    -- A conceal replacement is one character, so only the FIRST character of a
    -- checkbox glyph is concealed in; anything after it (a space, typically) is
    -- drawn as inline padding next to it -- see render_list_item. That is how a
    -- nerd glyph the terminal draws two columns wide gets a real gap in front of
    -- the item text.
    checkbox = { unchecked = ' ', checked = ' ' },
    bullet = { '●', '○', '◆' }, -- by nesting depth, cycled
    quote = '▎',
    heading = {
        -- Columns of indent per heading level when the toggle is on. The toggle is
        -- the global `vim.g.rendermark_heading_indent`, so it can be flipped at
        -- runtime (a refresh redraws it) rather than only at setup.
        per_level = 2,
        indent = false,
    },
    code = {
        min_width = 50,
        pad = 1,
        -- Rendered as images by rendermark.image; a block background would sit
        -- underneath the picture.
        disable = { 'plantuml', 'puml', 'uml' },
    },
    dim_checked_sublist = true,
}

local config = vim.deepcopy(defaults)
local ns = vim.api.nvim_create_namespace('rendermark_deco')

-- `col` is the screen column the string starts at: a tab's width depends on where
-- it lands, so any text that does not start at column 0 has to say so.
local function dw(s, col)
    return vim.fn.strdisplaywidth(s, col or 0)
end

local function line_at(buf, row)
    return vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
end

local function mark(buf, row, col, opts)
    pcall(vim.api.nvim_buf_set_extmark, buf, ns, row, col, opts)
end

local deco_query
local function get_query()
    if deco_query == nil then
        local ok, q = pcall(vim.treesitter.query.parse, 'markdown', [[
            (atx_heading) @heading
            (thematic_break) @rule
            (setext_h2_underline) @rule
            (fenced_code_block) @code
            (indented_code_block) @verbatim
            (list_item) @item
        ]])
        deco_query = ok and q or false
    end
    return deco_query or nil
end

-- The heading indent is a global so it can be toggled without re-running setup.
-- Anything truthy turns it on; a number overrides the per-level column count.
local function heading_cols()
    local g = vim.g.rendermark_heading_indent
    if g == nil then
        return config.heading.indent and config.heading.per_level or 0
    end
    if type(g) == 'number' then
        return g
    end
    return g and config.heading.per_level or 0
end

-- Rendered display widths of the prefixes whose drawn width no longer matches the
-- source, handed to wrap_text.compute_indent so continuation rows hang under the
-- text instead of under where the raw markers used to end.
-- Refreshed in place rather than rebuilt: wrap calls this once per wrapped line on
-- every CursorMoved, and the heading column count can change between calls.
local metrics = { checkbox = 0, heading = 0 }
function M.metrics()
    -- glyph (+ its inline padding, if the string carries any) + surviving space
    metrics.checkbox = dw(config.checkbox.unchecked) + 1
    metrics.heading = heading_cols()
    return metrics
end

-- Width of a code block: wide enough for its widest line (plus padding on both
-- sides) and for the language label, never narrower than min_width. Deliberately
-- NOT clamped to the window -- a wide block runs off the right edge rather than
-- reflowing the code.
function M.code_width(widths, lang_w)
    local pad = config.code.pad
    local width = config.code.min_width
    for _, w in ipairs(widths) do
        width = math.max(width, w + pad * 2)
    end
    if lang_w > 0 then
        width = math.max(width, lang_w + pad * 2)
    end
    return width
end

-- One virt_line spanning the block: blank, or with `label` right-aligned `pad`
-- columns in from the right edge. A virt_line always starts at screen column 0, so
-- an indented block (a fence inside a list item) prepends `indent` unhighlighted
-- columns to put the bar's left edge on the same column as the content rows.
function M.code_bar(width, label, indent)
    local chunks = {}
    if indent and indent > 0 then
        chunks[1] = { string.rep(' ', indent) }
    end
    if not label or label == '' then
        chunks[#chunks + 1] = { string.rep(' ', width), 'RendermarkCode' }
        return chunks
    end
    local pad = config.code.pad
    local lead = math.max(0, width - pad - dw(label))
    chunks[#chunks + 1] = { string.rep(' ', lead), 'RendermarkCode' }
    chunks[#chunks + 1] = { label, 'RendermarkCodeInfo' }
    chunks[#chunks + 1] = { string.rep(' ', pad), 'RendermarkCode' }
    return chunks
end

function M.rule_chunks(width)
    return { { string.rep('─', math.max(0, width)), 'RendermarkRule' } }
end

-- Prefix chunks drawn in front of each wrapped continuation row. Plain spaces
-- normally (wrap handles that itself, hence the nil), but a block quote repeats its
-- bar so the vertical rule is not broken by the wrap -- the wrap engine cannot
-- reproduce extmark decorations inside virt_lines, only conceals and highlights, so
-- the bar has to be re-emitted here.
function M.prefix_chunks(text, indent)
    if indent <= 0 then
        return nil
    end
    local quote = text:match('^%s*>[%s>]*')
    if not quote then
        return nil
    end
    -- Mirror the source prefix character for character, exactly as render_quote
    -- conceals it: every '>' becomes a bar, everything else stays as it is, so a
    -- nested '>> ' stays three columns wide instead of gaining a space per level.
    local chunks = {}
    for i = 1, #quote do
        local c = quote:sub(i, i)
        if c == '>' then
            chunks[#chunks + 1] = { config.quote, 'RendermarkQuote' }
        else
            chunks[#chunks + 1] = { c }
        end
    end
    local used = 0
    for _, c in ipairs(chunks) do
        used = used + dw(c[1])
    end
    if used > indent then
        return nil
    end
    if used < indent then
        chunks[#chunks + 1] = { string.rep(' ', indent - used) }
    end
    return chunks
end

local function render_heading(buf, node)
    local marker, inline
    for child in node:iter_children() do
        local t = child:type()
        if t:match('^atx_h%d_marker$') then
            marker = child
        elseif t == 'inline' then
            inline = child
        end
    end
    if not marker then
        return
    end
    local row, s_col, _, e_col = marker:range()
    local line = line_at(buf, row)
    if not line then
        return
    end
    -- Swallow the blanks between the '#'s and the title too, so the text lands at
    -- column 0 regardless of the heading level.
    local text_col = line:find('%S', e_col + 1)
    local stop = text_col and (text_col - 1) or #line
    mark(buf, row, s_col, { end_col = stop, conceal = '' })
    local cols = heading_cols()
    if cols > 0 then
        -- Indent with inline virt_text rather than a conceal replacement: a
        -- replacement is one character, and collect_deco counts inline width, so
        -- wrap stays in step for free.
        local level = e_col - s_col
        if level > 1 then
            mark(buf, row, s_col, {
                virt_text = { { string.rep(' ', (level - 1) * cols) } },
                virt_text_pos = 'inline',
            })
        end
    end
    if inline then
        local irow, icol, ierow, iecol = inline:range()
        mark(buf, irow, icol, {
            end_row = ierow,
            end_col = iecol,
            hl_group = 'RendermarkHeading',
        })
    end
end

-- Both a standalone '---' (thematic_break) and the '---' underlining a setext
-- heading, which is the same three dashes: the grammar only calls it a break when a
-- blank line precedes it, and that distinction should not decide whether the user
-- sees a rule.
local function render_rule(buf, node, rule_width)
    local row = node:range()
    -- An overlay covers the raw '---' and keeps extending past the end of the line,
    -- so no conceal is needed. Being an overlay (not 'inline') it also stays out of
    -- wrap's width arithmetic.
    mark(buf, row, 0, {
        virt_text = M.rule_chunks(rule_width),
        virt_text_pos = 'overlay',
    })
end

local function bullet_for(depth)
    local list = config.bullet
    if #list == 0 then
        return nil
    end
    return list[((depth - 1) % #list) + 1]
end

local function list_depth(node)
    local depth, parent = 0, node:parent()
    while parent do
        if parent:type() == 'list' then
            depth = depth + 1
        end
        parent = parent:parent()
    end
    return depth
end

-- Rows inside `node` that carry verbatim or tabular content, which the dim of a
-- checked item has to leave alone (the code block's own background and the
-- table's own colors would otherwise be flattened to Comment).
local function collect_verbatim_rows(node, out)
    for child in node:iter_children() do
        local t = child:type()
        if t == 'fenced_code_block' or t == 'indented_code_block'
            or t == 'pipe_table' then
            local r1, _, r2, c2 = child:range()
            for row = r1, (c2 == 0 and r2 - 1 or r2) do
                out[row] = true
            end
        else
            collect_verbatim_rows(child, out)
        end
    end
end

local function render_list_item(buf, node)
    local marker, box, checked
    for child in node:iter_children() do
        local t = child:type()
        if t:match('^list_marker_') then
            marker = child
        elseif t == 'task_list_marker_unchecked' then
            box, checked = child, false
        elseif t == 'task_list_marker_checked' then
            box, checked = child, true
        end
    end
    if not marker then
        return
    end
    local row, m_s, _, m_e = marker:range()
    -- The marker node does not always start AT the marker character: when a nested
    -- list is indented further than its parent's continuation column, the grammar
    -- folds the extra indent into the marker ('  - '). Concealing from m_s would
    -- then replace a space and leave the '-' itself on screen.
    local line = line_at(buf, row) or ''
    local off = line:sub(m_s + 1, m_e):find('%S')
    if not off then
        return
    end
    local c_s = m_s + off - 1
    local box_end = c_s

    if box then
        -- '- [ ] ' -> '<glyph> ': the list marker goes entirely, the glyph replaces
        -- '[ ]', and the source space after the bracket supplies the second column.
        local _, b_s, _, b_e = box:range()
        local glyph = checked and config.checkbox.checked or config.checkbox.unchecked
        local hl = checked and 'RendermarkChecked' or 'RendermarkUnchecked'
        local head = vim.fn.strcharpart(glyph, 0, 1)
        box_end = b_e
        mark(buf, row, c_s, { end_col = m_e, conceal = '' })
        mark(buf, row, b_s, { end_col = b_e, conceal = head, hl_group = hl })
        -- Whatever the glyph string carries past its first character cannot go into
        -- the conceal (it holds one character); it is drawn after the box instead,
        -- which is also what gives a double-width glyph room to breathe.
        local pad = glyph:sub(#head + 1)
        if pad ~= '' then
            mark(buf, row, b_e, {
                virt_text = { { pad, hl } },
                virt_text_pos = 'inline',
            })
        end
    elseif marker:type():match('^list_marker_[mps]') then
        -- '- ' -> '<bullet> ': only the marker character is replaced (ordered list
        -- markers are left alone), so the item text keeps its column.
        local glyph = bullet_for(list_depth(node))
        if glyph then
            mark(buf, row, c_s, {
                end_col = c_s + 1,
                conceal = glyph,
                hl_group = 'RendermarkBullet',
            })
        end
    end

    -- Dim a completed item whole: its own text and everything nested under it.
    -- Row by row rather than one range mark, so verbatim rows (a fenced or
    -- indented code block, a table) can be left with their own colors, and so
    -- collect_deco -- which only forwards single-row hl_group marks with a real
    -- end_col -- can re-apply the dim to wrapped continuation rows.
    if checked and config.dim_checked_sublist then
        local i_row, _, e_row, e_col = node:range()
        local skip = {}
        collect_verbatim_rows(node, skip)
        for r = i_row, (e_col == 0 and e_row - 1 or e_row) do
            local text = line_at(buf, r)
            -- The first row starts past the checkbox so the glyph keeps its own
            -- highlight; deeper rows are dimmed from column 0.
            local from = r == i_row and box_end or 0
            if text and #text > from and not skip[r] then
                mark(buf, r, from, {
                    end_row = r,
                    end_col = #text,
                    hl_group = 'Comment',
                    hl_eol = true,
                })
            end
        end
    end
end

-- Returns the block's row span so the caller can keep raw-text passes (quote bars)
-- out of verbatim content. `cur` is the 0-based cursor row (nil when there is none).
local function render_code(buf, node, first, last, cur)
    local r1, c1, r2, c2 = node:range()
    if c2 == 0 then
        r2 = r2 - 1
    end
    local lang
    for child in node:iter_children() do
        if child:type() == 'info_string' then
            lang = vim.treesitter.get_node_text(child, buf):match('^%S+')
            break
        end
    end
    if lang and vim.tbl_contains(config.code.disable, lang:lower()) then
        return r1, r2
    end

    local pad = config.code.pad
    -- The background alone draws the block's border, so every row -- both bars and
    -- every content row, blank ones included -- has to cover exactly the screen
    -- columns [indent_w, indent_w + width). indent_w is the fence's own indent.
    local indent_w = dw((line_at(buf, r1) or ''):sub(1, c1))
    -- Geometry of one content row: where its background starts in bytes, how many
    -- columns of the block indent that row is missing (a blank or under-indented row
    -- has some), and how wide the code itself draws.
    -- The code text always begins at screen column indent_w + pad (the row's own
    -- indent plus the inline left pad below), which is where its tabs expand from.
    local function row_geom(line)
        local start = math.min(c1, #line)
        return start, indent_w - dw(line:sub(1, start)),
            dw(line:sub(start + 1), indent_w + pad)
    end
    -- One read for the whole block: the width depends on every content row, even
    -- the ones off screen, and this runs on each refresh.
    local body = vim.api.nvim_buf_get_lines(buf, r1 + 1, r2, false)
    local widths = {}
    for _, line in ipairs(body) do
        local _, lead, text_w = row_geom(line)
        widths[#widths + 1] = lead + text_w
    end
    if #widths == 0 then
        -- No content rows: both fences are conceal_lines-hidden, so there is nothing
        -- left to anchor a bar to. Degenerate, left unrendered.
        return r1, r2
    end
    local width = M.code_width(widths, lang and dw(lang) or 0)

    -- One row of the block's background rectangle, drawn around whatever text the row
    -- really has. Used for the content rows and, when the cursor is on it, for a
    -- fence row -- which is then a normal row showing '```lua' on the block colour.
    local function paint_row(row, line)
        local start, lead, text_w = row_geom(line)
        -- Left edge: the row's missing indent plus the block padding, in one
        -- inline chunk. Placed unconditionally, so a blank row inside the block
        -- still gets a full-width background instead of a hole in the rectangle.
        if lead + pad > 0 then
            mark(buf, row, start, {
                virt_text = { { string.rep(' ', lead + pad), 'RendermarkCode' } },
                virt_text_pos = 'inline',
            })
        end
        if #line > start then
            mark(buf, row, start, { end_col = #line, hl_group = 'RendermarkCode' })
        end
        -- Right edge: 'inline' at the end of the line, NOT 'eol'. An eol virt_text
        -- is drawn "right after eol character", which leaves one unhighlighted
        -- column between the code and the fill -- the rectangle would be broken at
        -- every line end and shifted one column right. Inline is safe here because
        -- wrap.render_range skips code rows entirely (in_code), so this width never
        -- enters any wrap arithmetic.
        local fill = width - pad - lead - text_w
        if fill > 0 then
            mark(buf, row, #line, {
                virt_text = { { string.rep(' ', fill), 'RendermarkCode' } },
                virt_text_pos = 'inline',
            })
        end
    end

    -- Bars replace the (undrawn) fence rows, hung off the first and last content row
    -- -- except on the fence row the CURSOR is on. 'concealcursor' is empty outside
    -- READ mode, so conceal_lines yields on the cursor line: the fence row is drawn
    -- again there, with its raw '```lua' back, which is what makes the fence editable.
    -- Its bar has to go then -- a virt_line on top of the re-appeared row would make
    -- the block one row taller for as long as the cursor sits there -- and the row is
    -- painted as an ordinary block row instead, so the rectangle stays closed and only
    -- the label is traded for the source text.
    -- (READ mode conceals the cursor line too and signals that with a cursor row of
    -- -1, so the bars stay virt_lines there.)
    local function place_bar(fence, anchor, above, label)
        if cur == fence then
            if fence >= first and fence < last then
                paint_row(fence, line_at(buf, fence) or '')
            end
        elseif anchor >= first and anchor < last then
            mark(buf, anchor, 0, {
                virt_lines = { M.code_bar(width, label, indent_w) },
                virt_lines_above = above,
            })
        end
    end
    place_bar(r1, r1 + 1, true, lang)
    place_bar(r2, r2 - 1, false, nil)

    for row = math.max(r1 + 1, first), math.min(r2 - 1, last - 1) do
        local line = body[row - r1]
        if line then
            paint_row(row, line)
        end
    end
    return r1, r2
end

-- Quote markers come from the raw text, not the tree: the grammar only produces a
-- block_quote_marker on a quote's FIRST line -- later lines carry a
-- block_continuation buried inside the inline node -- so matching the prefix (the
-- same pattern wrap_text.compute_indent uses) covers every row uniformly.
local function render_quote(buf, row, line)
    local prefix = line:match('^%s*>[%s>]*')
    if not prefix then
        return
    end
    for i = 1, #prefix do
        if prefix:sub(i, i) == '>' then
            mark(buf, row, i - 1, {
                end_col = i,
                conceal = config.quote,
                hl_group = 'RendermarkQuote',
            })
        end
    end
end

-- Decorate rows [first, last). Called once per visible segment by wrap.refresh,
-- before wrap decorates the same rows. `cursor_row` is 1-based, as wrap carries it.
function M.render_range(buf, first, last, rule_width, cursor_row)
    local q = get_query()
    if not q then
        return
    end
    local ok, parser = pcall(vim.treesitter.get_parser, buf, 'markdown')
    if not ok or not parser then
        return
    end
    local ok_tree, trees = pcall(function() return parser:parse({ first, last }) end)
    local tree = ok_tree and trees and trees[1]
    if not tree then
        return
    end

    local cur = cursor_row and cursor_row - 1
    local verbatim = {}
    for id, node in q:iter_captures(tree:root(), buf, first, last) do
        local name = q.captures[id]
        if name == 'heading' then
            render_heading(buf, node)
        elseif name == 'rule' then
            render_rule(buf, node, rule_width)
        elseif name == 'item' then
            render_list_item(buf, node)
        elseif name == 'code' then
            local r1, r2 = render_code(buf, node, first, last, cur)
            for row = r1, r2 do
                verbatim[row] = true
            end
        elseif name == 'verbatim' then
            -- Not styled as a block (it has no info string to align), but its rows
            -- are literal text: a leading '>' in there is not a quote.
            local r1, _, r2, c2 = node:range()
            for row = r1, (c2 == 0 and r2 - 1 or r2) do
                verbatim[row] = true
            end
        end
    end

    for row = first, last - 1 do
        if not verbatim[row] then
            local line = line_at(buf, row)
            if line then
                render_quote(buf, row, line)
            end
        end
    end
end

function M.clear(buf)
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
end

-- Colors that have to track the colorscheme: the code background is derived from
-- 'Normal' rather than pinned to a literal, and the heading groups are overridden so
-- a heading is bold in the normal text color instead of the colorscheme's own
-- per-level heading colors.
local function define_highlights()
    local normal = vim.api.nvim_get_hl(0, { name = 'Normal', link = false })
    local bg = normal.bg and ut.shade(normal.bg, 8) or nil

    vim.api.nvim_set_hl(0, 'RendermarkHeading', { bold = true })
    vim.api.nvim_set_hl(0, 'RendermarkRule', { link = 'Comment' })
    vim.api.nvim_set_hl(0, 'RendermarkQuote', { link = 'Comment' })
    vim.api.nvim_set_hl(0, 'RendermarkBullet', { link = 'Comment' })
    vim.api.nvim_set_hl(0, 'RendermarkUnchecked', { link = 'Comment' })
    vim.api.nvim_set_hl(0, 'RendermarkChecked', { link = 'Comment' })
    vim.api.nvim_set_hl(0, 'RendermarkCode', bg and { bg = bg } or {})
    local comment = vim.api.nvim_get_hl(0, { name = 'Comment', link = false })
    vim.api.nvim_set_hl(0, 'RendermarkCodeInfo',
        bg and { bg = bg, fg = comment.fg } or { link = 'Comment' })
    -- The treesitter highlighter paints heading text from these; overriding them
    -- (rather than layering an extmark) also makes wrapped continuation rows bold,
    -- since wrap re-creates its styling from the highlight-query captures.
    for level = 1, 6 do
        vim.api.nvim_set_hl(0, ('@markup.heading.%d.markdown'):format(level),
            { link = 'RendermarkHeading' })
    end
end

function M.setup(opts)
    config = vim.tbl_deep_extend('force', vim.deepcopy(defaults), opts or {})
    define_highlights()
    vim.api.nvim_create_autocmd('ColorScheme', {
        group = vim.api.nvim_create_augroup('rendermark_deco', { clear = true }),
        callback = define_highlights,
    })
end

return M
