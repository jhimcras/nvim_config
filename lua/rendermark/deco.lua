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

local M = {}

local ut = require 'util'

local defaults = {
    -- Both conceal replacements below must stay single codepoints.
    checkbox = { unchecked = '', checked = '' },
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

local function dw(s)
    return vim.fn.strdisplaywidth(s)
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
    metrics.checkbox = dw(config.checkbox.unchecked) + 1 -- glyph + surviving space
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
-- columns in from the right edge.
function M.code_bar(width, label)
    if not label or label == '' then
        return { { string.rep(' ', width), 'RendermarkCode' } }
    end
    local pad = config.code.pad
    local lead = math.max(0, width - pad - dw(label))
    return {
        { string.rep(' ', lead), 'RendermarkCode' },
        { label, 'RendermarkCodeInfo' },
        { string.rep(' ', pad), 'RendermarkCode' },
    }
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

local function render_list_item(buf, node)
    local marker, box, checked, sublist
    for child in node:iter_children() do
        local t = child:type()
        if t:match('^list_marker_') then
            marker = child
        elseif t == 'task_list_marker_unchecked' then
            box, checked = child, false
        elseif t == 'task_list_marker_checked' then
            box, checked = child, true
        elseif t == 'list' then
            sublist = child
        end
    end
    if not marker then
        return
    end
    local row, m_s, _, m_e = marker:range()

    if box then
        -- '- [ ] ' -> '<glyph> ': the list marker goes entirely, the glyph replaces
        -- '[ ]', and the source space after the bracket supplies the second column.
        local _, b_s, _, b_e = box:range()
        mark(buf, row, m_s, { end_col = m_e, conceal = '' })
        mark(buf, row, b_s, {
            end_col = b_e,
            conceal = checked and config.checkbox.checked or config.checkbox.unchecked,
            hl_group = checked and 'RendermarkChecked' or 'RendermarkUnchecked',
        })
    elseif marker:type():match('^list_marker_[mps]') then
        -- '- ' -> '<bullet> ': only the marker character is replaced (ordered list
        -- markers are left alone), so the item text keeps its column.
        local glyph = bullet_for(list_depth(node))
        if glyph then
            mark(buf, row, m_s, {
                end_col = m_s + 1,
                conceal = glyph,
                hl_group = 'RendermarkBullet',
            })
        end
    end

    -- Dim the sub-list nested under a completed item; the checked item's own line is
    -- dimmed too, since neither is covered by the checkbox glyph's highlight.
    if checked and config.dim_checked_sublist and sublist then
        local s_row, s_col, e_row, e_col = sublist:range()
        mark(buf, s_row, s_col, {
            end_row = e_row,
            end_col = e_col,
            hl_group = 'Comment',
            hl_eol = true,
        })
    end
end

-- Returns the block's row span so the caller can keep raw-text passes (quote bars)
-- out of verbatim content.
local function render_code(buf, node, first, last)
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
    -- One read for the whole block: the width depends on every content row, even
    -- the ones off screen, and this runs on each refresh.
    local body = vim.api.nvim_buf_get_lines(buf, r1 + 1, r2, false)
    local widths = {}
    for _, line in ipairs(body) do
        widths[#widths + 1] = dw(line:sub(c1 + 1))
    end
    if #widths == 0 then
        -- No content rows: both fences are conceal_lines-hidden, so there is nothing
        -- left to anchor a bar to. Degenerate, left unrendered.
        return r1, r2
    end
    local width = M.code_width(widths, lang and dw(lang) or 0)

    -- Bars replace the (undrawn) fence rows, hung off the first and last content row.
    if r1 + 1 >= first and r1 + 1 < last then
        mark(buf, r1 + 1, 0, {
            virt_lines = { M.code_bar(width, lang) },
            virt_lines_above = true,
        })
    end
    if r2 - 1 >= first and r2 - 1 < last then
        mark(buf, r2 - 1, 0, { virt_lines = { M.code_bar(width, nil) } })
    end

    for row = math.max(r1 + 1, first), math.min(r2 - 1, last - 1) do
        local line = body[row - r1]
        if line then
            local text_w = dw(line:sub(c1 + 1))
            if #line > c1 then
                mark(buf, row, c1, { end_col = #line, hl_group = 'RendermarkCode' })
            end
            if pad > 0 then
                mark(buf, row, c1, {
                    virt_text = { { string.rep(' ', pad), 'RendermarkCode' } },
                    virt_text_pos = 'inline',
                })
            end
            -- 'eol' rather than virt_text_win_col: it is anchored to the text, so it
            -- needs no column arithmetic and survives horizontal scroll, and unlike
            -- 'inline' it is not counted into wrap's width math.
            local fill = width - pad - text_w
            if fill > 0 then
                mark(buf, row, c1, {
                    virt_text = { { string.rep(' ', fill), 'RendermarkCode' } },
                    virt_text_pos = 'eol',
                })
            end
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
-- before wrap decorates the same rows.
function M.render_range(buf, first, last, rule_width)
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
            local r1, r2 = render_code(buf, node, first, last)
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
