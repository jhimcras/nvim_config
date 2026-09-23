-- rendermark decorations: headings, thematic breaks, checkboxes, list bullets,
-- block quotes and fenced code blocks (what render-markdown.nvim used to draw).
--
-- Passive by design: no autocmds, no scheduling. rendermark.wrap drives it from its
-- own refresh (M.clear, then M.render_range per segment) BEFORE wrap decorates the
-- same rows. That order is load-bearing: wrap's collect_deco snapshots foreign
-- extmarks to learn a line's real width, so these marks must already be placed.
--
-- Two Neovim constraints shape most of the code below:
--
--   * A conceal replacement is a SINGLE character, so a six-column '- [ ] ' needs
--     split ranges: the glyph supplies one column, a real source space the other.
--   * The markdown highlights query sets `conceal_lines ""` on the fence rows, so
--     they have zero height and virt_lines anchored to them are dropped. The top
--     and bottom bars are therefore virt_lines on the first and last CONTENT rows.
--     conceal_lines yields on the cursor line, so a fence row under the cursor
--     comes back and its bar moves onto it as an overlay -- see place_bar.

local M = {}

local ut = require 'util'
local html = require 'rendermark.html'

-- Shade of the colorscheme's 'Normal', so the code background tracks it.
local function code_bg()
    local normal = vim.api.nvim_get_hl(0, { name = 'Normal', link = false })
    return normal.bg and ut.shade(normal.bg, 8) or nil
end

local defaults = {
    -- A conceal replacement is one character, so only the glyph's FIRST character
    -- is concealed in; the rest is drawn as inline padding (see render_list_item),
    -- which gives a double-width nerd glyph its gap before the item text.
    checkbox = { unchecked = ' ', checked = ' ' },
    bullet = { '●', '○', '◆' }, -- by nesting depth, cycled
    quote = '▎',
    heading = {
        -- Columns of indent per heading level. Toggled at runtime through the
        -- global vim.g.rendermark_heading_indent, not only at setup.
        per_level = 2,
        indent = false,
    },
    code = {
        min_width = 50,
        pad = 1,
        -- Rendered as images by rendermark.image; a background would show through.
        disable = { 'plantuml', 'puml', 'uml' },
    },
    dim_checked_sublist = true,
    -- Every highlight group this module paints with. A value is an nvim_set_hl spec
    -- or a function returning one, called on setup and on every ColorScheme so a
    -- group can derive from the active colorscheme. Override one entry via
    -- rendermark.setup{ highlight = { RendermarkQuote = { fg = '#7aa2f7' } } }.
    --
    -- @markup.heading.N.markdown is overridden rather than layering an extmark, so
    -- wrapped rows -- which replay the highlight-query captures -- stay bold too.
    highlight = {
        RendermarkHeading = { bold = true },
        RendermarkRule = { link = 'Comment' },
        RendermarkQuote = { link = 'Comment' },
        RendermarkBullet = { link = 'Comment' },
        RendermarkUnchecked = { link = 'Comment' },
        RendermarkChecked = { link = 'Comment' },
        RendermarkCode = function()
            local bg = code_bg()
            return bg and { bg = bg } or {}
        end,
        RendermarkCodeInfo = function()
            local bg = code_bg()
            local comment = vim.api.nvim_get_hl(0, { name = 'Comment', link = false })
            return bg and { bg = bg, fg = comment.fg } or { link = 'Comment' }
        end,
        ['@markup.heading.1.markdown'] = { link = 'RendermarkHeading' },
        ['@markup.heading.2.markdown'] = { link = 'RendermarkHeading' },
        ['@markup.heading.3.markdown'] = { link = 'RendermarkHeading' },
        ['@markup.heading.4.markdown'] = { link = 'RendermarkHeading' },
        ['@markup.heading.5.markdown'] = { link = 'RendermarkHeading' },
        ['@markup.heading.6.markdown'] = { link = 'RendermarkHeading' },
    },
}

local config = vim.deepcopy(defaults)
local ns = vim.api.nvim_create_namespace('rendermark_deco')

-- `col` is the starting screen column: a tab's width depends on where it lands.
local function dw(s, col)
    return vim.fn.strdisplaywidth(s, col or 0)
end

local function line_at(buf, row)
    return vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
end

local function mark(buf, row, col, opts)
    if html.is_hidden(buf, row) then return end
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

-- Global so it can be toggled without re-running setup. Truthy turns it on;
-- a number overrides the per-level column count.
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

-- Drawn widths of the prefixes whose rendered width differs from the source, for
-- wrap_text.compute_indent, so continuation rows hang under the text rather than
-- under the raw markers. Refreshed in place: wrap calls this per wrapped line on
-- every CursorMoved, and the heading column count can change between calls.
local metrics = { checkbox = 0, heading = 0 }
function M.metrics()
    -- glyph (+ any inline padding) + surviving space
    metrics.checkbox = dw(config.checkbox.unchecked) + 1
    metrics.heading = heading_cols()
    return metrics
end

-- Block width: its widest line plus padding, and the language label, never under
-- min_width. Deliberately unclamped -- a wide block runs off the right edge rather
-- than reflowing the code.
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

-- One virt_line spanning the block, optionally with `label` right-aligned `pad`
-- columns in. virt_lines start at screen column 0, so an indented block prepends
-- `indent` unhighlighted columns to line the bar up with the content rows.
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

-- Prefix chunks for each wrapped continuation row. nil for plain spaces (wrap does
-- those itself); a block quote repeats its bar so the rule isn't broken by the wrap,
-- since wrap cannot replay extmark decorations inside virt_lines.
function M.prefix_chunks(text, indent)
    if indent <= 0 then
        return nil
    end
    local quote = text:match('^%s*>[%s>]*')
    if not quote then
        return nil
    end
    -- Mirror the source prefix character for character, as render_quote conceals
    -- it, so a nested '>> ' stays three columns wide.
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
    -- Swallow the blanks after the '#'s so the text lands at column 0.
    local text_col = line:find('%S', e_col + 1)
    local stop = text_col and (text_col - 1) or #line
    mark(buf, row, s_col, { end_col = stop, conceal = '' })
    local cols = heading_cols()
    if cols > 0 then
        -- Inline virt_text, not a conceal replacement (one character only), and
        -- collect_deco counts inline width so wrap stays in step.
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

-- Both a standalone '---' and the '---' under a setext heading: the grammar only
-- calls it a break when a blank line precedes it, which shouldn't decide the look.
local function render_rule(buf, node, rule_width)
    local row = node:range()
    -- An overlay covers the raw '---' and extends past the line end, so no conceal
    -- is needed; being an overlay it also stays out of wrap's width arithmetic.
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

-- Rows of verbatim or tabular content inside `node`; a checked item's dim must
-- skip them or their own colors get flattened to Comment.
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

local function list_marker_col(line)
    local indent = line:match('^(%s*)[%-%*%+]%s+')
        or line:match('^(%s*)%d+[%.%)]%s+')
    return indent and #indent or nil
end

local function render_list_item(buf, node, cur)
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
    -- The grammar folds a nested list's extra indent into the marker ('  - '), so
    -- concealing from m_s would replace a space and leave the '-' on screen.
    local line = line_at(buf, row) or ''
    local off = line:sub(m_s + 1, m_e):find('%S')
    if not off then
        return
    end
    local c_s = m_s + off - 1
    local box_end = c_s

    if box then
        -- '- [ ] ' -> '<glyph> ': the marker goes, the glyph replaces '[ ]', and the
        -- source space after the bracket supplies the second column.
        local _, b_s, _, b_e = box:range()
        local glyph = checked and config.checkbox.checked or config.checkbox.unchecked
        local hl = checked and 'RendermarkChecked' or 'RendermarkUnchecked'
        local head = vim.fn.strcharpart(glyph, 0, 1)
        box_end = b_e
        mark(buf, row, c_s, { end_col = m_e, conceal = '' })
        mark(buf, row, b_s, { end_col = b_e, conceal = head, hl_group = hl })
        -- The conceal holds one character, so the rest of the glyph string is drawn
        -- after the box -- which also gives a double-width glyph room.
        local pad = glyph:sub(#head + 1)
        -- Conceal yields on the cursor row, revealing the source checkbox and its
        -- own trailing space. Keep the inline pad off that row or the gap doubles.
        if pad ~= '' and row ~= cur then
            mark(buf, row, b_e, {
                virt_text = { { pad, hl } },
                virt_text_pos = 'inline',
            })
        end
    elseif marker:type():match('^list_marker_[mps]') then
        -- '- ' -> '<bullet> ': only the marker character (ordered lists are left
        -- alone), so the item text keeps its column.
        local glyph = bullet_for(list_depth(node))
        if glyph then
            mark(buf, row, c_s, {
                end_col = c_s + 1,
                conceal = glyph,
                hl_group = 'RendermarkBullet',
            })
        end
    end

    -- Dim a completed item whole, nested content included. Row by row, not one range
    -- mark, so verbatim rows keep their own colors and collect_deco (which forwards
    -- only single-row hl_group marks) can re-apply the dim to wrapped rows.
    if checked and config.dim_checked_sublist then
        local i_row, _, e_row, e_col = node:range()
        local skip = {}
        collect_verbatim_rows(node, skip)
        for r = i_row, (e_col == 0 and e_row - 1 or e_row) do
            local text = line_at(buf, r)
            -- The markdown parser can absorb a following item into this node when
            -- both are indented four spaces. A marker at this item's depth (or
            -- shallower) is a sibling, not part of the checked item's sub-tree.
            local next_marker = r > i_row and text and list_marker_col(text)
            if next_marker and next_marker <= c_s then
                break
            end
            -- Start past the checkbox so the glyph keeps its highlight.
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

-- Returns the block's row span so the caller keeps raw-text passes (quote bars) out
-- of verbatim content. `cur` is the 0-based cursor row, or nil.
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
    -- The background alone draws the border, so every row (bars and content, blanks
    -- included) must cover exactly columns [indent_w, indent_w + width).
    local indent_w = dw((line_at(buf, r1) or ''):sub(1, c1))
    -- Geometry of one content row: byte where its background starts, columns of the
    -- block indent it is missing (blank or under-indented rows have some), and the
    -- drawn width of the code. Text always begins at column indent_w + pad, which is
    -- where its tabs expand from.
    local function row_geom(line)
        local start = math.min(c1, #line)
        return start, indent_w - dw(line:sub(1, start)),
            dw(line:sub(start + 1), indent_w + pad)
    end
    -- One read for the whole block: the width depends on off-screen rows too.
    local body = vim.api.nvim_buf_get_lines(buf, r1 + 1, r2, false)
    local widths = {}
    for _, line in ipairs(body) do
        local _, lead, text_w = row_geom(line)
        widths[#widths + 1] = lead + text_w
    end
    if #widths == 0 then
        -- No content rows and both fences hidden: nothing to anchor a bar to.
        return r1, r2
    end
    local width = M.code_width(widths, lang and dw(lang) or 0)

    -- One row of the background rectangle, around whatever text the row has. Used
    -- for content rows, and for a fence row the cursor is on.
    local function paint_row(row, line)
        local start, lead, text_w = row_geom(line)
        -- Left edge: missing indent plus block padding, in one inline chunk. Always
        -- placed, so a blank row doesn't leave a hole in the rectangle.
        if lead + pad > 0 then
            mark(buf, row, start, {
                virt_text = { { string.rep(' ', lead + pad), 'RendermarkCode' } },
                virt_text_pos = 'inline',
            })
        end
        if #line > start then
            mark(buf, row, start, { end_col = #line, hl_group = 'RendermarkCode' })
        end
        -- Right edge: 'inline', NOT 'eol' -- an eol virt_text leaves one
        -- unhighlighted column, breaking the rectangle at every line end. Safe
        -- because wrap.render_range skips code rows, so this width never reaches it.
        local fill = width - pad - lead - text_w
        if fill > 0 then
            mark(buf, row, #line, {
                virt_text = { { string.rep(' ', fill), 'RendermarkCode' } },
                virt_text_pos = 'inline',
            })
        end
    end

    -- Bars replace the undrawn fence rows, hung off the first and last content row --
    -- except on the fence row the CURSOR is on: conceal_lines yields there, the raw
    -- '```lua' comes back (that is what makes it editable), and a virt_line on top
    -- would make the block one row taller. That row is painted as an ordinary block
    -- row instead, trading only the label for the source text.
    -- (READ mode passes a cursor row of -1, so its bars stay virt_lines.)
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

-- Quote markers come from the raw text, not the tree: the grammar emits a
-- block_quote_marker only on the FIRST line, so matching the prefix (as
-- wrap_text.compute_indent does) covers every row uniformly.
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

-- Decorate rows [first, last), once per visible segment, before wrap decorates the
-- same rows. `cursor_row` is 1-based, as wrap carries it.
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
            render_list_item(buf, node, cur)
        elseif name == 'code' then
            local r1, r2 = render_code(buf, node, first, last, cur)
            for row = r1, r2 do
                verbatim[row] = true
            end
        elseif name == 'verbatim' then
            -- Not styled as a block (no info string), but its rows are literal text:
            -- a leading '>' in there is not a quote.
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

local function define_highlights()
    for group, spec in pairs(config.highlight) do
        if type(spec) == 'function' then spec = spec() end
        vim.api.nvim_set_hl(0, group, spec)
    end
end

function M.setup(opts)
    config = vim.tbl_deep_extend('force', vim.deepcopy(defaults), opts or {})
    -- Replaced whole, not merged: a { fg } override on a { link } default would
    -- otherwise keep the link, which wins.
    for group, spec in pairs((opts or {}).highlight or {}) do
        config.highlight[group] = spec
    end
    define_highlights()
    vim.api.nvim_create_autocmd('ColorScheme', {
        group = vim.api.nvim_create_augroup('rendermark_deco', { clear = true }),
        callback = define_highlights,
    })
end

return M
