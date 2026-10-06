-- Markdown decorations: headings, breaks, checkboxes, bullets, quotes, code blocks.
-- Passive: rendermark.wrap calls it before wrapping the same rows, since wrap's
-- collect_deco reads these extmarks for line widths.
-- A conceal replacement is a single character, so wider glyphs need extra padding.

local M = {}

local ut = require('nvim_config.util.hl')
local html = require 'nvim_config.rendermark.html'

-- Shade of 'Normal', for the code background.
local function code_bg()
    local normal = vim.api.nvim_get_hl(0, { name = 'Normal', link = false })
    return normal.bg and ut.shade(normal.bg, 8) or nil
end

local defaults = {
    -- Only the first glyph char is concealed in; the rest is inline padding.
    checkbox = { unchecked = ' ', checked = ' ' },
    bullet = { '●', '○', '◆' }, -- by nesting depth, cycled
    quote = '▎',
    heading = {
        -- Indent columns per heading level (toggle: vim.g.rendermark_heading_indent).
        per_level = 2,
        indent = false,
    },
    code = {
        min_width = 50,
        pad = 1,
        -- Rendered as images; a background would show through.
        disable = { 'plantuml', 'puml', 'uml' },
    },
    dim_checked_sublist = true,
    -- nvim_set_hl specs, or functions returning one (re-run on ColorScheme).
    -- Headings override @markup.heading.N.markdown so wrapped rows stay styled.
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
local fence_query
local fence_highlighters = {}

-- Strip conceal_lines from fence rows so each stays one screen row.
local function query_with_visible_fences()
    if fence_query then return fence_query end
    local parts = {}
    for _, path in ipairs(vim.treesitter.query.get_files('markdown', 'highlights')) do
        parts[#parts + 1] = table.concat(vim.fn.readfile(path), '\n')
    end
    local source = table.concat(parts, '\n')
    fence_query = source:gsub('(%(%#set! conceal ""%)%s*)%(%#set! conceal_lines ""%)', '%1')
    return fence_query
end

function M.visible_fences(buf, enable)
    if enable and fence_highlighters[buf] == vim.treesitter.highlighter.active[buf] then return end
    if not enable and not fence_highlighters[buf] then return end
    if enable then
        local ok, parser = pcall(vim.treesitter.get_parser, buf, 'markdown')
        if not ok then return end
        vim.treesitter.stop(buf)
        fence_highlighters[buf] = vim.treesitter.highlighter.new(parser,
            { queries = { markdown = query_with_visible_fences() } })
    else
        if fence_highlighters[buf] == vim.treesitter.highlighter.active[buf] then
            vim.treesitter.stop(buf)
            pcall(vim.treesitter.start, buf)
        end
        fence_highlighters[buf] = nil
    end
end

-- `col` is the starting screen column (tab width depends on it).
local function dw(s, col)
    return vim.fn.strdisplaywidth(s, col or 0)
end

local function line_at(buf, row)
    return vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
end

-- Rows of the render_range call in progress; marks outside it are dropped so a
-- partial repaint of [first, last) reproduces exactly what it cleared.
local clip_first, clip_last = 0, math.huge

local function mark(buf, row, col, opts)
    if row < clip_first or row >= clip_last or html.is_hidden(buf, row) then return end
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

-- Truthy enables it; a number overrides the per-level column count.
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

-- Rendered prefix widths for wrap_text.compute_indent. Refreshed in place.
local metrics = { checkbox = 0, heading = 0 }
function M.metrics()
    metrics.checkbox = dw(config.checkbox.unchecked) + 1
    metrics.heading = heading_cols()
    return metrics
end

-- Block width: widest line + padding + label, at least min_width. Not clamped.
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

-- One virt_line spanning the block, with an optional right-aligned `label`.
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

-- Prefix chunks for continuation rows (quote bars); nil for plain spaces.
function M.prefix_chunks(text, indent)
    if indent <= 0 then
        return nil
    end
    local quote = text:match('^%s*>[%s>]*')
    if not quote then
        return nil
    end
    -- Mirror the source prefix char by char, as render_quote conceals it.
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
    local text_col = line:find('%S', e_col + 1)
    local stop = text_col and (text_col - 1) or #line
    mark(buf, row, s_col, { end_col = stop, conceal = '' })
    local cols = heading_cols()
    if cols > 0 then
        -- Inline virt_text, since a conceal replacement is one character only.
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

-- Any '---' line, including under a setext heading.
local function render_rule(buf, node, rule_width)
    local row = node:range()
    -- An overlay covers the '---'; no conceal needed.
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

-- Verbatim/table rows inside `node`; a checked item's dim skips them.
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
    -- Nested markers include their indent ('  - '); skip it.
    local line = line_at(buf, row) or ''
    local off = line:sub(m_s + 1, m_e):find('%S')
    if not off then
        return
    end
    local c_s = m_s + off - 1
    local box_end = c_s

    if box then
        -- '- [ ] ' -> '<glyph> '.
        local _, b_s, _, b_e = box:range()
        local glyph = checked and config.checkbox.checked or config.checkbox.unchecked
        local hl = checked and 'RendermarkChecked' or 'RendermarkUnchecked'
        local head = vim.fn.strcharpart(glyph, 0, 1)
        box_end = b_e
        mark(buf, row, c_s, { end_col = m_e, conceal = '' })
        mark(buf, row, b_s, { end_col = b_e, conceal = head, hl_group = hl })
        -- Rest of the glyph is drawn after the box.
        local pad = glyph:sub(#head + 1)
        -- No inline pad on the cursor row, where conceal yields.
        if pad ~= '' and row ~= cur then
            mark(buf, row, b_e, {
                virt_text = { { pad, hl } },
                virt_text_pos = 'inline',
            })
        end
    elseif marker:type():match('^list_marker_[mps]') then
        -- '- ' -> '<bullet> ' (ordered lists left alone).
        local glyph = bullet_for(list_depth(node))
        if glyph then
            mark(buf, row, c_s, {
                end_col = c_s + 1,
                conceal = glyph,
                hl_group = 'RendermarkBullet',
            })
        end
    end

    -- Dim a completed item row by row, so collect_deco can forward it to wrapped rows.
    if checked and config.dim_checked_sublist then
        local i_row, _, e_row, e_col = node:range()
        local skip = {}
        collect_verbatim_rows(node, skip)
        for r = i_row, (e_col == 0 and e_row - 1 or e_row) do
            local text = line_at(buf, r)
            -- Stop at a sibling marker the parser absorbed into this node.
            local next_marker = r > i_row and text and list_marker_col(text)
            if next_marker and next_marker <= c_s then
                break
            end
            -- Past the checkbox, so the glyph keeps its highlight.
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

-- Returns the block's row span. `cur` is the 0-based cursor row, or nil.
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
    -- Every row must cover exactly columns [indent_w, indent_w + width).
    local indent_w = dw((line_at(buf, r1) or ''):sub(1, c1))
    -- Content row geometry: background start byte, missing indent, drawn width.
    local function row_geom(line)
        local start = math.min(c1, #line)
        return start, indent_w - dw(line:sub(1, start)),
            dw(line:sub(start + 1), indent_w + pad)
    end
    -- Read the whole block: width depends on off-screen rows too.
    local body = vim.api.nvim_buf_get_lines(buf, r1 + 1, r2, false)
    local widths = {}
    for _, line in ipairs(body) do
        local _, lead, text_w = row_geom(line)
        widths[#widths + 1] = lead + text_w
    end
    if #widths == 0 then
        -- Nothing to anchor a bar to.
        return r1, r2
    end
    local width = M.code_width(widths, lang and dw(lang) or 0)

    -- One row of the background rectangle.
    local function paint_row(row, line)
        local start, lead, text_w = row_geom(line)
        -- Left edge: always placed, so blank rows leave no hole.
        if lead + pad > 0 then
            mark(buf, row, start, {
                virt_text = { { string.rep(' ', lead + pad), 'RendermarkCode' } },
                virt_text_pos = 'inline',
            })
        end
        if #line > start then
            mark(buf, row, start, { end_col = #line, hl_group = 'RendermarkCode' })
        end
        -- Right edge: 'inline', not 'eol', which leaves a gap column at line end.
        local fill = width - pad - lead - text_w
        if fill > 0 then
            mark(buf, row, #line, {
                virt_text = { { string.rep(' ', fill), 'RendermarkCode' } },
                virt_text_pos = 'inline',
            })
        end
    end

    -- Bars sit on the fence rows themselves, for smooth scrolling.
    local function place_bar(fence, label)
        if fence < first or fence >= last then return end
        local line = line_at(buf, fence) or ''
        if cur == fence then
            paint_row(fence, line) -- keep the source editable under the cursor
        else
            mark(buf, fence, 0, { end_col = #line, conceal = '' })
            mark(buf, fence, 0, {
                virt_text = M.code_bar(width, label, indent_w),
                virt_text_pos = 'overlay',
            })
        end
    end
    place_bar(r1, lang)
    place_bar(r2, nil)

    for row = math.max(r1 + 1, first), math.min(r2 - 1, last - 1) do
        local line = body[row - r1]
        if line then
            paint_row(row, line)
        end
    end
    return r1, r2
end

-- Quote markers from raw text: the grammar marks only the first line.
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

-- Decorate rows [first, last). `cursor_row` is 1-based.
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
    clip_first, clip_last = first, last
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
            -- Literal rows: a leading '>' is not a quote.
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
    clip_first, clip_last = 0, math.huge
end

-- Rows [first, last), default all.
function M.clear(buf, first, last)
    vim.api.nvim_buf_clear_namespace(buf, ns, first or 0, last or -1)
end

local function define_highlights()
    for group, spec in pairs(config.highlight) do
        if type(spec) == 'function' then spec = spec() end
        vim.api.nvim_set_hl(0, group, spec)
    end
end

function M.setup(opts)
    config = vim.tbl_deep_extend('force', vim.deepcopy(defaults), opts or {})
    -- Replace, not merge: a kept { link } would win over { fg }.
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
